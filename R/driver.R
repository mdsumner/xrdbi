#' xarray DBI driver
#'
#' Use with [DBI::dbConnect()] to open a connection to an xarray object in
#' a live Python session managed by reticulate (see
#' [dbConnect()][dbConnect,XarrayDriver-method]).
#'
#' @param object,drv,dbObj an XarrayDriver
#' @param obj an R object, for `dbDataType()`
#' @param ... unused
#' @return `xarray()`: an XarrayDriver. `dbDataType()`: character, the
#'   numpy dtype an R vector maps to. `dbUnloadDriver()`: `TRUE`,
#'   invisibly. `show()`: called for its output.
#' @seealso [dbConnect()][dbConnect,XarrayDriver-method] to open a
#'   connection; [xrdbi-package] for an overview.
#' @export
#' @importFrom methods new
#' @examples
#' drv <- xarray()
#' drv
#' dbDataType(drv, Sys.Date())
#' \dontrun{
#' ## needs a Python environment with xarray (see ?xrdbi)
#' f <- system.file("extdata/autotest/trmm.nc", package = "xrdbi")
#' con <- dbConnect(drv, f)
#'
#' ## open_zarr defaults to dask; chunks = None keeps the fast lazy path
#' reticulate::py_require("zarr")
#' con <- dbConnect(drv, "path/or/url.zarr", open = "open_zarr",
#'                  chunks = reticulate::py_none())
#' }
xarray <- function() {
  new("XarrayDriver")
}

#' @rdname xarray
#' @export
setClass("XarrayDriver", contains = "DBIDriver")

#' @rdname xarray
#' @export
setMethod("show", "XarrayDriver", function(object) {
  cat("<XarrayDriver>\n")
})

#' @rdname xarray
#' @export
setMethod("dbUnloadDriver", "XarrayDriver", function(drv, ...) {
  invisible(TRUE)
})

#' @rdname xarray
#' @export
setMethod("dbDataType", "XarrayDriver", function(dbObj, obj, ...) {
  xr_data_type(obj)
})

