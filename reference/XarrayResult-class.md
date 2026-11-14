# Xarray result

A statement is a Python expression evaluated with `ds` (the dataset) and
`xr` (the module) in scope, plus any `params`. Evaluation happens at
[`DBI::dbSendQuery()`](https://dbi.r-dbi.org/reference/dbSendQuery.html).
A selection (`sel()`, `isel()`, indexing) is lazy there: it describes
the cells and reads nothing. A statement that computes, such as a
reduction (`.mean()`) or arithmetic, runs right then unless the data are
dask-backed, and the `max_cells` guard sizes only its result, so it does
not cover that computation. Rendering to the tidy data frame happens at
the first
[`DBI::dbFetch()`](https://dbi.r-dbi.org/reference/dbFetch.html): one
row per cell, every coordinate as a column, exactly as xarray's
`to_dataframe().reset_index()` gives it.
[`DBI::dbGetQuery()`](https://dbi.r-dbi.org/reference/dbGetQuery.html)
is the two in one step.

## Usage

``` r
# S4 method for class 'XarrayConnection,character'
dbSendQuery(conn, statement, ..., params = NULL)

# S4 method for class 'XarrayResult'
dbBind(res, params, ...)

# S4 method for class 'XarrayResult'
show(object)

# S4 method for class 'XarrayResult'
dbIsValid(dbObj, ...)

# S4 method for class 'XarrayResult'
dbGetStatement(res, ...)

# S4 method for class 'XarrayResult'
dbFetch(
  res,
  n = -1,
  ...,
  max_cells = getOption("xrdbi.max_cells", 1e+07),
  force = FALSE
)

# S4 method for class 'XarrayResult'
dbHasCompleted(res, ...)

# S4 method for class 'XarrayResult'
dbGetRowCount(res, ...)

# S4 method for class 'XarrayResult'
dbClearResult(res, ...)
```

## Arguments

- conn:

  an XarrayConnection

- statement:

  a Python expression over `ds` (and `xr`)

- ...:

  unused

- params:

  named list of values the statement refers to by name; see the
  Parameters section

- object, dbObj, res:

  an XarrayResult

- n:

  number of rows to fetch, `-1` for all remaining

- max_cells:

  guard threshold for the first fetch, default
  `getOption("xrdbi.max_cells", 1e7)`

- force:

  bypass the guard

## Value

- [`dbSendQuery()`](https://dbi.r-dbi.org/reference/dbSendQuery.html):
  an XarrayResult

- [`dbBind()`](https://dbi.r-dbi.org/reference/dbBind.html): the result,
  invisibly, ready to fetch from the start

- [`dbFetch()`](https://dbi.r-dbi.org/reference/dbFetch.html): a data
  frame of the next `n` rows

- [`dbHasCompleted()`](https://dbi.r-dbi.org/reference/dbHasCompleted.html),
  [`dbIsValid()`](https://dbi.r-dbi.org/reference/dbIsValid.html):
  logical

- [`dbGetRowCount()`](https://dbi.r-dbi.org/reference/dbGetRowCount.html):
  the number of rows fetched so far

- [`dbGetStatement()`](https://dbi.r-dbi.org/reference/dbGetStatement.html):
  the statement

- [`dbClearResult()`](https://dbi.r-dbi.org/reference/dbClearResult.html):
  `TRUE`, invisibly

- [`show()`](https://rdrr.io/r/methods/show.html): called for its output

## Details

The first fetch is guarded: an xarray result above `max_cells` cells
errors unless `force = TRUE` (see `options(xrdbi.max_cells = )`). Later
fetches page through the same rows.

## Slots

- `ptr`:

  environment holding the evaluated Python object and the fetch state

- `statement`:

  the Python expression

## Parameters

`params` is a named list; each element becomes a Python variable of that
name in the statement's scope, beside `ds` and `xr`, so
`dbGetQuery(con, "ds.sst.sel(lat=lat0, method='nearest')", params = list(lat0 = -60))`
selects at `-60`.
[`dbBind()`](https://dbi.r-dbi.org/reference/dbBind.html) evaluates the
statement again with new values and restarts the fetch. Values become:

- length-1 vectors: numpy scalars (wrap in
  [`I()`](https://rdrr.io/r/base/AsIs.html) to keep a 1-element array);
  longer vectors: 1-D numpy arrays. Factors become strings.

- `Date`: `datetime64[D]`; `POSIXct`: `datetime64[ns]` as UTC, the way
  xarray stores times; `NA` becomes `NaT`

- geometry (an sfc, the geometry column of an sf, or any wk vector):
  shapely geometries via WKB, as a numpy array; with a CRS, a geopandas
  `GeoSeries` carrying it (needs geopandas), the form xvec's
  `extract_points()` and `zonal_stats()` take

- data frames: pandas DataFrames

- reticulate Python objects: unchanged

Names must be Python identifiers; `ds`, `xr` and names starting with
`_xrdbi` are reserved.

## See also

[`xr_query()`](https://mdsumner.github.io/xrdbi/reference/xr_query.md)
to write a statement from a structured selection;
[tbl()](https://mdsumner.github.io/xrdbi/reference/tbl_xarray.md) to
compile one from dplyr verbs;
[`xr_raster()`](https://mdsumner.github.io/xrdbi/reference/xr_raster.md)
and
[`xr_chunks()`](https://mdsumner.github.io/xrdbi/reference/xr_chunks.md)
to render the same statement other ways; the guard's options in
[xrdbi-package](https://mdsumner.github.io/xrdbi/reference/xrdbi-package.md).

## Examples

``` r
if (FALSE) { # \dontrun{
## needs a Python environment with xarray (see ?xrdbi)
f <- system.file("extdata/autotest/trmm.nc", package = "xrdbi")
con <- dbConnect(xarray(), f)
res <- dbSendQuery(con, "ds.pcp.isel(time=0)")
dbFetch(res, n = 5)
dbFetch(res, n = 5)
dbGetRowCount(res)
dbClearResult(res)

dbGetQuery(con, "ds.pcp.sel(latitude=slice(-15, -12), longitude=slice(-75, -72))")

## values from R, by name: the cells nearest two points
dbGetQuery(con,
  "ds.pcp.isel(time=0).sel(latitude=xr.DataArray(lats, dims='pt'),
    longitude=xr.DataArray(lons, dims='pt'), method='nearest')",
  params = list(lats = c(-15.1, -12.6), lons = c(-75.3, -72.8)))

## rebind and fetch again; method='nearest' also matches times that are
## not at midnight (OISST's are at 12:00, so an exact date would not)
res <- dbSendQuery(con, "ds.pcp.sel(time=t0, method='nearest')",
                   params = list(t0 = as.Date("2011-01-01")))
dbFetch(res, n = 3)
dbBind(res, list(t0 = as.Date("2011-01-02")))
dbFetch(res, n = 3)
dbClearResult(res)

## geometry: sf or wk vectors become shapely (a GeoSeries with a CRS);
## the .xvec accessor exists once xvec has been imported
reticulate::py_require(c("xvec", "geopandas"))
reticulate::import("xvec")
pts <- wk::xy(c(-75.3, -72.8), c(-15.1, -12.6), crs = "EPSG:4326")
dbGetQuery(con,
  "ds.pcp.xvec.extract_points(pts, x_coords='longitude', y_coords='latitude')",
  params = list(pts = pts))
dbDisconnect(con)
} # }
```
