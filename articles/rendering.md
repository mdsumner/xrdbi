# From arrays to rows

Every query result in xrdbi becomes a data frame in the same way, so it
pays to know that way. This article covers the shape of the rows, the
types of the columns, and when the work happens.

``` r
library(xrdbi)
library(DBI)
```

The examples use a small Dataset with the shapes that matter: two
variables on (time, lat, lon), a scalar coordinate `zlev`, and a 2-D
coordinate `cell_area` on (lat, lon).

``` r
con <- dbConnect(xarray(), builder = function(xr) {
  reticulate::py_run_string("
import xarray as xr, numpy as np, pandas as pd
rng = np.random.default_rng(42)
ocean = xr.Dataset(
  {'sst': (('time', 'lat', 'lon'), rng.random((3, 4, 5)).astype('float32')),
   'ice': (('time', 'lat', 'lon'), rng.random((3, 4, 5)).astype('float32'))},
  coords={'time': pd.date_range('2026-01-01', periods=3),
          'lat': np.linspace(-80, -60, 4),
          'lon': np.linspace(0, 40, 5),
          'zlev': 0.0,
          'cell_area': (('lat', 'lon'), np.ones((4, 5)))})
")
  reticulate::py_eval("ocean", convert = FALSE)
})
con
#> <XarrayConnection>
#>   dims: time: 3, lat: 4, lon: 5
#>   vars: sst, ice
```

## The long form