#' Connect to an xarray object
#'
#' Exactly one of `dsn`, `builder`, `object` must be supplied.
#'
#' * `dsn`: a string that xarray can open. Passed to `xr.<open>(dsn, ...)`
#'   where `open` is `"open_dataset"` by default (also useful:
#'   `"open_zarr"`, which defaults to dask, so pass
#'   `chunks = reticulate::py_none()` for the lazy path; `"open_mfdataset"`,
#'   which needs dask, `reticulate::py_require("dask")`; and
#'   `"open_datatree"`). Extra named arguments in `...` are passed
#'   through as Python keyword arguments, e.g. `engine = "h5netcdf"`,
#'   `decode_times = TRUE`, or `chunks = reticulate::dict()` (Python
#'   `chunks={}`: dask at the storage chunking; an R `list()` would
#'   become a Python list).
#'   `engine = "gdalxarray"` opens anything GDAL reads (it needs the GDAL
#'   Python bindings; see [xrdbi-package]). It uses GDAL's
#'   multidimensional API by default; `multidim = FALSE` uses the
#'   classic raster API, where a GeoTIFF or COG becomes one variable,
#'   `band_data`, over (band, y, x).
#' * `builder`: an R function of one argument (the xarray module, not
#'   converted) returning a Dataset. Use this when construction needs more
#'   than a single open call, e.g. virtualizarr or icechunk session setup.
#' * `object`: an existing reticulate Python object (an xarray Dataset),
#'   adopted as-is. Handy when the object was built interactively with
#'   `reticulate::py_run_string()` or in a repl.
#'
#' The connection holds a reference to the Python object. Opening reads
#' metadata; data are read when a result is fetched (see
#' [XarrayResult-class] for statements that compute).
#'
#' @param drv result of [xarray()]
#' @param dsn character string openable by xarray
#' @param ... keyword arguments passed to the xarray open function
#' @param open name of the xarray open function, default "open_dataset"
#' @param builder function taking the xarray module, returning a Dataset
#' @param object an existing Python xarray object to adopt
#' @return an [XarrayConnection][XarrayConnection-class]
#' @seealso [XarrayConnection-class] for what a connection offers;
#'   [XarrayResult-class] to query it with Python statements;
#'   [tbl()][tbl_xarray] to query it with dplyr verbs; the Python
#'   requirements in [xrdbi-package] for the engines a source needs.
#' @examples
#' \dontrun{
#' ## needs a Python environment with xarray (see ?xrdbi)
#' f <- system.file("extdata/autotest/trmm.nc", package = "xrdbi")
#' con <- dbConnect(xarray(), f)
#'
#' ## anything that takes more than one call
#' con <- dbConnect(xarray(), builder = function(xr) {
#'   xr$open_dataset(f)$rename(list(pcp = "precip"))
#' })
#' dbListTables(con)
#'
#' ## many files as one dataset (open_mfdataset needs dask)
#' reticulate::py_require("dask")
#' files <- c(f, f)  # e.g. a daily series of files on one grid
#' con <- dbConnect(xarray(), builder = function(xr) {
#'   xr$open_mfdataset(files, combine = "nested", concat_dim = "run")
#' })
#'
#' ## an object already built in the session
#' reticulate::py_run_string("import xarray; myds = xarray.Dataset()")
#' con <- dbConnect(xarray(), object = reticulate::py_eval("myds", convert = FALSE))
#' }
#' @export
#' @importFrom reticulate import r_to_py
setMethod("dbConnect", "XarrayDriver",
  function(drv, dsn = NULL, ..., open = "open_dataset",
           builder = NULL, object = NULL) {

    supplied <- c(dsn = !is.null(dsn), builder = !is.null(builder),
                  object = !is.null(object))
    if (sum(supplied) != 1L) {
      stop("supply exactly one of 'dsn', 'builder', 'object'", call. = FALSE)
    }

    xr <- reticulate::import("xarray", convert = FALSE)

    ds <- if (!is.null(dsn)) {
      dsn <- path.expand(dsn)
      stopifnot(is.character(dsn), length(dsn) == 1L)
      opener <- xr[[open]]
      kwargs <- lapply(list(...), r_to_py)
      do.call(opener, c(list(dsn), kwargs))
    } else if (!is.null(builder)) {
      stopifnot(is.function(builder))
      builder(xr)
    } else {
      object
    }

    ptr <- new.env(parent = emptyenv())
    ptr$xr <- xr
    ptr$ds <- ds
    ptr$valid <- TRUE

    reticulate::py_run_string(xrdbi_render_py)
    ptr$render <- reticulate::py_eval("_xrdbi_render", convert = FALSE)
    reticulate::py_run_string(xrdbi_columns_py)
    ptr$columns <- reticulate::py_eval("_xrdbi_columns", convert = FALSE)
    ptr$geom_crs <- reticulate::py_eval("_xrdbi_geom_crs", convert = FALSE)
    ## geometry columns arrive as wk::wkb, or WKT text without wk
    reticulate::py_run_string(sprintf("_XRDBI_GEOMETRY = '%s'",
      if (requireNamespace("wk", quietly = TRUE)) "wkb" else "wkt"))
    reticulate::py_run_string(xrdbi_geometry_py)
    ptr$geometry <- reticulate::py_eval("_xrdbi_geometry", convert = FALSE)
    reticulate::py_run_string(xrdbi_coord_block_py)
    ptr$coord_block <- reticulate::py_eval("_xrdbi_coord_block", convert = FALSE)
    reticulate::py_run_string(xrdbi_chunks_py)
    ptr$chunks <- reticulate::py_eval("_xrdbi_chunks", convert = FALSE)
    reticulate::py_run_string(xrdbi_members_py)
    ptr$members <- reticulate::py_eval("_xrdbi_members", convert = FALSE)
    reticulate::py_run_string(xrdbi_plan_py)
    ptr$plan <- reticulate::py_eval("_xrdbi_plan", convert = FALSE)
    ptr$slice <- reticulate::py_eval("_xrdbi_slice", convert = FALSE)

    ## in dbConnect, next to the render handle:
    reticulate::py_run_string(xrdbi_hint_py)
    ptr$hint <- reticulate::py_eval("_xrdbi_empty_hint", convert = FALSE)

    new("XarrayConnection",
        ptr = ptr,
        dsn = if (is.null(dsn)) NA_character_ else dsn)
  })

# map R vector types to numpy dtype strings
xr_data_type <- function(obj) {
  if (is.factor(obj)) return("str")
  switch(class(obj)[[1L]],
    integer   = "int32",
    numeric   = "float64",
    logical   = "bool",
    character = "str",
    Date      = "datetime64[D]",
    POSIXct   = "datetime64[ns]",
    integer64 = "int64",
    stop("unsupported R type: ", class(obj)[[1L]], call. = FALSE)
  )
}
