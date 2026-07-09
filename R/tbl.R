#' A lazy dplyr table over an xarray variable
#'
#' `tbl(con, name)` returns a lazy object in the dtplyr/duckplyr mould:
#' dplyr verbs accumulate a spec, nothing touches Python until
#' [dplyr::collect()]. The spec compiles to a single Python statement
#' (inspect it with [dplyr::show_query()]), executed through
#' [DBI::dbGetQuery()] like any other statement.
#'
#' Predicate handling is pushdown-with-residuals:
#' * dimension-coordinate predicates compile to an inclusive `.sel()`
#'   hull, so only the chunks the slab touches are read
#' * anything the hull cannot express exactly (strict inequalities,
#'   predicates on data variables) is kept as a pandas `.query()`
#'   applied Python-side, before conversion to R
#' * at collect time each hull dimension is asked for its direction,
#'   and the slice is oriented to match: `filter(latitude > 18,
#'   latitude < 19)` works identically on ascending and DESCENDING
#'   coordinates
#'
#' @param src an XarrayConnection
#' @param from a data variable name
#' @param ... unused
#' @name tbl_xarray
NULL

#' @rdname tbl_xarray
#' @export
tbl.XarrayConnection <- function(src, from, ...) {
  stopifnot(is.character(from), length(from) == 1L)
  if (!dbExistsTable(src, from)) {
    stop("no such variable: ", from, "; see dbListTables()", call. = FALSE)
  }
  new_tbl_xarray(src, from)
}

new_tbl_xarray <- function(con, var, preds = list(), cols = NULL,
                           head_n = NULL) {
  structure(
    list(con = con, var = var, preds = preds, cols = cols, head_n = head_n),
    class = "tbl_xarray")
}

## ---- verbs -----------------------------------------------------------

#' @export
filter.tbl_xarray <- function(.data, ..., .preserve = FALSE) {
  quos <- rlang::enquos(...)
  new <- list()
  for (q in quos) {
    new <- c(new, parse_predicate(rlang::quo_get_expr(q),
                                  rlang::quo_get_env(q)))
  }
  if (!is.null(.data$con)) {
    fields <- dbListFields(.data$con, .data$var)
    bad <- setdiff(vapply(new, `[[`, "", "var"), fields)
    if (length(bad)) {
      stop("unknown field(s) in filter: ", paste(bad, collapse = ", "),
           "; fields are: ", paste(fields, collapse = ", "), call. = FALSE)
    }
  }
  .data$preds <- c(.data$preds, new)
  .data
}

#' @export
select.tbl_xarray <- function(.data, ...) {
  cols <- vapply(rlang::ensyms(...), rlang::as_string, "")
  if (!is.null(.data$con)) {
    fields <- dbListFields(.data$con, .data$var)
    bad <- setdiff(cols, fields)
    if (length(bad)) {
      stop("unknown field(s) in select: ", paste(bad, collapse = ", "),
           call. = FALSE)
    }
  }
  .data$cols <- cols
  .data
}

#' @export
head.tbl_xarray <- function(x, n = 6L, ...) {
  x$head_n <- as.integer(n)
  x
}

#' @export
collect.tbl_xarray <- function(x, ...) {
  con <- x$con
  if (is.null(con)) stop("no connection on this tbl", call. = FALSE)
  dims <- tbl_dims(con, x$var)
  hull_dims <- intersect(unique(vapply(x$preds, `[[`, "", "var")), dims)
  descending <- hull_dims[vapply(hull_dims, dim_is_descending,
                                 logical(1), con = con)]
  statement <- compile_tbl(x, dims = dims, descending = descending)
  hull <- compile_tbl(x, dims = dims, descending = descending, stage = "hull")
  bt <- import_builtins(convert = FALSE)
  scope <- py_dict("ds", list(conn_ds(con)), convert = FALSE)
  n <- py_to_r(bt$eval(paste0("int(", hull, ".size)"), scope))
  max_cells <- getOption("xrdbi.max_cells", 1e7)
  if (n > max_cells && !isTRUE(list(...)$force)) {
    stop(sprintf(paste0(
      "collect would materialize %s cells; constrain more dimensions ",
      "(e.g. a time range), raise options(xrdbi.max_cells=), or ",
      "collect(force = TRUE)"),
      format(n, big.mark = ",")), call. = FALSE)
  }
  dbGetQuery(con, statement)
}

