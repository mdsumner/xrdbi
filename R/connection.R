#' Xarray connection
#'
#' Tables are data variables. Fields are dimensions, then non-dimension
#' coordinates, then the variable itself. The Python object is reachable
#' at any time via [xr_dataset()]; this connection is a veneer, not a jail.
#'
#' @slot ptr environment holding the Python handles (xr module, ds object)
#' @slot dsn the source string if the connection was opened from one
#' @export
setClass("XarrayConnection", contains = "DBIConnection",
  slots = list(ptr = "environment", dsn = "character"))

conn_ds <- function(conn) {
  if (!isTRUE(conn@ptr$valid)) stop("connection is closed", call. = FALSE)
  conn@ptr$ds
}
conn_xr <- function(conn) conn@ptr$xr

#' Drop to the underlying Python objects
#'
#' `xr_dataset()` returns the xarray Dataset handle (not converted),
#' `xr_module()` the xarray module. Everything the veneer cannot express
#' is one step away.
#'
#' @param conn an XarrayConnection
#' @export
xr_dataset <- function(conn) conn_ds(conn)

#' @rdname xr_dataset
#' @export
xr_module <- function(conn) conn_xr(conn)

#' @export
setMethod("show", "XarrayConnection", function(object) {
  cat("<XarrayConnection>\n")
  if (!isTRUE(object@ptr$valid)) {
    cat("  DISCONNECTED\n")
    return(invisible(NULL))
  }
  if (!is.na(object@dsn)) cat("  dsn: ", object@dsn, "\n", sep = "")
  info <- dbGetInfo(object)
  dims <- paste(sprintf("%s: %s", names(info$sizes), unlist(info$sizes)),
                collapse = ", ")
  cat("  dims: ", dims, "\n", sep = "")
  cat("  vars: ", paste(info$tables, collapse = ", "), "\n", sep = "")
})

#' @export
setMethod("dbIsValid", "XarrayConnection", function(dbObj, ...) {
  isTRUE(dbObj@ptr$valid) && !py_is_null_xptr(dbObj@ptr$ds)
})

#' @export
setMethod("dbDisconnect", "XarrayConnection", function(conn, ...) {
  if (isTRUE(conn@ptr$valid)) {
    ds <- conn@ptr$ds
    ## file-backed datasets have close(); in-memory ones do too (no-op)
    tryCatch(ds$close(), error = function(e) NULL)
    conn@ptr$ds <- NULL
    conn@ptr$valid <- FALSE
  }
  invisible(TRUE)
})

#' @export
setMethod("dbGetInfo", "XarrayConnection", function(dbObj, ...) {
  ds <- conn_ds(dbObj)
  bt <- import_builtins(convert = FALSE)
  list(
    dbname = dbObj@dsn,
    db.version = py_to_r(conn_xr(dbObj)$`__version__`),
    tables = as.character(py_to_r(bt$list(ds$data_vars))),
    sizes = py_to_r(bt$dict(ds$sizes))
  )
})

#' @export
setMethod("dbListTables", "XarrayConnection", function(conn, ...) {
  bt <- import_builtins(convert = FALSE)
  as.character(py_to_r(bt$list(conn_ds(conn)$variables)))
})

#' @export
setMethod("dbExistsTable", signature("XarrayConnection", "character"),
  function(conn, name, ...) {
    name %in% dbListTables(conn)
  })

#' @export
setMethod("dbListFields", signature("XarrayConnection", "character"),
  function(conn, name, ...) {
    ds <- conn_ds(conn)
    if (!dbExistsTable(conn, name)) {
      stop("no such variable: ", name, call. = FALSE)
    }
    bt <- import_builtins(convert = FALSE)
    v <- py_get_item(ds, name)
    dims <- as.character(py_to_r(bt$list(v$dims)))
    if (name %in% dims) return(name)
    coords <- as.character(py_to_r(bt$list(v$coords)))
    c(dims, setdiff(coords, c(dims, name)), name)
  })

#' Read a variable as a tidy data frame
#'
#' The rendering is `ds[name].to_dataframe().reset_index()`: one row per
#' cell, dimension coordinates as columns. This materializes the variable,
#' so it is guarded: reads above `max_cells` cells error unless
#' `force = TRUE`. Set `options(xrdbi.max_cells = )` to taste.
#'
#' @param conn an XarrayConnection
#' @param name a data variable name
#' @param max_cells guard threshold, default `getOption("xrdbi.max_cells", 1e7)`
#' @param force bypass the guard
#' @export
setMethod("dbReadTable", signature("XarrayConnection", "character"),
  function(conn, name, ...,
           max_cells = getOption("xrdbi.max_cells", 1e7),
           force = FALSE) {
    ds <- conn_ds(conn)
    if (!dbExistsTable(conn, name)) {
      stop("no such variable: ", name, call. = FALSE)
    }
    v <- py_get_item(ds, name)
    guard_cells(v, max_cells, force)
    render_dataframe(conn, v)
  })

## transactions: reserved for icechunk session/commit semantics
no_txn <- function() {
  stop("transactions are not implemented; ",
       "intended future mapping is icechunk sessions and commits",
       call. = FALSE)
}

#' @export
setMethod("dbBegin", "XarrayConnection", function(conn, ...) no_txn())
#' @export
setMethod("dbCommit", "XarrayConnection", function(conn, ...) no_txn())
#' @export
setMethod("dbRollback", "XarrayConnection", function(conn, ...) no_txn())

#' @export
setMethod("dbDataType", "XarrayConnection", function(dbObj, obj, ...) {
  xr_data_type(obj)
})

#' @export
setMethod("dbQuoteIdentifier", signature("XarrayConnection", "character"),
  function(conn, x, ...) {
    SQL(paste0("ds[", vapply(x, py_repr_string, ""), "]"))
  })

#' @export
setMethod("dbQuoteString", signature("XarrayConnection", "character"),
  function(conn, x, ...) {
    SQL(vapply(x, py_repr_string, ""))
  })
