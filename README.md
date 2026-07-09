# xrdbi

A DBI backend for xarray. The "database" is a live Python session
(reticulate) holding an xarray object; the connection is a handle to that
object.

- tables are variables (data variables and coordinates alike)
- fields are dimensions, then non-dimension coordinates, then the variable
- a statement is a Python expression evaluated with `ds` and `xr` in scope
- `dbSendQuery()` is lazy (builds the xarray selection graph, moves no
  bytes); the tidy long-form data frame is rendered at `dbFetch()`
- everything else is one step away via `xr_dataset(con)`

This provides pixel-level rows on demand from anything xarray can open. 
The chunk-level relation (byte
ranges, encoded blobs) is deliberately a different project; see the
dbi-for-xarray design note (gdal-r-python/dbi-xarray).

## Status

Should run anywhere reticulate can see a Python
environment with xarray plus the relevant IO engines (h5netcdf, zarr,
gcsfs, s3fs,gcsfs, ...); the gdal-r-python image is the reference environment.

## Example: OISST NetCDF over HTTPS

```r
## however you do it: https://rstudio.github.io/reticulate/reference/py_require.html
##reticulate::use_python("/usr/bin/python3")
library(DBI)
library(xrdbi)

eg <- "https://www.ncei.noaa.gov/data/sea-surface-temperature-optimum-interpolation/v2.1/access/avhrr/198109/oisst-avhrr-v02r01.19810901.nc"
con <- dbConnect(xarray(),
                 eg,
                 engine = "h5netcdf")  ## chunks = None by default, not reticulate::dict()

dbListTables(con)
#> [1] "anom" "err"  "ice"  "sst"  ...
dbListFields(con, "sst")
#> [1] "time" "zlev" "lat"  "lon"  "sst"

dbGetQuery(con, "ds.sst.sel(lat=slice(-56, -55), lon=slice(100, 101)).isel(time=0)")
#>   zlev     lat     lon                time         sst
#> 1    0 -55.875 100.125 1981-09-01 12:00:00 -0.06000000
#> 2    0 -55.875 100.375 1981-09-01 12:00:00 -0.14000000
#> 3    0 -55.875 100.625 1981-09-01 12:00:00 -0.17000000
#> 4    0 -55.875 100.875 1981-09-01 12:00:00 -0.11000000
#> 5    0 -55.625 100.125 1981-09-01 12:00:00  0.06000000
#> ...

dbDisconnect(con)
```

Note on `chunks`: omitting it (Python `chunks=None` for `open_dataset`)
gives lazy zarr-backed arrays and a fast connection. Passing
`chunks = reticulate::dict()` (Python `chunks={}`) wraps every variable
in dask at native storage chunking; for finely-chunked stores this can
cost minutes of task-graph construction at connect time (the ARCO ERA5
store above is 1 timestep per chunk, times 277 variables). Selection via
`sel`/`isel` is lazy either way and reads only the chunks a slab
touches, so prefer no dask for extraction, and opt in per statement for
reductions, rechunking to something sane:

```
    dbGetQuery(con,
      "ds['2m_temperature'].chunk({'time': 744}).sel(latitude=slice(19, 18), longitude=slice(73, 74)).mean('time')")
```

Beware that the default differs by open function: `open_dataset` defaults
to `chunks=None` (no dask), `open_zarr` defaults to `chunks='auto'`
(dask). If you connect with `open = "open_zarr"`, pass `chunks =
reticulate::py_none()` explicitly to get the fast path.

## Example: ARCO ERA5 (zarr v3, anonymous GCS)

Requires the gcsfs Python package.

```r
era <- "gs://gcp-public-data-arco-era5/ar/full_37-1h-0p25deg-chunk-1.zarr-v3"
con <- dbConnect(xarray(),
                 era,
                 engine = "zarr", 
                 storage_options = reticulate::dict(token = "anon"))

con
#> <XarrayConnection>
#>   dsn: gs://gcp-public-data-arco-era5/ar/full_37-1h-0p25deg-chunk-1.zarr-v3
#>   dims: time: 1323648, latitude: 721, longitude: 1440, level: 37
#>   vars: 100m_u_component_of_wind, 100m_v_component_of_wind, ...

str(dbListTables(con))
#> chr [1:277] "100m_u_component_of_wind" "100m_v_component_of_wind" ...
dbListFields(con, "100m_u_component_of_wind")
#> [1] "time"  "latitude"  "longitude"  "100m_u_component_of_wind"

## dataset attributes are one expression away
dbGetQuery(con, "ds.attrs['valid_time_start']")
```

