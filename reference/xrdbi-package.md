# xrdbi: 'DBI' Backend for 'xarray' via a Live 'reticulate' Session

Treats a live Python session holding an 'xarray' <https://xarray.dev>
object as a database connection. Tables are variables, fields are
dimensions and coordinates, and queries are Python expressions (or
compiled from a small structured spec or from 'dplyr' verbs) evaluated
lazily against the dataset. Fetching renders the tidy long form, one row
per cell, built in R from the values; results can also render as an
in-memory raster.

## Articles

The [package website](https://mdsumner.github.io/xrdbi/) has a Get
started guide and articles with live examples: querying with dplyr,
parameters, the shape and types of results, data sources, rasters, chunk
maps, curvilinear grids and vector cubes, Python environments, and
design notes.

## How xarray maps to DBI

A connection holds one xarray Dataset, open in the Python session.

- **Tables** are its variables, data variables and coordinates alike:
  [`DBI::dbListTables()`](https://dbi.r-dbi.org/reference/dbListTables.html)
  lists them all, while `dbGetInfo()$tables` lists only the data
  variables.

- The **fields** of a table are its dimensions, then its non-dimension
  coordinates, then the variable itself: the columns its rows will have
  ([`DBI::dbListFields()`](https://dbi.r-dbi.org/reference/dbListFields.html)).

- A **statement** is a Python expression over `ds` (the Dataset) and
  `xr` (the module), such as `"ds.sst.isel(time=0)"`. It runs when sent;
  a selection reads nothing there, a computation runs in full (see
  [XarrayResult](https://mdsumner.github.io/xrdbi/reference/XarrayResult-class.md)).

- **Fetching** renders the result in long form, as xarray's
  `to_dataframe().reset_index()` would: one row per cell, a column per
  coordinate. Missing floats stay `NaN`, times become `POSIXct` in UTC
  (as xarray stores them), and the geometry of a vector data cube
  becomes a
  [`wk::wkb()`](https://paleolimbot.github.io/wk/reference/wkb.html)
  vector with its CRS when wk is installed (WKT strings otherwise).

## Functions by task

- **Connect**:
  [`xarray()`](https://mdsumner.github.io/xrdbi/reference/xarray.md) is
  the driver;
  [dbConnect()](https://mdsumner.github.io/xrdbi/reference/dbConnect-XarrayDriver-method.md)
  opens a path or URL, runs a builder function, or adopts a Python
  object;
  [`dbDisconnect()`](https://dbi.r-dbi.org/reference/dbDisconnect.html)
  closes it.

- **Look around**: print the connection, or use
  [`dbListTables()`](https://dbi.r-dbi.org/reference/dbListTables.html),
  [`dbListFields()`](https://dbi.r-dbi.org/reference/dbListFields.html)
  and [`dbGetInfo()`](https://dbi.r-dbi.org/reference/dbGetInfo.html)
  ([XarrayConnection](https://mdsumner.github.io/xrdbi/reference/XarrayConnection-class.md)).

- **Query in Python**: `dbGetQuery(con, statement)`, or
  [`dbSendQuery()`](https://dbi.r-dbi.org/reference/dbSendQuery.html)
  then [`dbFetch()`](https://dbi.r-dbi.org/reference/dbFetch.html) in
  pages; pass values from R with `params` and rebind with
  [`dbBind()`](https://dbi.r-dbi.org/reference/dbBind.html)
  ([XarrayResult](https://mdsumner.github.io/xrdbi/reference/XarrayResult-class.md)).
  [`xr_query()`](https://mdsumner.github.io/xrdbi/reference/xr_query.md)
  writes a statement from a structured selection.

- **Query with dplyr**:
  [tbl()](https://mdsumner.github.io/xrdbi/reference/tbl_xarray.md)
  gives a lazy table for
  [`filter()`](https://dplyr.tidyverse.org/reference/filter.html),
  [`select()`](https://dplyr.tidyverse.org/reference/select.html),
  [`head()`](https://rdrr.io/r/utils/head.html) and
  [`collect()`](https://dplyr.tidyverse.org/reference/compute.html),
  compiled to a statement that
  [`dplyr::show_query()`](https://dplyr.tidyverse.org/reference/explain.html)
  prints.

- **Read a whole variable**:
  [dbReadTable()](https://mdsumner.github.io/xrdbi/reference/dbReadTable-XarrayConnection-character-method.md).

- **Render other ways**:
  [`xr_raster()`](https://mdsumner.github.io/xrdbi/reference/xr_raster.md)
  gives a 2-D or 3-D slab in gdalraster's in-memory raster form;
  [`xr_chunks()`](https://mdsumner.github.io/xrdbi/reference/xr_chunks.md)
  maps the storage chunks a selection touches.

- **Use Python directly**:
  [`xr_dataset()`](https://mdsumner.github.io/xrdbi/reference/xr_dataset.md)
  and
  [`xr_module()`](https://mdsumner.github.io/xrdbi/reference/xr_dataset.md)
  return the Dataset and the xarray module, unconverted.

## Guards and options

Reads that materialize data are guarded: above a size they error, naming
the size, unless the call is given `force = TRUE`. Each guarded function
also takes the threshold as an argument; the options set the defaults.

- `xrdbi.max_cells` (default `1e7`): the most cells a read renders: the
  first [`dbFetch()`](https://dbi.r-dbi.org/reference/dbFetch.html) of a
  result (so
  [`dbGetQuery()`](https://dbi.r-dbi.org/reference/dbGetQuery.html)),
  [`dbReadTable()`](https://dbi.r-dbi.org/reference/dbReadTable.html),
  [`collect()`](https://dplyr.tidyverse.org/reference/compute.html) of a
  [tbl_xarray](https://mdsumner.github.io/xrdbi/reference/tbl_xarray.md),
  and
  [`xr_raster()`](https://mdsumner.github.io/xrdbi/reference/xr_raster.md).
  It sizes the result of a statement, not its computation:
  `.mean('time')` runs at
  [`dbSendQuery()`](https://dbi.r-dbi.org/reference/dbSendQuery.html),
  before the guard sees the result.

- `xrdbi.max_chunks` (default `1e6`): the most rows
  [`xr_chunks()`](https://mdsumner.github.io/xrdbi/reference/xr_chunks.md)
  returns.

- `xrdbi.print_n` (default `6`): the rows a printed
  [tbl_xarray](https://mdsumner.github.io/xrdbi/reference/tbl_xarray.md)
  previews, reading at most one chunk.

- `xrdbi.print_preview` (default `TRUE`): `FALSE` prints a
  [tbl_xarray](https://mdsumner.github.io/xrdbi/reference/tbl_xarray.md)'s
  compiled statement without the preview's data read (compiling still
  reads coordinates).

## R packages used when installed

- wk: geometry. Vector cube geometry arrives as
  [`wk::wkb()`](https://paleolimbot.github.io/wk/reference/wkb.html)
  (WKT strings without it), geometry `params` are sent through it, and
  [`xr_chunks()`](https://mdsumner.github.io/xrdbi/reference/xr_chunks.md)
  returns each chunk's rectangle as a
  [`wk::rct()`](https://paleolimbot.github.io/wk/reference/rct.html).

- sf: not needed, but
  [`sf::st_as_sfc()`](https://r-spatial.github.io/sf/reference/st_as_sfc.html)
  converts any of those.

- gdalraster: not needed by
  [`xr_raster()`](https://mdsumner.github.io/xrdbi/reference/xr_raster.md),
  but its output is in the form gdalraster's `read_ds()` returns, so
  `plot_raster()` takes it.

## Python requirements

Loading xrdbi declares its core Python requirements with
[`reticulate::py_require()`](https://rstudio.github.io/reticulate/reference/py_require.html):
'xarray' (which brings 'pandas' and 'numpy') and 'netCDF4', the netCDF
engine for local netCDF-3 and netCDF-4 files. When no Python is
configured, reticulate provisions them in a managed environment on first
use. Declare the IO engines your data needs the same way, before
connecting (or after: reticulate then switches to an environment that
adds them):

- zarr stores: `reticulate::py_require("zarr")`, with `"gcsfs"` or
  `"s3fs"` for cloud buckets

- netCDF/HDF5 over HTTPS via h5netcdf:
  `reticulate::py_require(c("h5netcdf", "h5py", "fsspec", "aiohttp"))`

- many files as one dataset (`open_mfdataset`):
  `reticulate::py_require("dask")`

- vector data cubes: `reticulate::py_require(c("xvec", "geopandas"))`

The 'gdalxarray' engine needs the GDAL Python bindings, which pip cannot
install: use a conda environment (conda-forge `gdal`) or an image with
GDAL, such as `ghcr.io/hypertidy/gdal-r-python`. With a Python you
configure yourself (`RETICULATE_PYTHON`, a conda environment), install
the packages there; reticulate does not provision into it.

## See also

Useful links:

- <https://github.com/mdsumner/xrdbi>

- <https://mdsumner.github.io/xrdbi/>

- Report bugs at <https://github.com/mdsumner/xrdbi/issues>

## Author

**Maintainer**: Michael Sumner <mdsumner@gmail.com>

Authors:

- Michael Sumner <mdsumner@gmail.com>

Other contributors:

- The GDAL/OGR contributors (test fixtures in inst/extdata/autotest, see
  inst/COPYRIGHTS) \[copyright holder\]

## Examples

``` r
if (FALSE) { # \dontrun{
## needs a Python environment with xarray (see Python requirements)
library(DBI)
f <- system.file("extdata/autotest/trmm.nc", package = "xrdbi")
con <- dbConnect(xarray(), f)
con
dbGetQuery(con, "ds.pcp.isel(time=0, latitude=0, longitude=slice(0, 3))")

library(dplyr)
tbl(con, "pcp") |> filter(latitude > -14, latitude < -13) |> collect()
dbDisconnect(con)
} # }
```
