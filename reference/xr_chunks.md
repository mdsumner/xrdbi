# Map the chunks a selection touches

The block structure of a stored variable as a table: one row per storage
chunk that the selection touches, with each chunk's index range and
coordinate extent along every dimension, and a rectangle over the last
two dimensions (y and x, as for
[`xr_raster()`](https://mdsumner.github.io/xrdbi/reference/xr_raster.md)).
Run it on the whole variable (`"ds.sst"`) to see its chunk grid, or on a
selection (`"ds.sst.sel(lat=slice(-60, -50))"`) to see which chunks
reading it would touch.

## Usage

``` r
xr_chunks(
  x,
  statement = NULL,
  params = NULL,
  level = c("chunks", "shards"),
  max_chunks = getOption("xrdbi.max_chunks", 1e+06),
  force = FALSE
)
```

## Arguments

- x:

  an XarrayResult, or an XarrayConnection (with `statement`)

- statement:

  a Python expression selecting one stored variable, when `x` is a
  connection

- params:

  named list of values the statement refers to, when `x` is a connection
  (see
  [XarrayResult](https://mdsumner.github.io/xrdbi/reference/XarrayResult-class.md))

- level:

  `"chunks"` (the default) maps storage chunks; `"shards"` maps the
  shards of a sharded zarr v3 array, each a stored object holding a grid
  of inner chunks. At the chunk level a sharded array also gets a
  `d_shard` column per dimension, the shard each chunk lives in.

- max_chunks:

  guard on the number of rows, default
  `getOption("xrdbi.max_chunks", 1e6)`

- force:

  bypass the guard

## Value

a data frame, one row per chunk touched, chunks in C order (the last
dimension fastest). For each dimension `d`: `d_chunk`, the chunk's index
along `d`; `d_start` and `d_stop`, its 0-based index range, stop
exclusive (as in `isel(d=slice(start, stop))`); and, when `d` has a
coordinate, `d_min` and `d_max`, its extent: cell edges for a numeric
coordinate, the first and last values otherwise. Then `cells`, the
chunk's size in cells, and `selected`, how many of them the selection
reads. When the last two dimensions have numeric coordinates and the wk
package is installed, `geometry` is a
[`wk::rct()`](https://paleolimbot.github.io/wk/reference/rct.html) over
them, with the CRS when one is recorded (as for
[`xr_raster()`](https://mdsumner.github.io/xrdbi/reference/xr_raster.md)).
On a curvilinear grid, where 2-D longitude/latitude coordinates
(recognised by CF `standard_name`, units, or common names) span the last
two dimensions, each chunk also gets the envelope of its block of those
values (`lon_min`, `lon_max`, `lat_min`, `lat_max`, named after the
coordinates; cell centres, so half a cell inside the edges, and not
split at the antimeridian), and `geometry` is that envelope in OGC:CRS84
when the dimensions have no 1-D coordinates of their own. Attribute
`chunking` says where the shapes came from: `"storage"`, `"shards"`,
`"dask"` or `"none"`.

## Details

Chunk shapes come from the variable's `encoding["preferred_chunks"]`,
which xarray's backends (zarr, netCDF via netCDF4 or h5netcdf, GDAL via
gdalxarray, classic and multidimensional) set from the storage layout.
Without it, a dask-backed selection maps its own dask chunks; otherwise
the variable is one chunk. The selection is placed on the source grid by
its coordinate values, so it must be an orthogonal selection of one
stored variable (`sel()`/`isel()` by labels, slices, or lists);
pointwise selections onto a new dimension are not supported. Nothing but
coordinates is read.

## See also

[`xr_raster()`](https://mdsumner.github.io/xrdbi/reference/xr_raster.md)
to read the cells;
[XarrayResult](https://mdsumner.github.io/xrdbi/reference/XarrayResult-class.md)
for statements and `params`;
[xrdbi-package](https://mdsumner.github.io/xrdbi/reference/xrdbi-package.md)
for an overview.

## Examples

``` r
if (FALSE) { # \dontrun{
## needs a Python environment with xarray (and here zarr, gcsfs)
con <- dbConnect(xarray(),
  "gs://gcp-public-data-arco-era5/ar/full_37-1h-0p25deg-chunk-1.zarr-v3",
  engine = "zarr", storage_options = reticulate::dict(token = "anon"))
## one chunk per hour: a month of one variable reads 744 chunks
ch <- xr_chunks(con,
  "ds['2m_temperature'].sel(time=slice('1980-01-01', '1980-01-31'))")
nrow(ch)

## a GeoTIFF's block grid (gdalxarray needs the GDAL Python bindings;
## multidim = FALSE opens it as a classic raster: one variable,
## band_data, over (band, y, x))
tif <- system.file("extdata/autotest/rgbsmall.tif", package = "xrdbi")
con <- dbConnect(xarray(), tif, engine = "gdalxarray", multidim = FALSE)
ch <- xr_chunks(con, "ds.band_data")
ch[, c("band_chunk", "y_start", "y_stop", "x_start", "x_stop", "cells")]
plot(ch$geometry)
} # }
```
