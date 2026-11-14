# Render a result in gdalraster's in-memory raster format

An alternate rendering: where
[`DBI::dbFetch()`](https://dbi.r-dbi.org/reference/dbFetch.html) gives
the tidy long-form data frame, `xr_raster()` gives the slab in the same
in-memory form as gdalraster `read_ds()` a plain vector of pixel values
in left-to-right, top-to-bottom order, band-sequential, with a `gis`
attribute carrying `type`, `bbox`, `dim`, `srs`, and `datatype`. No
dataset is created and no bytes go through GDAL; the array converts
directly via numpy (no pandas hop), and gdalraster is not needed at all.

## Usage

``` r
xr_raster(
  x,
  statement = NULL,
  as_list = FALSE,
  max_cells = getOption("xrdbi.max_cells", 1e+07),
  force = FALSE,
  params = NULL
)
```

## Arguments

- x:

  an XarrayResult, or an XarrayConnection (with `statement`)

- statement:

  a Python expression, when `x` is a connection

- as_list:

  if TRUE, a list of band vectors instead of one band-sequential vector

- max_cells:

  guard threshold, as elsewhere

- force:

  bypass the guard

- params:

  named list of values the statement refers to, when `x` is a connection
  (see
  [XarrayResult](https://mdsumner.github.io/xrdbi/reference/XarrayResult-class.md))

## Value

a vector (or list of band vectors) with attribute `gis`, interchangeable
with the output of gdalraster `read_ds`

## Details

The selected object must be a DataArray that squeezes to 2 or 3
dimensions: (y, x) for a single band, (band, y, x) for a stack (e.g. a
time series of slabs). y and x are taken by position, the last two
dimensions, whatever their names: an array stored (lon, lat) renders
transposed, so put it in order in the statement
(`.transpose('lat', 'lon')`). The y and x coordinates must be 1-D,
numeric and regular (to their storage precision: float32 grids are
fine); the half-cell bbox expansion assumes cell-centre coordinates.
Ascending or descending coordinate order is handled on either axis (rows
and columns are reordered into top-left pixel order). Curvilinear grids
have no affine rendering, and vector data cubes (an xvec geometry
dimension) no raster at all; both error with the reason.

`srs` is the CRS found in this order: an index carrying one (xproj's
`CRSIndex`, as gdalxarray sets; rasterix's `RasterIndex`); WKT in a
`crs_wkt` or `spatial_ref` attribute of a `spatial_ref`/`crs`
coordinate, of the variable named by the CF `grid_mapping` attribute, or
of a dataset variable named `spatial_ref` or `crs`; and last the CF
parameters of that `grid_mapping` variable, through pyproj when it is
installed. `""` when none is found.

## See also

[`xr_chunks()`](https://mdsumner.github.io/xrdbi/reference/xr_chunks.md)
for the storage chunks under a slab;
[XarrayResult](https://mdsumner.github.io/xrdbi/reference/XarrayResult-class.md)
for statements and `params`;
[xrdbi-package](https://mdsumner.github.io/xrdbi/reference/xrdbi-package.md)
for an overview.

## Examples

``` r
if (FALSE) { # \dontrun{
## needs a Python environment with xarray (see ?xrdbi)
f <- system.file("extdata/autotest/trmm.nc", package = "xrdbi")
con <- dbConnect(xarray(), f)
r <- xr_raster(con, "ds.pcp.isel(time=0)")
attr(r, "gis")$dim
attr(r, "gis")$bbox

## or from a result
res <- dbSendQuery(con, "ds.pcp.isel(time=0)")
r <- xr_raster(res)
dbClearResult(res)
} # }
```
