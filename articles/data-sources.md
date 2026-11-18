# Data sources

Anything xarray can open, xrdbi can query. This article is a cookbook of
sources: for each, which Python packages it needs and how to connect.
Most recipes run live against public data. The [Python
environments](https://mdsumner.github.io/xrdbi/articles/python-environments.md)
article covers getting the packages.

``` r
library(xrdbi)
library(DBI)
```

[`dbConnect()`](https://dbi.r-dbi.org/reference/dbConnect.html) takes
exactly one of three things:

- `dsn`, a string passed to an xarray open function: `open_dataset()` by
  default, or another named with `open =` (`"open_zarr"`,
  `"open_mfdataset"`, `"open_datatree"`). Other named arguments pass
  through as Python keyword arguments.
- `builder`, an R function given the xarray module that returns a
  Dataset, for anything that takes more than one call.
- `object`, a Dataset that already exists in the Python session.

## A local netCDF file

The netCDF4 engine is declared when xrdbi loads, so local netCDF-3 and
netCDF-4 files need nothing more:

``` r
f <- system.file("extdata/autotest/trmm.nc", package = "xrdbi")
con <- dbConnect(xarray(), f)
dbGetInfo(con)$sizes
#> $time
#> [1] 1
#> 
#> $latitude
#> [1] 40
#> 
#> $longitude
#> [1] 40
dbDisconnect(con)
```

## netCDF over HTTPS

h5netcdf reads netCDF-4 (HDF5) files over HTTPS by byte ranges, through
fsspec. One day of NOAA’s OISST sea surface temperature from NCEI:

``` r
reticulate::py_require(c("h5netcdf", "h5py", "fsspec", "aiohttp"))
oisst <- "https://www.ncei.noaa.gov/data/sea-surface-temperature-optimum-interpolation/v2.1/access/avhrr/198109/oisst-avhrr-v02r01.19810901.nc"
con <- dbConnect(xarray(), oisst, engine = "h5netcdf")
dbGetQuery(con, "ds.sst.sel(lat=slice(-56, -55), lon=slice(100, 101))")
#>                   time zlev     lat     lon         sst
#> 1  1981-09-01 12:00:00    0 -55.875 100.125 -0.06000000
#> 2  1981-09-01 12:00:00    0 -55.875 100.375 -0.14000000
#> 3  1981-09-01 12:00:00    0 -55.875 100.625 -0.17000000
#> 4  1981-09-01 12:00:00    0 -55.875 100.875 -0.11000000
#> 5  1981-09-01 12:00:00    0 -55.625 100.125  0.06000000
#> 6  1981-09-01 12:00:00    0 -55.625 100.375  0.00000000
#> 7  1981-09-01 12:00:00    0 -55.625 100.625  0.01000000
#> 8  1981-09-01 12:00:00    0 -55.625 100.875  0.09999999
#> 9  1981-09-01 12:00:00    0 -55.375 100.125  0.19000000
#> 10 1981-09-01 12:00:00    0 -55.375 100.375  0.17999999
#> 11 1981-09-01 12:00:00    0 -55.375 100.625  0.22999999
#> 12 1981-09-01 12:00:00    0 -55.375 100.875  0.34999999
#> 13 1981-09-01 12:00:00    0 -55.125 100.125  0.32999998
#> 14 1981-09-01 12:00:00    0 -55.125 100.375  0.34000000
#> 15 1981-09-01 12:00:00    0 -55.125 100.625  0.38999999
#> 16 1981-09-01 12:00:00    0 -55.125 100.875  0.50000000
dbDisconnect(con)
```

## Many files as one dataset

`open_mfdataset()` combines files along their shared dimensions. It
needs dask, and its variables are dask-backed, so a statement that
computes stays lazy until fetched. A builder passes the list of files:

``` r
reticulate::py_require("dask")
days <- sprintf("https://www.ncei.noaa.gov/data/sea-surface-temperature-optimum-interpolation/v2.1/access/avhrr/198109/oisst-avhrr-v02r01.198109%02d.nc", 1:2)
con <- dbConnect(xarray(), builder = function(xr) {
  xr$open_mfdataset(days, engine = "h5netcdf")
})
dbGetInfo(con)$sizes
#> $time
#> [1] 2
#> 
#> $zlev
#> [1] 1
#> 
#> $lat
#> [1] 720
#> 
#> $lon
#> [1] 1440
dbGetQuery(con, "ds.sst.sel(lat=-55.125, lon=100.125)")
#>                  time zlev     lat     lon  sst
#> 1 1981-09-01 12:00:00    0 -55.125 100.125 0.33
#> 2 1981-09-02 12:00:00    0 -55.125 100.125 0.48
dbDisconnect(con)
```

## zarr on Google Cloud

zarr stores on Google Cloud Storage need zarr and gcsfs, and
`storage_options` reaches gcsfs; `token = "anon"` reads a public bucket
without credentials. The ARCO ERA5 reanalysis:

``` r
reticulate::py_require(c("zarr", "gcsfs"))
era <- "gs://gcp-public-data-arco-era5/ar/full_37-1h-0p25deg-chunk-1.zarr-v3"
con <- dbConnect(xarray(), era, engine = "zarr",
                 storage_options = reticulate::dict(token = "anon"))
con
#> <XarrayConnection>
#>   dsn: gs://gcp-public-data-arco-era5/ar/full_37-1h-0p25deg-chunk-1.zarr-v3
#>   dims: time: 1323648, latitude: 721, longitude: 1440, level: 37
#>   vars: 100m_u_component_of_wind, 100m_v_component_of_wind, ... (273 total)
dbGetQuery(con,
  "ds['2m_temperature'].sel(time='1980-01-01T00', latitude=-42.75,
                            longitude=147.25)")
#>   latitude longitude       time 2m_temperature
#> 1   -42.75    147.25 1980-01-01       286.1443
dbDisconnect(con)
```

Leave `chunks` out, as here, for lazily indexed arrays and a fast
connection: `sel()` and `isel()` then read only the chunks they touch.
`chunks = reticulate::dict()` (Python `chunks={}`) wraps every variable
in dask at the storage chunking, which for a store of 273 variables in
1.3 million time chunks means minutes of graph building at connect time.
`open = "open_zarr"` defaults to dask, so pass
`chunks = reticulate::py_none()` with it.

## zarr on S3

The same, with s3fs; `anon = TRUE` reads a public bucket. NASA’s MUR sea
surface temperature on AWS (not run here: opening its metadata takes
about a minute):

``` r
reticulate::py_require(c("zarr", "s3fs"))
con <- dbConnect(xarray(), "s3://mur-sst/zarr-v1", engine = "zarr",
                 storage_options = reticulate::dict(anon = TRUE))
dbGetQuery(con, "ds.analysed_sst.sel(time='2020-01-01', lat=-42.5,
                                     lon=147.5, method='nearest')")
```

## Anything GDAL reads

The gdalxarray engine opens anything GDAL can, through GDAL’s virtual
file systems (`/vsicurl/`, `/vsis3/`, …). It needs the GDAL Python
bindings, which pip cannot install (see [Python
environments](https://mdsumner.github.io/xrdbi/articles/python-environments.md)).
A Cloud-Optimized GeoTIFF over HTTPS, opened as a classic raster
(`multidim = FALSE`), so that its bands are one variable, `band_data`:

``` r
tci <- "/vsicurl/https://sentinel-cogs.s3.us-west-2.amazonaws.com/sentinel-s2-l2a-cogs/36/Q/WD/2020/7/S2A_36QWD_20200701_0_L2A/TCI.tif"
cog <- dbConnect(xarray(), tci, engine = "gdalxarray", multidim = FALSE)
cog
#> <XarrayConnection>
#>   dsn: /vsicurl/https://sentinel-cogs.s3.us-west-2.amazonaws.com/sentinel-s2-l2a-cogs/36/Q/WD/2020/7/S2A_36QWD_20200701_0_L2A/TCI.tif
#>   dims: band: 3, y: 10980, x: 10980
#>   vars: band_data
dbGetQuery(cog, "ds.band_data.isel(y=5000, x=slice(5000, 5003))")
#>   band      x       y crs band_data
#> 1    1 549985 1850015   0       203
#> 2    1 549995 1850015   0       212
#> 3    1 550005 1850015   0       227
#> 4    2 549985 1850015   0       163
#> 5    2 549995 1850015   0       161
#> 6    2 550005 1850015   0       169
#> 7    3 549985 1850015   0       115
#> 8    3 549995 1850015   0       115
#> 9    3 550005 1850015   0       118
dbDisconnect(cog)
```

By default gdalxarray uses GDAL’s multidimensional API, which suits
netCDF, HDF5, zarr and multidimensional VRTs. This VRT mosaics the whole
daily OISST record, published by a scheduled pipeline. Its sources are
in a public S3 bucket, so GDAL needs `AWS_NO_SIGN_REQUEST`:

``` r
Sys.setenv(AWS_NO_SIGN_REQUEST = "YES")
vrt <- "/vsicurl/https://projects.pawsey.org.au/aad-index/oisst/oisst-mdim.vrt"
con <- dbConnect(xarray(), vrt, engine = "gdalxarray")
con
#> <XarrayConnection>
#>   dsn: /vsicurl/https://projects.pawsey.org.au/aad-index/oisst/oisst-mdim.vrt
#>   dims: time: 16492, zlev: 1, lat: 720, lon: 1440
#>   vars: anom, err, ice, sst
dbGetQuery(con, "ds.time.isel(time=-1)")
#>                  time
#> 1 2026-10-26 12:00:00
```

GDAL reads its configuration from the process environment when it
accesses data, so
[`Sys.setenv()`](https://rdrr.io/r/base/Sys.setenv.html) works even
after Python has started, and a missing setting fails at the first
query, not at connect: opening reads only the VRT. gdalxarray also takes
`config_options`, a dict of GDAL options applied around the open and
every read.

A connection is a snapshot. This VRT gains a day on a schedule, and a
connection made before that keeps answering from the old version; a new
connection sees the new day. For a record that does not move, open a
dated version: `oisst-mdim-20260630.vrt`, beside it, holds the days to
the end of June 2026.

``` r
dbDisconnect(con)
```

## Icechunk and virtual stores

A builder covers sources that take more than one call: kerchunk or
VirtualiZarr references, or an icechunk repository. Icechunk versions a
zarr store, and a readonly session at a branch, tag or snapshot is a
fixed version of the data.

This repository, on Source Cooperative, holds daily ocean salinity from
the BRAN reanalysis as a *virtual* store: its metadata and coordinates
are in the repository, and each data chunk is a byte range in the
original netCDF files on NCI’s THREDDS server. Icechunk reads virtual
chunks only from locations it is authorized for, so the builder
authorizes that server, and caps concurrent requests, since THREDDS
resets connections above about ten:

``` r
reticulate::py_require(c("icechunk", "zarr"))
con <- dbConnect(xarray(), builder = function(xr) {
  ic <- reticulate::import("icechunk", convert = FALSE)
  storage <- ic$s3_storage(
    bucket = "us-west-2.opendata.source.coop",
    prefix = "ausantarctic/ausantarctic-scratch/bluelink/bluelink-daily-salt/icechunk",
    region = "us-west-2", anonymous = TRUE)
  config <- ic$Repository$fetch_config(storage)
  config$max_concurrent_requests <- 4L
  repo <- ic$Repository$open(storage, config = config,
    authorize_virtual_chunk_access = reticulate::dict(
      "https://thredds.nci.org.au/" = ic$credentials$HttpAccess))
  xr$open_zarr(repo$readonly_session("main")$store, consolidated = FALSE,
               chunks = reticulate::py_none())
})
con
#> <XarrayConnection>
#>   dims: Time: 12265, st_ocean: 51, yt_ocean: 1500, xt_ocean: 3600
#>   vars: salt
```

Each chunk of `salt` is one day at one depth over a 300 by 300 cell
block, so a value at the surface is one range request:

``` r
dbGetQuery(con, "ds.salt.sel(Time='2020-01-01', st_ocean=0, yt_ocean=-45,
                             xt_ocean=147.5, method='nearest')")
#>                  Time st_ocean xt_ocean yt_ocean     salt
#> 1 2020-01-01 12:00:00      2.5   147.45   -45.05 35.11521
dbDisconnect(con)
```

## A Dataset built in Python

`object =` adopts a Dataset that already exists, however it was made:

``` r
reticulate::py_run_string("
import xarray, numpy
myds = xarray.Dataset({'v': (('y', 'x'), numpy.arange(6.).reshape(2, 3))},
                      coords={'y': [10, 20], 'x': [1, 2, 3]})
")
con <- dbConnect(xarray(), object = reticulate::py_eval("myds", convert = FALSE))
dbGetQuery(con, "ds.v")
#>    y x v
#> 1 10 1 0
#> 2 10 2 1
#> 3 10 3 2
#> 4 20 1 3
#> 5 20 2 4
#> 6 20 3 5
dbDisconnect(con)
```

The connection holds a reference to the object itself, so changes made
to it in place, such as `myds['w'] = myds.v * 2`, are seen by later
queries. Binding the Python name to a new object is not: the connection
keeps the object it was given.
