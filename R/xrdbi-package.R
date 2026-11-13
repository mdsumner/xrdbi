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
#' * vector data cubes: `reticulate::py_require(c("xvec", "geopandas"))`
#'
#' The 'gdalxarray' engine needs the GDAL Python bindings, which pip
#' cannot install: use a conda environment (conda-forge `gdal`) or an
#' image with GDAL, such as `ghcr.io/hypertidy/gdal-r-python`. With a
#' Python you configure yourself (`RETICULATE_PYTHON`, a conda
#' environment), install the packages there; reticulate does not
#' provision into it.
#'
#' @keywords internal
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
