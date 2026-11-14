# Querying with dplyr

`tbl(con, variable)` gives a lazy table over one variable of an xarray
Dataset. dplyr verbs on it accumulate, and nothing is read until
[`collect()`](https://dplyr.tidyverse.org/reference/compute.html). The
verbs compile to a single Python statement, the same kind you could
write yourself for
[`dbGetQuery()`](https://dbi.r-dbi.org/reference/dbGetQuery.html), and
[`show_query()`](https://dplyr.tidyverse.org/reference/explain.html)
prints it. This article shows how each verb compiles, and so what gets
read.

``` r
library(xrdbi)
library(DBI)
library(dplyr, warn.conflicts = FALSE)
```

The examples use a small Dataset built in Python: ten days of a
sea-surface-temperature-like variable on a 1 degree grid, with latitude
stored north to south, as many products store it, and a few missing
values.

``` r
con <- dbConnect(xarray(), builder = function(xr) {
  reticulate::py_run_string("
import xarray as xr, numpy as np, pandas as pd
rng = np.random.default_rng(1)
lat = np.arange(-40.5, -50, -1.0)            # descending
lon = np.arange(140.5, 150, 1.0)
time = pd.date_range('2026-01-01', periods=10)
sst = 12 + 0.5 * (lat[None, :, None] + 45) + rng.normal(0, 0.3, (10, 10, 10))
sst[:, 0, :2] = np.nan
toy = xr.Dataset({'sst': (('time', 'lat', 'lon'), sst.astype('float32'))},
                 coords={'time': time, 'lat': lat, 'lon': lon})
")
  reticulate::py_eval("toy", convert = FALSE)
})
con
#> <XarrayConnection>
#>   dims: time: 10, lat: 10, lon: 10
#>   vars: sst
sst <- tbl(con, "sst")
```

## What a tbl supports

- [`filter()`](https://dplyr.tidyverse.org/reference/filter.html), with
  `==`, `%in%`, `<`, `<=`, `>`, `>=`,
  [`between()`](https://dplyr.tidyverse.org/reference/between.html) and
  `&` (or several arguments), each comparing a field with a value
- [`select()`](https://dplyr.tidyverse.org/reference/select.html) with
  plain column names
- [`head()`](https://rdrr.io/r/utils/head.html)
- [`collect()`](https://dplyr.tidyverse.org/reference/compute.html) (a
  tibble),
  [`as.data.frame()`](https://rdrr.io/r/base/as.data.frame.html) (a data
  frame),
  [`show_query()`](https://dplyr.tidyverse.org/reference/explain.html),
  and printing

Anything else, such as
[`mutate()`](https://dplyr.tidyverse.org/reference/mutate.html),
[`summarise()`](https://dplyr.tidyverse.org/reference/summarise.html) or
[`arrange()`](https://dplyr.tidyverse.org/reference/arrange.html), has
no method:
[`collect()`](https://dplyr.tidyverse.org/reference/compute.html) first,
and carry on with dplyr in R. Filter forms outside the list error when
the filter is added, saying which forms are supported:

``` r
try(sst |> filter(lat < -48 | lat > -42))
#> Error : unsupported filter expression: lat < -48 | lat > -42
#> supported: ==, %in%, <, <=, >, >=, between(), &
```

## Filters on dimensions become selections

A filter on a dimension compiles to a label-based `.sel()`, so xarray
reads only the cells in range. Inclusive bounds (`>=`, `<=`,
[`between()`](https://dplyr.tidyverse.org/reference/between.html)) are a
[`slice()`](https://dplyr.tidyverse.org/reference/slice.html); `%in%` is
a list of exact labels; `==` is a single label.

``` r
q <- sst |> filter(between(lon, 142, 144), lat == -42.5,
                   time >= as.Date("2026-01-09"))
show_query(q)
#> ds['sst'].sel(lat=-42.5, lon=slice(142, 144), time=slice('2026-01-09', None))
collect(q)
#> # A tibble: 4 × 4
#>   time                  lon   lat   sst
#>   <dttm>              <dbl> <dbl> <dbl>
#> 1 2026-01-09 00:00:00  142. -42.5  13.1
#> 2 2026-01-09 00:00:00  144. -42.5  13.1
#> 3 2026-01-10 00:00:00  142. -42.5  13.6
#> 4 2026-01-10 00:00:00  144. -42.5  12.9
```

Strict bounds (`<`, `>`) cannot be a `.sel()`, which is inclusive, so
the statement selects the inclusive range and then trims the boundary
labels with a boolean `.isel()`. The result is still an xarray
selection, read cell for cell:

``` r
sst |> filter(lon > 141.5, lon < 144.5) |> show_query()
#> ds['sst'].sel(lon=slice(141.5, 144.5)).pipe(lambda a: a.isel(lon=(a['lon'].to_index() > 141.5) & (a['lon'].to_index() < 144.5)))
```

Latitude here runs north to south, and a
[`slice()`](https://dplyr.tidyverse.org/reference/slice.html) in xarray
follows the order of the coordinate. Written by hand, `slice(-43, -41)`
would select nothing. The compiler checks the direction of each filtered
dimension and writes the slice in its order:

``` r
q <- sst |> filter(lat >= -43, lat <= -41, time == as.Date("2026-01-01"))
show_query(q)
#> ds['sst'].sel(lat=slice(-41, -43), time='2026-01-01')
collect(q)
#> # A tibble: 20 × 4
#>      lat   lon time                  sst
#>    <dbl> <dbl> <dttm>              <dbl>
#>  1 -41.5  140. 2026-01-01 00:00:00  13.8
#>  2 -41.5  142. 2026-01-01 00:00:00  13.9
#>  3 -41.5  142. 2026-01-01 00:00:00  13.5
#>  4 -41.5  144. 2026-01-01 00:00:00  13.7
#>  5 -41.5  144. 2026-01-01 00:00:00  13.6
#>  6 -41.5  146. 2026-01-01 00:00:00  13.9
#>  7 -41.5  146. 2026-01-01 00:00:00  13.8
#>  8 -41.5  148. 2026-01-01 00:00:00  13.7
#>  9 -41.5  148. 2026-01-01 00:00:00  13.5
#> 10 -41.5  150. 2026-01-01 00:00:00  13.7
#> 11 -42.5  140. 2026-01-01 00:00:00  13.3
#> 12 -42.5  142. 2026-01-01 00:00:00  13.2
#> 13 -42.5  142. 2026-01-01 00:00:00  13.6
#> 14 -42.5  144. 2026-01-01 00:00:00  13.6
#> 15 -42.5  144. 2026-01-01 00:00:00  12.4
#> 16 -42.5  146. 2026-01-01 00:00:00  12.7
#> 17 -42.5  146. 2026-01-01 00:00:00  13.2
#> 18 -42.5  148. 2026-01-01 00:00:00  13.1
#> 19 -42.5  148. 2026-01-01 00:00:00  13.3
#> 20 -42.5  150. 2026-01-01 00:00:00  13.3
```

Dates and times compile to their instant in UTC, the way xarray stores
times: a `Date` as `'YYYY-MM-DD'`, a `POSIXct` as
`'YYYY-MM-DDTHH:MM:SS'`, whatever its time zone.

``` r
sst |>
  filter(time >= as.POSIXct("2026-01-05 10:00", tz = "Australia/Hobart")) |>
  show_query()
#> ds['sst'].sel(time=slice('2026-01-04T23:00:00', None))
```

## Filters on values run in Python after the selection

A filter on the variable itself cannot be a selection, because which
cells pass depends on their values. It becomes a pandas `.query()` on
the selected cells, before they come to R. The dimension filters still
narrow what is read first:

``` r
q <- sst |> filter(lat <= -48, sst > 10.4)
show_query(q)
#> ds['sst'].sel(lat=slice(-48, None)).pipe(_xrdbi_render).query('`sst` > 10.4')
collect(q)
#> # A tibble: 34 × 4
#>    time                  lat   lon   sst
#>    <dttm>              <dbl> <dbl> <dbl>
#>  1 2026-01-01 00:00:00 -48.5  140.  10.5
#>  2 2026-01-01 00:00:00 -48.5  144.  10.5
#>  3 2026-01-01 00:00:00 -48.5  146.  10.5
#>  4 2026-01-02 00:00:00 -48.5  144.  11.1
#>  5 2026-01-02 00:00:00 -48.5  144.  10.5
#>  6 2026-01-03 00:00:00 -48.5  140.  10.5
#>  7 2026-01-04 00:00:00 -48.5  142.  10.7
#>  8 2026-01-04 00:00:00 -48.5  144.  10.5
#>  9 2026-01-04 00:00:00 -48.5  148.  10.6
#> 10 2026-01-04 00:00:00 -48.5  148.  10.4
#> # ℹ 24 more rows
```

With such a filter in place,
[`select()`](https://dplyr.tidyverse.org/reference/select.html) and
[`head()`](https://rdrr.io/r/utils/head.html) run in pandas too, so only
the rows and columns asked for cross to R.

``` r
sst |> filter(sst > 14) |> select(time, lat, sst) |> head(3) |> show_query()
#> ds['sst'].pipe(_xrdbi_render).query('`sst` > 14')[['time', 'lat', 'sst']].head(3)
```

Missing values are `NaN` in the array and stay `NaN` in R. A value
comparison is false for them, so they drop out:

``` r
nrow(collect(sst |> filter(time == as.Date("2026-01-01"), lat == -40.5)))
#> [1] 10
nrow(collect(sst |> filter(time == as.Date("2026-01-01"), lat == -40.5,
                           sst > 0)))
#> [1] 8
```

Filters on non-dimension coordinates, such as the 2-D longitude and
latitude of a curvilinear grid, are also exact pandas filters, but the
read is first narrowed to the block of the grid that holds every passing
cell. The [curvilinear
grids](https://mdsumner.github.io/xrdbi/articles/curvilinear.md) article
shows it.

## head() reads one corner

Without a value filter, `head(n)` and
[`select()`](https://dplyr.tidyverse.org/reference/select.html) apply in
R to the fetched rows, and `head(n)` first narrows the selection to the
leading block of the array that holds its `n` rows. The rows of the long
form run in C order, the last dimension fastest, so the first `n` rows
are a corner of the array:

``` r
sst |> head(4) |> show_query()
#> ds['sst'].isel(time=slice(0, 1), lat=slice(0, 1), lon=slice(0, 4)) 
#> # then in R: head(4)
```

That matters on big stores. This is the ARCO ERA5 reanalysis on Google
Cloud, an hourly zarr store with a time axis of over a million steps.
The first rows of a variable are one chunk’s worth of reading:

``` r
reticulate::py_require(c("zarr", "gcsfs"))
era <- dbConnect(xarray(),
  "gs://gcp-public-data-arco-era5/ar/full_37-1h-0p25deg-chunk-1.zarr-v3",
  engine = "zarr", storage_options = reticulate::dict(token = "anon"))
dbGetInfo(era)$sizes$time
#> [1] 1323648

t2m <- tbl(era, "2m_temperature") |>
  filter(time >= as.POSIXct("1980-01-01", tz = "UTC")) |>
  select(time, latitude, longitude, `2m_temperature`) |>
  head(3)
show_query(t2m)
#> ds['2m_temperature'].sel(time=slice('1980-01-01T00:00:00', None)).isel(time=slice(0, 1), latitude=slice(0, 1), longitude=slice(0, 3)) 
#> # then in R: head(3) |> select(time, latitude, longitude, `2m_temperature`)
collect(t2m)
#> # A tibble: 3 × 4
#>   time                latitude longitude `2m_temperature`
#>   <dttm>                 <dbl>     <dbl>            <dbl>
#> 1 1980-01-01 00:00:00       90      0                248.
#> 2 1980-01-01 00:00:00       90      0.25             248.
#> 3 1980-01-01 00:00:00       90      0.5              248.
dbDisconnect(era)
```

## Printing is a preview

Printing a lazy table shows the compiled statement, the sizes it
selects, and its first rows, reading at most one chunk.
`options(xrdbi.print_n = )` sets the number of rows, and
`options(xrdbi.print_preview = FALSE)` turns the preview off.

``` r
sst |> filter(lat <= -45)
#> <tbl_xarray> sst
#>   python: ds['sst'].sel(lat=slice(-45, None))
#>   sizes : time: 10, lat:  5, lon: 10
#> # A tibble: 6 × 4
#>   time                  lat   lon   sst
#>   <dttm>              <dbl> <dbl> <dbl>
#> 1 2026-01-01 00:00:00 -45.5  140.  11.8
#> 2 2026-01-01 00:00:00 -45.5  142.  11.5
#> 3 2026-01-01 00:00:00 -45.5  142.  12.0
#> 4 2026-01-01 00:00:00 -45.5  144.  11.6
#> 5 2026-01-01 00:00:00 -45.5  144.  12.0
#> 6 2026-01-01 00:00:00 -45.5  146.  11.4
#> # lazy preview of the first cells (reads at most one chunk); collect() for the full result
```

## The guard

[`collect()`](https://dplyr.tidyverse.org/reference/compute.html) sizes
the xarray part of the statement before reading it, and errors above
`max_cells` cells (10 million by default, or
`getOption("xrdbi.max_cells")`). Pass `force = TRUE` to read anyway, or
filter more dimensions. Here the limit is set low to show it:

``` r
try(collect(sst, max_cells = 500))
#> Error : collect would materialize 1,000 cells, over the guard (500); constrain more dimensions (e.g. a time range), raise options(xrdbi.max_cells=), or collect(force = TRUE)
nrow(collect(sst, max_cells = 500, force = TRUE))
#> [1] 1000
dbDisconnect(con)
```

## Where next

- [`?tbl_xarray`](https://mdsumner.github.io/xrdbi/reference/tbl_xarray.md)
  lists the verbs and filter forms.
- [Parameters](https://mdsumner.github.io/xrdbi/articles/parameters.md)
  passes values from R into statements you write yourself, for anything
  the verbs cannot say.
- [From arrays to
  rows](https://mdsumner.github.io/xrdbi/articles/rendering.md) covers
  what [`collect()`](https://dplyr.tidyverse.org/reference/compute.html)
  returns.