Label-based `slice` follows the order of the coordinate, and ERA5
latitude runs descending (90 down to -90). So this selects the empty
interval and returns zero rows:

```r
dbGetQuery(con,
  "ds['100m_u_component_of_wind'].sel(latitude=slice(18, 19), longitude=slice(73, 74), time='1980-01-01')")
#> <0 rows>
```

Inspect the coordinate (coordinates are tables too), then slice in its
order:

```r
dbGetQuery(con, "ds.latitude.isel(latitude=slice(0, 5))")
#>   latitude
#> 1     90.0
#> 2     89.75
#> ...

dbGetQuery(con,
  "ds['100m_u_component_of_wind'].sel(latitude=slice(19, 18), longitude=slice(73, 74), time='1980-01-01')")
# # A tibble: 600 × 4
# time                latitude longitude `100m_u_component_of_wind`
# <dttm>                 <dbl>     <dbl>                      <dbl>
# 1  1980-01-01 00:00:00    19        73                     -0.55761 
# 2  1980-01-01 00:00:00    19        73.25                  -0.21255 
# 3  1980-01-01 00:00:00    19        73.5                    0.80380 
# 4  1980-01-01 00:00:00    19        73.75                   2.3964  
# 5  1980-01-01 00:00:00    19        74                      3.7569  
# 6  1980-01-01 00:00:00    18.75     73                     -0.28515 
# 7  1980-01-01 00:00:00    18.75     73.25                  -0.035991
# 8  1980-01-01 00:00:00    18.75     73.5                    1.0485  
# 9  1980-01-01 00:00:00    18.75     73.75                   2.7908  
# 10 1980-01-01 00:00:00    18.75     74                      3.9434  
# # ℹ 590 more rows
# # ℹ Use `print(n = ...)` to see more rows
```

Longitude here is 0..360 ascending, so `slice(73, 74)` is fine as-is.
A quoted date string on `time` selects the whole day.

dplyr verbs work as expected. 

```R
 tbl(con, "100m_u_component_of_wind") |>
+        filter(latitude > 18, latitude < 19, longitude >= 73, longitude <= 74) |> 
+   filter(time >= as.Date("1980-01-01"), time <= as.Date("1980-01-31")) |> 
+   collect()
                   time latitude longitude 100m_u_component_of_wind
1   1980-01-01 00:00:00    18.75     73.00              -0.28514814
2   1980-01-01 00:00:00    18.75     73.25              -0.03599060
3   1980-01-01 00:00:00    18.75     73.50               1.04847205
4   1980-01-01 00:00:00    18.75     73.75               2.79078245
5   1980-01-01 00:00:00    18.75     74.00               3.94336033
...
```
## Example: OISST daily mosaic via GDAL multidim VRT (gdalxarray engine)

Requires the gdalxarray Python package. The dsn is a GDAL multidim VRT
mosaic over the full OISST daily record, published by a scheduled
pipeline; xarray opens it through the gdalxarray backend, so every GDAL
virtual filesystem and format is in reach of the same DBI surface.

```r
dsn <- "/vsicurl/https://projects.pawsey.org.au/aad-index/oisst/oisst-mdim.vrt"

Sys.setenv(AWS_NO_SIGN_REQUEST = "YES")
system.time({
  con <- dbConnect(xarray(), dsn, engine = "gdalxarray")
})
#>    user  system elapsed
#>   9.261   0.386   5.569

con
#> <XarrayConnection>
#>   dsn: /vsicurl/https://projects.pawsey.org.au/aad-index/oisst/oisst-mdim.vrt
#>   dims: time: 16379, zlev: 1, lat: 720, lon: 1440
#>   vars: anom, err, ice, sst

## the most recent day in the record (a 0-d scalar renders as one row)
dbGetQuery(con, "ds.time.isel(time=-1)")
#>                  time
#> 1 2026-07-06 12:00:00

## one day of SST as tidy rows
dbGetQuery(con, "ds.sst.isel(time=-1)") |> str()
#> 'data.frame':  1036800 obs. of  5 variables:
#>  $ zlev: num  0 0 0 0 ...
#>  $ lat : num  -89.9 -89.9 ...
#>  $ lon : num  0.125 0.375 ...
#>  $ time: POSIXct, format: "2026-07-06 12:00:00" ...
#>  $ sst : num  NaN NaN ...
```