A result renders as xarray’s `to_dataframe().reset_index()` would give
it. There is one row per cell, in C order (the last dimension varies
fastest). The columns are the dimensions in the variable’s order, then
its other coordinates, broadcast to every row, then the variable itself.
[`dbListFields()`](https://dbi.r-dbi.org/reference/dbListFields.html)
names them in advance.

``` r
dbListFields(con, "sst")
#> [1] "time"      "lat"       "lon"       "zlev"      "cell_area" "sst"
head(dbGetQuery(con, "ds.sst"))
#>         time       lat lon zlev cell_area        sst
#> 1 2026-01-01 -80.00000   0    0         1 0.77395606
#> 2 2026-01-01 -80.00000  10    0         1 0.43887845
#> 3 2026-01-01 -80.00000  20    0         1 0.85859793
#> 4 2026-01-01 -80.00000  30    0         1 0.69736803
#> 5 2026-01-01 -80.00000  40    0         1 0.09417735
#> 6 2026-01-01 -73.33333   0    0         1 0.97562236
```

A Dataset renders a column per data variable on their shared dimensions.
After the dimensions come its other variables, data variables and
coordinates, in the Dataset’s own order (a scalar `time` here, left by
the selection):

``` r
head(dbGetQuery(con, "ds[['sst', 'ice']].isel(time=0)"), 3)
#>   lat lon       sst       ice       time zlev cell_area
#> 1 -80   0 0.7739561 0.6684030 2026-01-01    0         1
#> 2 -80  10 0.4388784 0.4710962 2026-01-01    0         1
#> 3 -80  20 0.8585979 0.5652361 2026-01-01    0         1
```

Variables with fewer dimensions are broadcast, as `to_dataframe()` does,
so a per-time value repeats along lat and lon:

``` r
head(dbGetQuery(con,
  "ds[['sst']].assign(sst_mean=ds.sst.mean(['lat', 'lon']))"), 3)
#>         time lat lon       sst zlev cell_area  sst_mean
#> 1 2026-01-01 -80   0 0.7739561    0         1 0.5738422
#> 2 2026-01-01 -80  10 0.4388784    0         1 0.5738422
#> 3 2026-01-01 -80  20 0.8585979    0         1 0.5738422
```

## Smaller shapes

A coordinate is a table too, and renders as a single column of its
values:

``` r
dbGetQuery(con, "ds.lat")
#>         lat
#> 1 -80.00000
#> 2 -73.33333
#> 3 -66.66667
#> 4 -60.00000
```

A selection that drops every dimension renders one row. A data variable
keeps the coordinates that were its dimensions, so a nearest-point
lookup says where it landed; a 0-d coordinate renders just itself.

``` r
dbGetQuery(con, "ds.sst.sel(time='2026-01-02', lat=-71, lon=12, method='nearest')")
#>         time       lat lon zlev cell_area      sst
#> 1 2026-01-02 -73.33333  10    0         1 0.466721
dbGetQuery(con, "ds.time.isel(time=-1)")
#>         time
#> 1 2026-01-03
```

A reduction is an ordinary result of whatever shape it has:

``` r
dbGetQuery(con, "ds.sst.mean('time')") |> head(3)
#>   lat lon zlev cell_area       sst
#> 1 -80   0    0         1 0.6563986
#> 2 -80  10    0         1 0.5420275
#> 3 -80  20    0         1 0.8431870
dbGetQuery(con, "ds.sst.mean()")
#>   zlev       sst
#> 1    0 0.5198094
```

A statement may also end in pandas, which is returned as it is, or in
any other Python value, which becomes one row in a column named `value`:

``` r
dbGetQuery(con,
  "ds.sst.isel(time=0).to_dataframe().reset_index().nlargest(3, 'sst')")
#>         lat lon       time zlev cell_area       sst
#> 1 -73.33333   0 2026-01-01    0         1 0.9756224
#> 2 -66.66667  10 2026-01-01    0         1 0.9267650
#> 3 -80.00000  20 2026-01-01    0         1 0.8585979
dbGetQuery(con, "len(ds.data_vars)")
#>   value
#> 1     2
```

## Types

Each column converts on its own, from the array’s type:

| In xarray (numpy or pandas) | In R |
|----|----|
| `float16` to `float64` | double; missing values stay `NaN` |
| `int8` to `int32`, `uint8`, `uint16` | integer |
| `int64`, `uint32`, `uint64` | double (exact up to 2^53) |
| `bool` | logical |
| `datetime64` | `POSIXct` in UTC; `NaT` becomes `NA` |
| time-zone-aware times (pandas) | `POSIXct` in their own zone |
| `timedelta64` | `difftime` in seconds; `NaT` is `NA` |
| strings, bytes | character |
| cftime dates (non-standard calendars) | character, as ISO text |
| pandas categoricals | factor |
| pandas nullable types (`Int64`, `boolean`) | integer, double or logical, with `NA` |
| shapely geometry (an xvec cube) | [`wk::wkb()`](https://paleolimbot.github.io/wk/reference/wkb.html) with its CRS (needs wk) |

``` r
types <- dbConnect(xarray(), builder = function(xr) {
  reticulate::py_run_string("
import xarray as xr, numpy as np, pandas as pd, cftime
types = xr.Dataset(
  {'f32': ('station', np.array([1.5, np.nan, 3.25], dtype='float32')),
   'i16': ('station', np.array([1, 2, 3], dtype='int16')),
   'i64': ('station', np.array([1, 2, 2**40], dtype='int64')),
   'flag': ('station', [True, False, True]),
   'when': ('station', pd.to_datetime(['2026-01-01', '2026-01-02', None])),
   'lag': ('station', pd.to_timedelta(['1h', '90min', None])),
   'name': ('station', np.array(['Casey', 'Davis', 'Mawson'])),
   'model_day': ('station', [cftime.DatetimeNoLeap(2028, 2, 27),
                             cftime.DatetimeNoLeap(2028, 2, 28),
                             cftime.DatetimeNoLeap(2028, 3, 1)])},
  coords={'station': np.array([1, 2, 3], dtype='int32')})
")
  reticulate::py_eval("types", convert = FALSE)
})
str(dbGetQuery(types, "ds"))
#> 'data.frame':    3 obs. of  9 variables:
#>  $ station  : int  1 2 3
#>  $ f32      : num  1.5 NaN 3.25
#>  $ i16      : int  1 2 3
#>  $ i64      : num  1.0 2.0 1.1e+12
#>  $ flag     : logi  TRUE FALSE TRUE
#>  $ when     : POSIXct, format: "2026-01-01" "2026-01-02" ...
#>  $ lag      : 'difftime' num  3600 5400 NA
#>   ..- attr(*, "units")= chr "secs"
#>  $ name     : chr  "Casey" "Davis" "Mawson"
#>  $ model_day: chr  "2028-02-27 00:00:00" "2028-02-28 00:00:00" "2028-03-01 00:00:00"
dbDisconnect(types)
```

`model_day` is in a 365-day calendar, where 2028 has no 29 February and
28 February is followed by 1 March. R has no types for such calendars,
so these dates arrive as character: labels, not times.

## When the work happens

Three moments matter:

- **[`dbSendQuery()`](https://dbi.r-dbi.org/reference/dbSendQuery.html)**
  evaluates the statement in Python. A selection (`sel()`, `isel()`,
  indexing) reads nothing here: xarray’s arrays are lazy until their
  values are asked for. A statement that computes, such as a mean or
  arithmetic, runs in full here, unless the data are dask-backed.
- **The first
  [`dbFetch()`](https://dbi.r-dbi.org/reference/dbFetch.html)** checks
  the guard, which sizes the result, and then reads its values.
  [`dbGetQuery()`](https://dbi.r-dbi.org/reference/dbGetQuery.html) is
  send and fetch together.
- **Every fetch** builds its rows in R: only the values cross from
  Python, and the coordinate columns are repeated with
  [`rep()`](https://rdrr.io/r/base/rep.html), so `dbFetch(n = )` builds
  only the rows it is asked for.

``` r
res <- dbSendQuery(con, "ds.sst.isel(time=0)")
dbFetch(res, n = 2)
#>   lat lon       time zlev cell_area       sst
#> 1 -80   0 2026-01-01    0         1 0.7739561
#> 2 -80  10 2026-01-01    0         1 0.4388784
dbFetch(res, n = 2)
#>   lat lon       time zlev cell_area       sst
#> 1 -80  20 2026-01-01    0         1 0.8585979
#> 2 -80  30 2026-01-01    0         1 0.6973680
dbHasCompleted(res)
#> [1] FALSE
dbClearResult(res)
```

Because the guard sizes only the result, a reduction over a large
variable runs at send time, before any guard. Select first, then reduce.

The guard counts the cells of the xarray result (for a Dataset, the rows
multiplied by the data variables) and errors above `max_cells`, 10
million by default (`getOption("xrdbi.max_cells")`):

``` r
try(dbGetQuery(con, "ds", max_cells = 50))
#> Error : materializing 120 cells exceeds the guard (50); subset first, raise options(xrdbi.max_cells=), or use force = TRUE
nrow(dbGetQuery(con, "ds", max_cells = 50, force = TRUE))
#> [1] 60
dbDisconnect(con)
```

## Where next

- [Querying with
  dplyr](https://mdsumner.github.io/xrdbi/articles/dplyr.md) builds
  these statements from verbs.
- [Rasters](https://mdsumner.github.io/xrdbi/articles/rasters.md)
  renders a 2-D slab as pixels instead of rows.
- [Curvilinear grids and vector
  cubes](https://mdsumner.github.io/xrdbi/articles/curvilinear.md) has
  2-D coordinates and geometry columns.
