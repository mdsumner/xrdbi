#' xarray DBI driver
#'
#' Use with [DBI::dbConnect()] to open a connection to an xarray object in
#' a live Python session managed by reticulate.
#'
#' @export
#' @examples
#' \dontrun{
#' con <- dbConnect(xarray(), "https://example.com/oisst.zarr", open = "open_zarr")
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
#'   `"open_zarr"`, `"open_mfdataset"`, `"open_datatree"`). Extra named
#'   arguments in `...` are passed through as Python keyword arguments,
#'   e.g. `engine = "rasterio"`, `chunks = list()`, `decode_times = TRUE`.
#' * `builder`: an R function of one argument (the xarray module, not
#'   converted) returning a Dataset. Use this when construction needs more
#'   than a single open call, e.g. virtualizarr or icechunk session setup.
#' * `object`: an existing reticulate Python object (an xarray Dataset),
#'   adopted as-is. Handy when the object was built interactively with
#'   `reticulate::py_run_string()` or in a repl.
#'
#' The connection holds a reference to the Python object; nothing is
#' computed or converted until a result is fetched.
#'
#' @param drv result of [xarray()]
#' @param dsn character string openable by xarray
#' @param ... keyword arguments passed to the xarray open function
#' @param open name of the xarray open function, default "open_dataset"
#' @param builder function taking the xarray module, returning a Dataset
#' @param object an existing Python xarray object to adopt
#' @export
setMethod("dbConnect", "XarrayDriver",
  function(drv, dsn = NULL, ..., open = "open_dataset",
           builder = NULL, object = NULL) {

    supplied <- c(dsn = !is.null(dsn), builder = !is.null(builder),
                  object = !is.null(object))
    if (sum(supplied) != 1L) {
      stop("supply exactly one of 'dsn', 'builder', 'object'", call. = FALSE)
    }

    xr <- import("xarray", convert = FALSE)

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