#' @export
as.data.frame.tbl_xarray <- function(x, ...) collect.tbl_xarray(x, ...)

#' @export
show_query.tbl_xarray <- function(x, ...) {
  cat(tbl_statement(x), "\n")
  invisible(x)
}

#' @export
print.tbl_xarray <- function(x, ...) {
  cat("<tbl_xarray> ", x$var, "\n", sep = "")
  cat("  python: ", tbl_statement(x), "\n", sep = "")
  cat("  (lazy; collect() to render)\n")
  invisible(x)
}

## compile with a live direction probe when connected, placeholders not
tbl_statement <- function(x) {
  if (is.null(x$con) || !isTRUE(x$con@ptr$valid)) {
    return(compile_tbl(x, dims = NULL, descending = character()))
  }
  dims <- tbl_dims(x$con, x$var)
  hull_dims <- intersect(unique(vapply(x$preds, `[[`, "", "var")), dims)
  descending <- hull_dims[vapply(hull_dims, dim_is_descending,
                                 logical(1), con = x$con)]
  compile_tbl(x, dims = dims, descending = descending)
}

## ---- predicate parsing ----------------------------------------------

pred <- function(var, op, value) list(var = var, op = op, value = value)

parse_predicate <- function(ex, env) {
  ops <- c("==", "%in%", "<", "<=", ">", ">=")
  if (rlang::is_call(ex, "(")) return(parse_predicate(ex[[2L]], env))
  if (rlang::is_call(ex, "&") || rlang::is_call(ex, "&&")) {
    return(c(parse_predicate(ex[[2L]], env), parse_predicate(ex[[3L]], env)))
  }
  if (rlang::is_call(ex, "between") && length(ex) == 4L &&
      rlang::is_symbol(ex[[2L]])) {
    v <- rlang::as_string(ex[[2L]])
    return(list(pred(v, ">=", eval(ex[[3L]], env)),
                pred(v, "<=", eval(ex[[4L]], env))))
  }
  if (rlang::is_call(ex) && length(ex) == 3L &&
      rlang::as_string(ex[[1L]]) %in% ops) {
    op <- rlang::as_string(ex[[1L]])
    lhs <- ex[[2L]]; rhs <- ex[[3L]]
    if (rlang::is_symbol(lhs)) {
      return(list(pred(rlang::as_string(lhs), op, eval(rhs, env))))
    }
    if (rlang::is_symbol(rhs) && op != "%in%") {
      flip <- c(`<` = ">", `<=` = ">=", `>` = "<", `>=` = "<=", `==` = "==")
      return(list(pred(rlang::as_string(rhs), flip[[op]], eval(lhs, env))))
    }
  }
  stop("unsupported filter expression: ", deparse1(ex),
       "\nsupported: ==, %in%, <, <=, >, >=, between(), &",
       call. = FALSE)
}

## ---- compilation (pure: dims and descending are arguments) -----------

