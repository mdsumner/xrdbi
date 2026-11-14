#' @section How xarray maps to DBI:
#' A connection holds one xarray Dataset, open in the Python session.
#' * **Tables** are its variables, data variables and coordinates alike:
#'   [DBI::dbListTables()] lists them all, while `dbGetInfo()$tables`
#'   lists only the data variables.
#' * The **fields** of a table are its dimensions, then its
#'   non-dimension coordinates, then the variable itself: the columns its
#'   rows will have ([DBI::dbListFields()]).
#' * A **statement** is a Python expression over `ds` (the Dataset) and
#'   `xr` (the module), such as `"ds.sst.isel(time=0)"`. It runs when
#'   sent; a selection reads nothing there, a computation runs in full
#'   (see [XarrayResult-class]).
#' * **Fetching** renders the result in long form, as xarray's
#'   `to_dataframe().reset_index()` would: one row per cell, a column per
#'   coordinate. Missing floats stay `NaN`, times become `POSIXct` in
#'   UTC (as xarray stores them), and the geometry of a vector data cube becomes a [wk::wkb()]
#'   vector with its CRS when wk is installed (WKT strings otherwise).
#'
#' @section Functions by task:
#' * **Connect**: [xarray()] is the driver; [dbConnect()][dbConnect,XarrayDriver-method]
#'   opens a path or URL, runs a builder function, or adopts a Python
#'   object; `dbDisconnect()` closes it.
#' * **Look around**: print the connection, or use `dbListTables()`,
#'   `dbListFields()` and `dbGetInfo()` ([XarrayConnection-class]).
#' * **Query in Python**: `dbGetQuery(con, statement)`, or `dbSendQuery()`
#'   then `dbFetch()` in pages; pass values from R with `params` and
#'   rebind with `dbBind()` ([XarrayResult-class]). [xr_query()] writes a
#'   statement from a structured selection.
#' * **Query with dplyr**: [tbl()][tbl_xarray] gives a lazy table for
#'   `filter()`, `select()`, `head()` and `collect()`, compiled to a
#'   statement that [dplyr::show_query()] prints.
#' * **Read a whole variable**: [dbReadTable()][dbReadTable,XarrayConnection,character-method].
#' * **Render other ways**: [xr_raster()] gives a 2-D or 3-D slab in
#'   gdalraster's in-memory raster form; [xr_chunks()] maps the storage
#'   chunks a selection touches.
#' * **Use Python directly**: [xr_dataset()] and [xr_module()] return the
#'   Dataset and the xarray module, unconverted.
#'
#' @section Guards and options:
#' Reads that materialize data are guarded: above a size they error,
#' naming the size, unless the call is given `force = TRUE`. Each guarded
#' function also takes the threshold as an argument; the options set the
#' defaults.
#' * `xrdbi.max_cells` (default `1e7`): the most cells a read renders: the
#'   first `dbFetch()` of a result (so `dbGetQuery()`), `dbReadTable()`,
#'   `collect()` of a [tbl_xarray], and [xr_raster()]. It sizes the
#'   result of a statement, not its computation: `.mean('time')` runs at
#'   `dbSendQuery()`, before the guard sees the result.
#' * `xrdbi.max_chunks` (default `1e6`): the most rows [xr_chunks()]
#'   returns.
#' * `xrdbi.print_n` (default `6`): the rows a printed [tbl_xarray]
#'   previews, reading at most one chunk.
#' * `xrdbi.print_preview` (default `TRUE`): `FALSE` prints a
#'   [tbl_xarray]'s compiled statement without the preview's data read
#'   (compiling still reads coordinates).
#'
#' @section R packages used when installed:
#' * wk: geometry. Vector cube geometry arrives as [wk::wkb()] (WKT
#'   strings without it), geometry `params` are sent through it, and
#'   [xr_chunks()] returns each chunk's rectangle as a [wk::rct()].
#' * sf: not needed, but `sf::st_as_sfc()` converts any of those.
#' * gdalraster: not needed by [xr_raster()], but its output is in the
#'   form gdalraster's `read_ds()` returns, so `plot_raster()` takes it.
#'
#' @section Python requirements:
#' Loading xrdbi declares its core Python requirements with
#' [reticulate::py_require()]: 'xarray' (which brings 'pandas' and
#' 'numpy') and 'netCDF4', the netCDF engine for local netCDF-3 and
#' netCDF-4 files. When no Python is configured, reticulate provisions
#' them in a managed environment on first use. Declare the IO engines
#' your data needs the same way, before connecting (or after: reticulate
#' then switches to an environment that adds them):
#'
#' * zarr stores: `reticulate::py_require("zarr")`, with `"gcsfs"` or
#'   `"s3fs"` for cloud buckets
#' * netCDF/HDF5 over HTTPS via h5netcdf:
#'   `reticulate::py_require(c("h5netcdf", "h5py", "fsspec", "aiohttp"))`
#' * many files as one dataset (`open_mfdataset`):
#'   `reticulate::py_require("dask")`
#' * vector data cubes: `reticulate::py_require(c("xvec", "geopandas"))`
#'
#' The 'gdalxarray' engine needs the GDAL Python bindings, which pip
#' cannot install: use a conda environment (conda-forge `gdal`) or an
#' image with GDAL, such as `ghcr.io/hypertidy/gdal-r-python`. With a
#' Python you configure yourself (`RETICULATE_PYTHON`, a conda
#' environment), install the packages there; reticulate does not
#' provision into it.
#'
#' @examples
#' \dontrun{
#' ## needs a Python environment with xarray (see Python requirements)
#' library(DBI)
#' f <- system.file("extdata/autotest/trmm.nc", package = "xrdbi")
#' con <- dbConnect(xarray(), f)
#' con
#' dbGetQuery(con, "ds.pcp.isel(time=0, latitude=0, longitude=slice(0, 3))")
#'
#' library(dplyr)
#' tbl(con, "pcp") |> filter(latitude > -14, latitude < -13) |> collect()
#' dbDisconnect(con)
#' }
"_PACKAGE"

## usethis namespace: start
## usethis namespace: end
NULL

## Package-level imports: roxygen builds NAMESPACE from these tags, so
## every generic we register an S3 method on (tbl, filter, select,
## collect, show_query, head) must be imported here or roxygen emits a
## plain export() instead of S3method() and dispatch silently breaks.
#' @import DBI
#' @import methods
#' @importFrom reticulate import import_builtins py_to_r r_to_py
#' @importFrom reticulate py_get_item py_dict py_run_string py_eval
#' @importFrom reticulate py_call py_module_available py_is_null_xptr
#' @importFrom dplyr tbl filter select collect show_query
#' @importFrom utils head
NULL
