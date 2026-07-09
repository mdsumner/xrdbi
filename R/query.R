#' Compile a structured selection to a Python expression
#'
#' A thin, inspectable alternative to writing the Python yourself. The
#' return value is a plain string, so `dbGetQuery(con, xr_query(...))`
#' and `dbGetQuery(con, "ds.sst.isel(time=0)")` are the same thing. Print
#' it, log it, put it in a registry row.
#'
#' Rules for `sel` and `isel` values:
#' * a length-2 vector becomes a Python `slice(a, b)` (a range on that
#'   dimension; for `sel` this is label-based and inclusive per xarray)
#' * a length-1 value is a scalar selection (drops the dimension)
#' * longer vectors become Python lists (fancy indexing)
#'
#' NOTE `isel` uses zero-based Python indices, faithfully: this function
#' interpolates values into Python source and does not translate them.
#' The compiled expression is the contract; inspect it.
#'
#' @param vars character vector of data variable names, NULL for all
#' @param sel named list of label-based selections
#' @param isel named list of integer (zero-based) selections
#' @param method optional method for inexact `sel` matches, e.g. "nearest"
#' @param tail extra Python method chain appended verbatim, e.g.
#'   `".mean('time')"`
#' @return character, a Python expression over `ds`
#' @export
#' @examples
#' xr_query(vars = "sst", sel = list(lat = c(-80, -60)), isel = list(time = 0))
#' # "ds[['sst']].sel(lat=slice(-80, -60)).isel(time=0)"
xr_query <- function(vars = NULL, sel = NULL, isel = NULL,
                     method = NULL, tail = NULL) {
  expr <- "ds"
  if (!is.null(vars)) {
    stopifnot(is.character(vars))
    if (length(vars) == 1L) {
      expr <- paste0(expr, "[", py_repr_string(vars), "]")
    } else {
      expr <- paste0(expr, "[[",
                     paste(vapply(vars, py_repr_string, ""), collapse = ", "),
                     "]]")
    }
  }
  if (!is.null(sel)) {
    args <- compile_indexers(sel)
    if (!is.null(method)) {
      args <- c(args, paste0("method=", py_repr_string(method)))
    }
    expr <- paste0(expr, ".sel(", paste(args, collapse = ", "), ")")
  }
  if (!is.null(isel)) {
    expr <- paste0(expr, ".isel(",
                   paste(compile_indexers(isel, integer = TRUE),
                         collapse = ", "), ")")
  }
  if (!is.null(tail)) {
    stopifnot(is.character(tail), length(tail) == 1L)
    expr <- paste0(expr, tail)
  }
  expr
}

compile_indexers <- function(x, integer = FALSE) {
  stopifnot(is.list(x), !is.null(names(x)), all(nzchar(names(x))))
  vapply(seq_along(x), function(i) {
    nm <- names(x)[[i]]
    if (!grepl("^[A-Za-z_][A-Za-z0-9_]*$", nm)) {
      stop("dimension name is not a valid Python identifier: ", nm,
           call. = FALSE)
    }
    val <- x[[i]]
    lit <- if (length(val) == 2L && !is.character(val)) {
      paste0("slice(", py_literal(val[[1L]], integer), ", ",
             py_literal(val[[2L]], integer), ")")
    } else if (length(val) == 1L) {
      py_literal(val, integer)
    } else {
      paste0("[", paste(vapply(val, py_literal, "", integer = integer),
                        collapse = ", "), "]")
    }
    paste0(nm, "=", lit)
  }, character(1L))
}

py_literal <- function(x, integer = FALSE) {
  if (inherits(x, "Date") || inherits(x, "POSIXct")) {
    return(py_repr_string(format(x, if (inherits(x, "Date")) "%Y-%m-%d"
                                    else "%Y-%m-%dT%H:%M:%S")))
  }
  if (is.character(x)) return(py_repr_string(x))
  if (is.logical(x)) return(if (isTRUE(x)) "True" else "False")
  if (integer) return(format(as.integer(x)))
  ## no scientific notation surprises in the compiled python
  format(x, digits = 15, scientific = FALSE, trim = TRUE)
}