compile_tbl <- function(x, dims, descending, stage = "full") {
  vars_by <- split(x$preds, vapply(x$preds, `[[`, "", "var"))
  dim_names <- if (is.null(dims)) names(vars_by) else
    intersect(names(vars_by), dims)

  sel_args <- character(0)
  residual <- list()

  for (nm in names(vars_by)) {
    ps <- vars_by[[nm]]
    if (!nm %in% dim_names) {
      residual <- c(residual, ps)
      next
    }
    eq <- Filter(function(p) p$op == "==", ps)
    mem <- Filter(function(p) p$op == "%in%", ps)
    rng <- Filter(function(p) p$op %in% c("<", "<=", ">", ">="), ps)

    if (length(eq) == 1L && !length(mem) && !length(rng)) {
      sel_args <- c(sel_args,
                    paste0(nm, "=", py_literal(eq[[1L]]$value)))
    } else if (length(mem) == 1L && !length(eq) && !length(rng)) {
      vals <- mem[[1L]]$value
      sel_args <- c(sel_args, paste0(nm, "=[",
        paste(vapply(vals, py_literal, "", integer = FALSE),
              collapse = ", "), "]"))
    } else if (length(rng) && !length(eq) && !length(mem)) {
      los <- Filter(function(p) p$op %in% c(">", ">="), rng)
      his <- Filter(function(p) p$op %in% c("<", "<="), rng)
      lo_v <- if (length(los)) {
        v <- lapply(los, `[[`, "value"); v[[which.max(unlist(v))]]
      } else NULL
      hi_v <- if (length(his)) {
        v <- lapply(his, `[[`, "value"); v[[which.min(unlist(v))]]
      } else NULL
      lo_lit <- if (is.null(lo_v)) "None" else py_literal(lo_v)
      hi_lit <- if (is.null(hi_v)) "None" else py_literal(hi_v)
      bounds <- if (nm %in% descending) c(hi_lit, lo_lit) else c(lo_lit, hi_lit)
      sel_args <- c(sel_args,
                    paste0(nm, "=slice(", bounds[1L], ", ", bounds[2L], ")"))
      ## strict bounds over-fetch the boundary cell; refine python-side
      strict <- Filter(function(p) p$op %in% c(">", "<"), rng)
      residual <- c(residual, strict)
    } else {
      ## mixed forms on one dimension: no pushdown, all residual
      residual <- c(residual, ps)
    }
  }

  statement <- paste0("ds[", py_repr_string(x$var), "]")
  if (length(sel_args)) {
    statement <- paste0(statement, ".sel(", paste(sel_args, collapse = ", "),
                        ")")
  }

  needs_pandas <- stage == "full" &&
    (length(residual) || !is.null(x$cols) || !is.null(x$head_n))
  if (needs_pandas) {
    statement <- paste0(statement, ".to_dataframe().reset_index()")
    if (length(residual)) {
      statement <- paste0(statement, ".query('",
                          paste(vapply(residual, q_pred, ""),
                                collapse = " and "), "')")
    }
    if (!is.null(x$cols)) {
      statement <- paste0(statement, "[[",
        paste(vapply(x$cols, py_repr_string, ""), collapse = ", "), "]]")
    }
    if (!is.null(x$head_n)) {
      statement <- paste0(statement, ".head(", x$head_n, ")")
    }
  }
  statement
}

## a predicate as pandas query syntax (inner strings double-quoted,
## since the query itself is single-quoted in the statement)
q_pred <- function(p) {
  op <- if (p$op == "%in%") "in" else p$op
  val <- if (p$op == "%in%") {
    paste0("[", paste(vapply(p$value, q_literal, ""), collapse = ", "), "]")
  } else {
    q_literal(p$value)
  }
  paste0("`", p$var, "` ", op, " ", val)
}

q_literal <- function(x) {
  if (inherits(x, "Date")) return(paste0('"', format(x, "%Y-%m-%d"), '"'))
  if (inherits(x, "POSIXct")) {
    return(paste0('"', format(x, "%Y-%m-%dT%H:%M:%S"), '"'))
  }
  if (is.character(x)) {
    return(paste0('"', gsub('"', '\\\\"', x), '"'))
  }
  if (is.logical(x)) return(if (isTRUE(x)) "True" else "False")
  format(x, digits = 15, scientific = FALSE, trim = TRUE)
}

## ---- connection introspection (metadata only, no reads) --------------

tbl_dims <- function(con, var) {
  bt <- import_builtins(convert = FALSE)
  scope <- py_dict("ds", list(conn_ds(con)), convert = FALSE)
  as.character(py_to_r(bt$eval(
    paste0("list(ds[", py_repr_string(var), "].dims)"), scope)))
}

dim_is_descending <- function(d, con) {
  bt <- import_builtins(convert = FALSE)
  scope <- py_dict("ds", list(conn_ds(con)), convert = FALSE)
  out <- tryCatch(py_to_r(bt$eval(
    paste0("bool(ds.indexes[", py_repr_string(d),
           "].is_monotonic_decreasing)"), scope)),
    error = function(e) FALSE)
  isTRUE(out)
}