Two lessons this dsn teaches:

Laziness defers failure as well as work. The VRT itself is public over
`/vsicurl`, but its sources are `/vsis3` paths into the NOAA bucket, so
a missing `AWS_NO_SIGN_REQUEST` errors at the first query, not at
connect (connect reads only the VRT metadata). GDAL reads configuration
from the process environment at access time, so `Sys.setenv()` works
even after the Python session is up; setting it before connecting is
still the tidy habit.

A connection is a snapshot. The pipeline behind this VRT publishes a
new day on schedule (it did so mid-session while writing this example:
a held connection kept answering with the previous day, a fresh connect
saw the new one). The rolling `oisst-mdim.vrt` always means "latest";
pin a dated sibling (`oisst-mdim-YYYYMMDD.vrt`) when you need a
reproducible record. Icechunk makes this distinction first-class: a
readonly session at a snapshot is an AS OF query.

## Connect forms

Exactly one of `dsn`, `builder`, `object`.

A string that xarray can open (as above), with the open function
selectable via `open =` ("open_dataset" default, also "open_zarr",
"open_mfdataset", "open_datatree") and keyword arguments passed through.

A builder function, for anything that takes more than one call (icechunk
sessions, virtualizarr, combining sources):

```r
con <- dbConnect(xarray(), builder = function(xr) {
  ic <- reticulate::import("icechunk", convert = FALSE)
  repo <- ic$Repository$open(ic$s3_storage(
            bucket = "aad-index", prefix = "rema-v2",
            region = "ap-southeast-2", anonymous = TRUE))
  session <- repo$readonly_session("main")
  xr$open_zarr(session$store, consolidated = FALSE)
})
```

Adopt an object already built in the session:

```r
reticulate::py_run_string("import xarray; myds = xarray.tutorial.open_dataset('air_temperature')")
con <- dbConnect(xarray(), object = reticulate::py_eval("myds", convert = FALSE))
```

## Verbs and semantics

```r
## structured spec compiles to the same python string (inspect it, log it)
q <- xr_query(vars = "sst",
              sel  = list(lat = c(-56, -55), lon = c(100, 101)),
              isel = list(time = 0))
q
#> "ds['sst'].sel(lat=slice(-56, -55), lon=slice(100, 101)).isel(time=0)"
dbGetQuery(con, q)

## lazy send, paginated fetch
res <- dbSendQuery(con, "ds.sst.isel(time=0)")
dbFetch(res, n = 1000)
dbClearResult(res)

## whole-variable read is guarded against accidental terabyte renderings
dbReadTable(con, "sst")                  # errors above xrdbi.max_cells
options(xrdbi.max_cells = 1e8)           # move the line, or force = TRUE

## drop down whenever the veneer is in the way
ds <- xr_dataset(con)
ds$sst$encoding
```

The rendering of a result is `to_dataframe().reset_index()`: one row per
cell, coordinates as columns (all coordinates propagate, including
scalars like zlev), datetimes arriving as POSIXct. Dimension coordinates
render as a single column of their values; scalar results as a one-cell
frame. The array is a rendering format; so is the data frame.

Note `isel` in `xr_query()` uses zero-based Python indices: the function
interpolates values into Python source and does not translate. The
compiled expression is the contract.

`dbBegin`/`dbCommit`/`dbRollback` error for now; the intended mapping is
icechunk sessions and commits (a readonly session at a snapshot is
literally an AS OF query).

## Not yet

- dbplyr translation (filter on dim coords to sel/isel, select to variable
  subset, summarise to reductions) so that `tbl(con, "sst")` works
- chunk-aligned streaming fetch instead of render-then-paginate
- DataTree groups as schemas (open = "open_datatree" already connects,
  but the table listing assumes a flat Dataset)
- write support (dbWriteTable as to_zarr / icechunk commit)
- registry integration: `dbConnect(xarray(), sds::dsn("oisst"))` where the
  registry row carries the open function and kwargs
- a coords on/off toggle for renderings (n-D coordinates broadcast into
  every row of a data variable, which is faithful but can be heavy)
