#' Xarray result
#'
#' A statement is a Python expression evaluated with `ds` (the dataset)
#' and `xr` (the module) in scope. Evaluation at [DBI::dbSendQuery()] is
#' lazy in the xarray sense: it builds the selection graph, moves no
#' bytes. Rendering to the tidy data frame happens at the first
#' [DBI::dbFetch()]: one row per cell, every coordinate as a column,
#' exactly as xarray's `to_dataframe().reset_index()` gives it.
#' [DBI::dbGetQuery()] is the two in one step.
#'
#' The first fetch is guarded: an xarray result above `max_cells` cells
#' errors unless `force = TRUE` (see `options(xrdbi.max_cells = )`).
#' Later fetches page through the same rows.
#'
#' @slot ptr environment holding the evaluated Python object and the
#'   fetch state
#' @slot statement the Python expression
#' @param conn an XarrayConnection
#' @param statement a Python expression over `ds` (and `xr`)
#' @param object,dbObj,res an XarrayResult
#' @param n number of rows to fetch, `-1` for all remaining
#' @param max_cells guard threshold for the first fetch, default
#'   `getOption("xrdbi.max_cells", 1e7)`
#' @param force bypass the guard
#' @param ... unused
#' @return
#' * `dbSendQuery()`: an XarrayResult
#' * `dbFetch()`: a data frame of the next `n` rows
#' * `dbHasCompleted()`, `dbIsValid()`: logical
#' * `dbGetRowCount()`: the number of rows fetched so far
#' * `dbGetStatement()`: the statement
#' * `dbClearResult()`: `TRUE`, invisibly
#' * `show()`: called for its output
#' @examples
#' \dontrun{
#' ## needs a Python environment with xarray (and here h5netcdf)
#' con <- dbConnect(xarray(), "oisst.nc", engine = "h5netcdf")
#' res <- dbSendQuery(con, "ds.sst.isel(time=0)")
#' dbFetch(res, n = 5)
#' dbFetch(res, n = 5)
#' dbGetRowCount(res)
#' dbClearResult(res)
#'
#' dbGetQuery(con, "ds.sst.sel(lat=slice(-56, -55), lon=slice(100, 101))")
#' }
#' @export
setClass("XarrayResult", contains = "DBIResult",
  slots = list(ptr = "environment", statement = "character"))

#' @rdname XarrayResult-class
#' @export
#' @importFrom reticulate py_dict
setMethod("dbSendQuery", signature("XarrayConnection", "character"),
  function(conn, statement, ...) {
    ds <- conn_ds(conn)
    xr <- conn_xr(conn)
    bt <- import_builtins(convert = FALSE)
    scope <- py_dict(c("ds", "xr", "_xrdbi_render"),
                     list(ds, xr, conn@ptr$render), convert = FALSE)


    obj <- bt$eval(statement, scope)

    ptr <- new.env(parent = emptyenv())
    ptr$conn <- conn
    ptr$obj <- obj          # unevaluated xarray object (or plain python value)
    ptr$df <- NULL          # pandas frame, rendered on first fetch
    ptr$cursor <- 0L
    ptr$nrow <- NA_integer_
    ptr$valid <- TRUE


    new("XarrayResult", ptr = ptr, statement = statement)
  })

#' @rdname XarrayResult-class
#' @export
setMethod("show", "XarrayResult", function(object) {
  cat("<XarrayResult>\n")
  cat("  ", object@statement, "\n", sep = "")
  if (!isTRUE(object@ptr$valid)) cat("  CLEARED\n")
})

#' @rdname XarrayResult-class
#' @export
#' @import DBI
setMethod("dbIsValid", "XarrayResult", function(dbObj, ...) {
  isTRUE(dbObj@ptr$valid)
})

#' @rdname XarrayResult-class
#' @export
setMethod("dbGetStatement", "XarrayResult", function(res, ...) {
  res@statement
})

render_result <- function(res, max_cells, force) {
  ptr <- res@ptr
  if (!is.null(ptr$df) || !is.null(ptr$plan)) return(invisible(NULL))
  xr <- conn_xr(ptr$conn)
  bt <- import_builtins(convert = FALSE)
  obj <- ptr$obj
  is_xr <- py_to_r(bt$isinstance(obj, xr$DataArray)) ||
    py_to_r(bt$isinstance(obj, xr$Dataset))
  if (is_xr) guard_cells(obj, max_cells, force)

  ## a plain DataArray: R builds the coordinate columns (plan_result)
  if (is_xr) ptr$plan <- plan_result(ptr$conn, obj)
  if (!is.null(ptr$plan)) {
    ptr$nrow <- ptr$plan$n
    return(invisible(NULL))
  }

  ## everything else renders through the python helper: Dataset,
  ## DataArray (incl. 0-d and dim coords), and plain python scalars
  ptr$df <- ptr$conn@ptr$render(obj)
  ptr$nrow <- py_to_r(bt$len(ptr$df))

  if (is_xr && identical(ptr$nrow, 0L)) {
    h <- tryCatch(py_to_r(ptr$conn@ptr$hint(obj, conn_ds(ptr$conn))),
                  error = function(e) NULL)
    if (!is.null(h) && is.character(h)) message("xrdbi: ", h)
  }
  invisible(NULL)
}
#' @rdname XarrayResult-class
#' @export
setMethod("dbFetch", "XarrayResult",
  function(res, n = -1, ...,
           max_cells = getOption("xrdbi.max_cells", 1e7),
           force = FALSE) {
    ptr <- res@ptr
    if (!isTRUE(ptr$valid)) stop("result has been cleared", call. = FALSE)
    render_result(res, max_cells, force)

    start <- ptr$cursor
    stop_ <- if (n < 0) ptr$nrow else min(ptr$nrow, start + as.integer(n))
    ptr$cursor <- stop_

    if (!is.null(ptr$plan)) return(plan_fetch(ptr$conn, ptr$plan, start, stop_))
    bt <- import_builtins(convert = FALSE)
    chunk <- py_get_item(ptr$df$iloc,
                         bt$slice(as.integer(start), as.integer(stop_)))
    frame_to_r(ptr$conn, chunk)
  })

#' @rdname XarrayResult-class
#' @export
setMethod("dbHasCompleted", "XarrayResult", function(res, ...) {
  ptr <- res@ptr
  ## before first fetch, not completed
  if (is.na(ptr$nrow)) return(FALSE)
  ptr$cursor >= ptr$nrow
})

#' @rdname XarrayResult-class
#' @export
setMethod("dbGetRowCount", "XarrayResult", function(res, ...) {
  cur <- res@ptr$cursor
  if (is.null(cur)) 0L else as.integer(cur)
})

#' @rdname XarrayResult-class
#' @export
setMethod("dbClearResult", "XarrayResult", function(res, ...) {
  res@ptr$obj <- NULL
  res@ptr$df <- NULL
  res@ptr$plan <- NULL
  res@ptr$valid <- FALSE
  invisible(TRUE)
})
