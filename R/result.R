#' Xarray result
#'
#' A statement is a Python expression evaluated with `ds` (the dataset)
#' and `xr` (the module) in scope. Evaluation at [DBI::dbSendQuery()] is
#' lazy in the xarray sense: it builds the selection graph, moves no
#' bytes. Rendering to the tidy data frame happens at the first
#' [DBI::dbFetch()].
#'
#' @export
setClass("XarrayResult", contains = "DBIResult",
  slots = list(ptr = "environment", statement = "character"))

#' @export
setMethod("dbSendQuery", signature("XarrayConnection", "character"),
  function(conn, statement, ...) {
    ds <- conn_ds(conn)
    xr <- conn_xr(conn)
    bt <- import_builtins(convert = FALSE)
    scope <- py_dict(c("ds", "xr"), list(ds, xr), convert = FALSE)
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

#' @export
setMethod("show", "XarrayResult", function(object) {
  cat("<XarrayResult>\n")
  cat("  ", object@statement, "\n", sep = "")
  if (!isTRUE(object@ptr$valid)) cat("  CLEARED\n")
})

#' @export
setMethod("dbIsValid", "XarrayResult", function(dbObj, ...) {
  isTRUE(dbObj@ptr$valid)
})

#' @export
setMethod("dbGetStatement", "XarrayResult", function(res, ...) {
  res@statement
})

render_result <- function(res, max_cells, force) {


  ptr <- res@ptr
  if (!is.null(ptr$df)) return(invisible(NULL))
  xr <- conn_xr(ptr$conn)
  bt <- import_builtins(convert = FALSE)
  obj <- ptr$obj
  is_xr <- py_to_r(bt$isinstance(obj, xr$DataArray)) ||
           py_to_r(bt$isinstance(obj, xr$Dataset))
  if (is_xr) {
    guard_cells(obj, max_cells, force)
    ptr$df <- obj$to_dataframe()$reset_index()
  } else {
    ## scalar or other python value: render as a one-cell frame
    pd <- import("pandas", convert = FALSE)
    ptr$df <- pd$DataFrame(list(value = list(obj)))

  }
  ptr$nrow <- py_to_r(bt$len(ptr$df))
  invisible(NULL)
}

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

    bt <- import_builtins(convert = FALSE)
    chunk <- py_get_item(ptr$df$iloc,
                         bt$slice(as.integer(start), as.integer(stop_)))
    out <- py_to_r(chunk)
    ## pandas index comes along as rownames; drop for DBI cleanliness
    rownames(out) <- NULL
    out
  })

#' @export
setMethod("dbHasCompleted", "XarrayResult", function(res, ...) {
  ptr <- res@ptr
  ## before first fetch, not completed
  if (is.na(ptr$nrow)) return(FALSE)
  ptr$cursor >= ptr$nrow
})

#' @export
setMethod("dbGetRowCount", "XarrayResult", function(res, ...) {
  cur <- res@ptr$cursor
  if (is.null(cur)) 0L else as.integer(cur)
})

#' @export
setMethod("dbClearResult", "XarrayResult", function(res, ...) {
  res@ptr$obj <- NULL
  res@ptr$df <- NULL
  res@ptr$valid <- FALSE
  invisible(TRUE)
})
