#' Xarray connection
#'
#' Tables are variables (data variables and coordinates alike). Fields are
#' dimensions, then non-dimension coordinates, then the variable itself.
#' The Python object is reachable at any time via [xr_dataset()]; this
#' connection is a veneer, not a jail. Create one with
#' [dbConnect()][dbConnect,XarrayDriver-method]; queries are documented
#' with [XarrayResult-class], whole variables with
#' [dbReadTable()][dbReadTable,XarrayConnection,character-method].
#'
#' Transactions (`dbBegin()`, `dbCommit()`, `dbRollback()`) are not
#' implemented and error; the intended mapping is icechunk sessions and
#' commits.
#'
#' @slot ptr environment holding the Python handles (xr module, ds object)
#' @slot dsn the source string if the connection was opened from one
#' @param object,dbObj,conn an XarrayConnection
#' @param name a variable name
#' @param obj an R object, for `dbDataType()`
#' @param x character vector to quote
#' @param ... unused
#' @return
#' * `show()`: called for its output (source, dims, data variables)
#' * `dbIsValid()`: `TRUE` while the connection is open
#' * `dbDisconnect()`: `TRUE`, invisibly
#' * `dbGetInfo()`: a list with `dbname`, `db.version` (the xarray
#'   version), `tables` (data variables) and `sizes` (dims)
#' * `dbListTables()`: character, every variable (coordinates included)
#' * `dbExistsTable()`: logical
#' * `dbListFields()`: character, dims, then non-dimension coordinates,
#'   then the variable
#' * `dbDataType()`: character, the numpy dtype an R vector maps to
#' * `dbQuoteIdentifier()`, `dbQuoteString()`: [DBI::SQL()] holding
#'   Python source (`ds['name']`, `'text'`)
#' * `dbBegin()`, `dbCommit()`, `dbRollback()`: no return, they error
#' @examples
#' \dontrun{
#' ## needs a Python environment with xarray (see ?xrdbi)
#' f <- system.file("extdata/autotest/trmm.nc", package = "xrdbi")
#' con <- dbConnect(xarray(), f)
#' con
#' dbListTables(con)       # every variable, coordinates included
#' dbGetInfo(con)$tables   # the data variables
#' dbListFields(con, "pcp")
#' dbGetInfo(con)$sizes
#' dbDisconnect(con)
#' }
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
#' @return a reticulate Python object, not converted to R
#' @examples
#' \dontrun{
#' ## needs a Python environment with xarray (see ?xrdbi)
#' f <- system.file("extdata/autotest/trmm.nc", package = "xrdbi")
#' con <- dbConnect(xarray(), f)
#' ds <- xr_dataset(con)
#' ds$pcp$encoding
#' xr_module(con)$`__version__`
#' }
#' @export
xr_dataset <- function(conn) conn_ds(conn)

#' @rdname xr_dataset
#' @export
xr_module <- function(conn) conn_xr(conn)

#' @rdname XarrayConnection-class
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
  cat("  vars: ", fit_names(info$tables, getOption("width", 80) - 8), "\n",
      sep = "")
})

#' @rdname XarrayConnection-class
#' @export
#' @importFrom reticulate py_is_null_xptr
setMethod("dbIsValid", "XarrayConnection", function(dbObj, ...) {
  isTRUE(dbObj@ptr$valid) && !py_is_null_xptr(dbObj@ptr$ds)
})

#' @rdname XarrayConnection-class
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

#' @rdname XarrayConnection-class
#' @export
#' @importFrom reticulate import_builtins py_to_r
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

#' @rdname XarrayConnection-class
#' @export
setMethod("dbListTables", "XarrayConnection", function(conn, ...) {
  bt <- import_builtins(convert = FALSE)
  as.character(py_to_r(bt$list(conn_ds(conn)$variables)))
})

#' @rdname XarrayConnection-class
#' @export
setMethod("dbExistsTable", signature("XarrayConnection", "character"),
  function(conn, name, ...) {
    name %in% dbListTables(conn)
  })

#' @rdname XarrayConnection-class
#' @export
#' @importFrom reticulate py_get_item
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
#' The rendering is the tidy long form of `ds[name]`, exactly as
#' `to_dataframe().reset_index()` gives it: one row per cell, every
#' coordinate as a column. This materializes the variable, so it is
#' guarded: reads above `max_cells` cells error unless `force = TRUE`.
#' Set `options(xrdbi.max_cells = )` to taste.
#'
#' @param conn an XarrayConnection
#' @param name a variable name
#' @param ... unused
#' @param max_cells guard threshold, default `getOption("xrdbi.max_cells", 1e7)`
#' @param force bypass the guard
#' @return a data frame, one row per cell of the variable
#' @examples
#' \dontrun{
#' ## needs a Python environment with xarray (see ?xrdbi)
#' f <- system.file("extdata/autotest/trmm.nc", package = "xrdbi")
#' con <- dbConnect(xarray(), f)
#' dbReadTable(con, "latitude")
#' head(dbReadTable(con, "pcp"))
#' ## the guard: 1600 cells is over a limit of 100
#' try(dbReadTable(con, "pcp", max_cells = 100))
#' }
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

#' @rdname XarrayConnection-class
#' @export
setMethod("dbBegin", "XarrayConnection", function(conn, ...) no_txn())
#' @rdname XarrayConnection-class
#' @export
setMethod("dbCommit", "XarrayConnection", function(conn, ...) no_txn())
#' @rdname XarrayConnection-class
#' @export
setMethod("dbRollback", "XarrayConnection", function(conn, ...) no_txn())

#' @rdname XarrayConnection-class
#' @export
setMethod("dbDataType", "XarrayConnection", function(dbObj, obj, ...) {
  xr_data_type(obj)
})

#' @rdname XarrayConnection-class
#' @export
setMethod("dbQuoteIdentifier", signature("XarrayConnection", "character"),
  function(conn, x, ...) {
    SQL(paste0("ds[", vapply(x, py_repr_string, ""), "]"))
  })

#' @rdname XarrayConnection-class
#' @export
setMethod("dbQuoteString", signature("XarrayConnection", "character"),
  function(conn, x, ...) {
    SQL(vapply(x, py_repr_string, ""))
  })
