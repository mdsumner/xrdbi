# Parameters

A statement is Python, so it can do anything xarray can, but writing R
values into Python source by hand
([`sprintf()`](https://rdrr.io/r/base/sprintf.html),
[`paste0()`](https://rdrr.io/r/base/paste.html)) is fragile: numbers
lose precision, dates need quoting, and a vector of points or a polygon
has no literal at all. `params` passes R values in by name instead. Each
element of the list becomes a Python variable of that name in the
statement’s scope, beside `ds` and `xr`.

``` r
library(xrdbi)
library(DBI)
f <- system.file("extdata/autotest/trmm.nc", package = "xrdbi")
con <- dbConnect(xarray(), f)

dbGetQuery(con,
  "ds.pcp.isel(time=0).sel(latitude=lat0, longitude=lon0, method='nearest')",
  params = list(lat0 = -15.1, lon0 = -75.3))
#>   longitude latitude       time         pcp
#> 1   -75.375  -15.125 2011-01-01 0.006235942
```

`params` works the same in
[`dbGetQuery()`](https://dbi.r-dbi.org/reference/dbGetQuery.html),
[`dbSendQuery()`](https://dbi.r-dbi.org/reference/dbSendQuery.html),
[`xr_raster()`](https://mdsumner.github.io/xrdbi/reference/xr_raster.md)
and
[`xr_chunks()`](https://mdsumner.github.io/xrdbi/reference/xr_chunks.md).

## What each R value becomes

A little helper shows what Python receives:

``` r
seen <- function(x) {
  dbGetQuery(con,
    "type(x).__name__ + (' ' + str(x.dtype) if hasattr(x, 'dtype') else '')",
    params = list(x = x))$value
}
seen(3)                       # a length-1 vector is a numpy scalar
#> [1] "float64 float64"
seen(I(3))                    # I() keeps it a 1-element array
#> [1] "ndarray float64"
seen(c(1.5, 2))               # longer vectors are 1-D numpy arrays
#> [1] "ndarray float64"
seen(1:3)
#> [1] "ndarray int64"
seen(c("Casey", "Davis"))
#> [1] "ndarray <U5"
seen(factor(c("lo", "hi")))   # factors become their labels
#> [1] "ndarray <U2"
seen(TRUE)
#> [1] "bool bool"
seen(as.Date("2026-01-01"))
#> [1] "datetime64 datetime64[D]"
seen(as.POSIXct("2026-01-01 10:00", tz = "Australia/Hobart"))
#> [1] "datetime64 datetime64[ns]"
seen(data.frame(a = 1:2, b = c("x", "y")))
#> [1] "DataFrame"
```

Dates become `datetime64[D]`, and date-times `datetime64[ns]` at their
instant in UTC, which is how xarray stores times, so a `POSIXct` in any
time zone selects the same instant. `NA` becomes `NaT`:

``` r
dbGetQuery(con, "str(x)",
  params = list(x = as.POSIXct(c("2026-01-01 10:00", NA),
                               tz = "Australia/Hobart")))
#>                                                               value
#> 1 ['2025-12-31T23:00:00.000000000'                           'NaT']
```

A reticulate Python object is passed as it is, so anything built with
reticulate can be a parameter too.

## Many points at once

xarray selects pointwise when the indexers are DataArrays sharing a new
dimension. With vectors from R, that is one statement for any number of
points:

``` r
dbGetQuery(con,
  "ds.pcp.isel(time=0).sel(latitude=xr.DataArray(lats, dims='pt'),
                           longitude=xr.DataArray(lons, dims='pt'),
                           method='nearest')",
  params = list(lats = c(-15.1, -12.6, -18.2), lons = c(-75.3, -72.8, -71.0)))
#>   pt longitude latitude       time         pcp
#> 1  0   -75.375  -15.125 2011-01-01 0.006235942
#> 2  1   -72.875  -12.625 2011-01-01 0.134595439
#> 3  2   -70.875  -18.125 2011-01-01 0.001243382
```

## Rebinding

[`dbBind()`](https://dbi.r-dbi.org/reference/dbBind.html) evaluates the
statement again with new values and restarts the fetch, so one result
can step through a set of values. Here, the mean rainfall along each of
a few latitudes:

``` r
res <- dbSendQuery(con,
  "ds.pcp.isel(time=0).sel(latitude=lat0, method='nearest').mean('longitude')",
  params = list(lat0 = -19))
profile <- lapply(c(-19, -16, -13, -10), function(lat) {
  dbBind(res, list(lat0 = lat))
  dbFetch(res)
})
dbClearResult(res)
do.call(rbind, profile)
#>   latitude       time          pcp
#> 1  -18.875 2011-01-01 0.0009085938
#> 2  -15.875 2011-01-01 0.0201212857
#> 3  -12.875 2011-01-01 0.1457962543
#> 4  -10.125 2011-01-01 0.1941436827
```

## Geometry

A geometry vector (an sf `sfc`, the geometry column of an sf data frame,
or any wk vector) becomes shapely geometries, by way of WKB. With a CRS
it becomes a geopandas `GeoSeries` carrying that CRS, which is the form
xvec takes. Both need the R package wk.

``` r
pts <- wk::xy(c(-75.3, -72.8), c(-15.1, -12.6), crs = "EPSG:4326")
seen(pts)
#> [1] "GeoSeries geometry"
seen(wk::xy(c(-75.3, -72.8), c(-15.1, -12.6)))   # no CRS: a shapely array
#> [1] "ndarray object"
```

With xvec, that makes point extraction one statement. The result is a
vector data cube, and its geometry comes back as
[`wk::wkb()`](https://paleolimbot.github.io/wk/reference/wkb.html) with
the CRS:

``` r
reticulate::py_require(c("xvec", "geopandas"))
invisible(reticulate::import("xvec"))   # registers the .xvec accessor
at <- dbGetQuery(con,
  "ds.pcp.xvec.extract_points(pts, x_coords='longitude', y_coords='latitude')",
  params = list(pts = pts))
at
#>         time              geometry         pcp
#> 1 2011-01-01 <POINT (-75.3 -15.1)> 0.006235942
#> 2 2011-01-01 <POINT (-72.8 -12.6)> 0.134595439
wk::wk_crs(at$geometry)
#> [1] "EPSG:4326"
```

The [curvilinear grids and vector
cubes](https://mdsumner.github.io/xrdbi/articles/curvilinear.md) article
goes further with xvec.

## Names

Names must be Python identifiers, and `ds`, `xr` and names starting with
`_xrdbi` are reserved:

``` r
try(dbGetQuery(con, "ds.pcp", params = list(ds = 1)))
#> Error : params names would shadow the statement scope: ds (ds, xr and _xrdbi* are reserved)
try(dbGetQuery(con, "ds.pcp", params = list(`2x` = 1)))
#> Error : params names must be Python identifiers: 2x
```

A name the statement uses but `params` does not supply is Python’s
`NameError`, with a reminder of what is in scope:

``` r
try(dbGetQuery(con, "ds.pcp.sel(latitude=lat0, method='nearest')"))
#> Error : NameError: name 'lat0' is not defined
#> Run `reticulate::py_last_error()` for details.
#> xrdbi: a statement sees `ds`, `xr` and the names in params; pass values with params = list(name = value)
dbDisconnect(con)
```

## Where next

- `?XarrayResult-class` documents `params` and
  [`dbBind()`](https://dbi.r-dbi.org/reference/dbBind.html).
- [From arrays to
  rows](https://mdsumner.github.io/xrdbi/articles/rendering.md) covers
  the results.
