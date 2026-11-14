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
#' * strict inequalities on a dimension use the inclusive hull, then a
#'   boolean `.isel()` on that dimension's index trims the boundary, so
#'   the result is still an xarray object
#' * predicates on data variables, and mixed forms on one dimension, are
#'   kept as a pandas `.query()` applied Python-side, before conversion
#'   to R
#' * predicates on non-dimension coordinates (2-D `lat`/`lon` of a
#'   curvilinear grid, a 1-D coordinate along `time`) stay in that query
#'   for exactness, but are checked against the coordinates at collect
#'   time and the read narrowed to the index block holding every passing
#'   cell (`.isel()` with literal slices, visible in `show_query()`).
#'   Dimensions without coordinates are pinned to their positions first
#'   (`.assign_coords(y=range(n))`), so they render as they would
#'   unfiltered
#' * without such a query, `head()` and `select()` apply in R to the
#'   fetched rows, and `head(n)` first narrows the selection to the
#'   leading block that holds its `n` rows, so a peek at a huge variable
#'   reads one corner; [dplyr::show_query()] lists these R steps
#' * at collect time each hull dimension is asked for its direction,
#'   and the slice is oriented to match: `filter(latitude > 18,
#'   latitude < 19)` works identically on ascending and DESCENDING
#'   coordinates
#'
#' @param src an XarrayConnection
#' @param from a data variable name
#' @param ... unused
#' @return a lazy `tbl_xarray`; [dplyr::collect()] returns a tibble
#' @examples
#' \dontrun{
#' ## needs a Python environment with xarray (and here zarr, gcsfs)
#' library(dplyr)
#' con <- dbConnect(xarray(),
#'   "gs://gcp-public-data-arco-era5/ar/full_37-1h-0p25deg-chunk-1.zarr-v3",
#'   engine = "zarr", storage_options = reticulate::dict(token = "anon"))
#' u <- tbl(con, "100m_u_component_of_wind") |>
#'   filter(latitude > 18, latitude < 19, longitude >= 73, longitude <= 74,
#'          time >= as.POSIXct("1980-01-01", tz = "UTC"),
#'          time < as.POSIXct("1980-01-02", tz = "UTC"))
#' show_query(u)
#' collect(u)
#' tbl(con, "2m_temperature") |> head(3) |> collect()
#' }
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


collect_impl <- function(x, ...) {
  con <- x$con
  if (is.null(con)) stop("no connection on this tbl", call. = FALSE)
  cc <- tbl_compile(x, tbl_context(x))
  ## size the guard on what will be read: the xarray part of the
  ## statement (strict trims, the coordinate block and the head() block
  ## included), whatever a pandas stage does after
  sized <- cc$xarray
  n <- py_to_r(import_builtins(convert = FALSE)$eval(
    paste0("float((", sized, ").size)"), tbl_scope(con)))  # see guard_cells
  max_cells <- getOption("xrdbi.max_cells", 1e7)
  if (n > max_cells && !isTRUE(list(...)$force)) {
    stop(sprintf(paste0(
      "collect would materialize %s cells; constrain more dimensions ",
      "(e.g. a time range), raise options(xrdbi.max_cells=), or ",
      "collect(force = TRUE)"),
      fmt_count(n)), call. = FALSE)
  }
  run_tbl(con, cc, x)
}

## fetch a compiled tbl. A pandas-stage statement already applied
## head() and select(); otherwise they apply here, to the R-built rows.
## The guard has been checked by the caller, with its force.
run_tbl <- function(con, cc, x) {
  if (cc$pandas) return(dbGetQuery(con, cc$statement))
  res <- dbSendQuery(con, cc$statement)
  on.exit(dbClearResult(res))
  df <- dbFetch(res, n = if (is.null(x$head_n)) -1 else x$head_n,
                force = TRUE)
  if (!is.null(x$cols)) df <- df[x$cols]
  df
}

#' @export
as.data.frame.tbl_xarray <- function(x, ...) collect_impl(x, ...)

#' @export
#' @importFrom dplyr collect
collect.tbl_xarray <- function(x, ...) {
  dplyr::as_tibble(collect_impl(x, ...))
}

#' @export
as.data.frame.tbl_xarray <- function(x, ...) collect.tbl_xarray(x, ...)

#' @export
show_query.tbl_xarray <- function(x, ...) {
  cc <- tbl_compiled(x)
  cat(cc$statement, "\n")
  steps <- tbl_r_steps(x, cc$pandas)
  if (length(steps)) cat("# then in R: ", steps, "\n", sep = "")
  invisible(x)
}


#' @export
print.tbl_xarray <- function(x, ..., n = getOption("xrdbi.print_n", 6L)) {
  cat("<tbl_xarray> ", x$var, "\n", sep = "")
  cc <- tbl_compiled(x)
  cat("  python: ", cc$statement, "\n", sep = "")
  steps <- tbl_r_steps(x, cc$pandas)
  if (length(steps)) cat("  then R: ", steps, "\n", sep = "")
  ok <- FALSE
  if (!is.null(x$con) && isTRUE(x$con@ptr$valid) &&
      isTRUE(getOption("xrdbi.print_preview", TRUE))) {
    ok <- tryCatch({
      pv <- tbl_preview(x, n = n)
      cat("  sizes : ", pv$sizes_line, "\n", sep = "")
      print(dplyr::as_tibble(pv$df), n = n)
      if (nrow(pv$df) == 0L && pv$residual) {
        cat("# note: filters removed all previewed cells;",
            "the full result may still have rows\n")
      }
      TRUE
    }, error = function(e) FALSE)
  }
  if (ok) {
    cat("# lazy preview of the first cells (reads at most one chunk);",
        "collect() for the full result\n")
  } else {
    cat("  (lazy; collect() to render)\n")
  }
  invisible(x)
}

## a peek that clamps every dimension of the hull before rendering, so
## the read touches at most the first chunk. This is head() semantics:
## the first rows of the long-form frame ARE the first-corner cells in
## C order. Residual filters still apply, so fewer than n rows can
## survive on a filtered corner.
tbl_preview <- function(x, n = 6L) {
  con <- x$con
  ctx <- tbl_context(x)
  hull <- compile_tbl(x, dims = ctx$dims, descending = ctx$descending,
                      stage = "hull")
  sizes <- tbl_sizes(con, hull)
  sizes_line <- paste(sprintf("%s: %s", names(sizes),
                              format(unlist(sizes), big.mark = ",")),
                      collapse = ", ")
  ## clamp: 1 along every dim, up to n along the last (C-order head)
  clamp <- rep(1L, length(sizes))
  names(clamp) <- names(sizes)
  if (length(sizes)) {
    last <- length(sizes)
    clamp[last] <- min(sizes[[last]], as.integer(n))
  }
  x2 <- x
  x2$head_n <- as.integer(min(c(n, x$head_n[x$head_n >= 0L])))
  cc <- tbl_compile(x2, ctx, clamp = clamp, block = FALSE)
  list(df = run_tbl(con, cc, x2), sizes_line = sizes_line,
       residual = grepl(".query(", cc$statement, fixed = TRUE))
}

## compile with a live direction probe when connected, placeholders not
tbl_statement <- function(x) tbl_compiled(x)$statement

tbl_compiled <- function(x) {
  if (is.null(x$con) || !isTRUE(x$con@ptr$valid)) {
    sp <- split_preds(x, dims = NULL, descending = character())
    return(list(statement = compile_tbl(x, dims = NULL,
                                        descending = character()),
                pandas = tbl_needs_pandas(x, sp$residual)))
  }
  tbl_compile(x, tbl_context(x))
}

## the live facts compilation needs: the variable's dims, and which of
## the filtered dims are DESCENDING
tbl_context <- function(x) {
  con <- x$con
  dims <- tbl_dims(con, x$var)
  hull_dims <- intersect(unique(vapply(x$preds, `[[`, "", "var")), dims)
  descending <- hull_dims[vapply(hull_dims, dim_is_descending,
                                 logical(1), con = con)]
  list(dims = dims, descending = descending, coords = tbl_coords(con, x$var))
}

## a variable's non-dimension coordinates that have dimensions
tbl_coords <- function(con, var) {
  bt <- import_builtins(convert = FALSE)
  out <- py_to_r(bt$eval(paste0(
    "{c: list(v.coords[c].dims) for v in [ds[", py_repr_string(var), "]] ",
    "for c in v.coords if c not in v.dims and v.coords[c].ndim >= 1}"),
    tbl_scope(con)))
  if (!length(out)) list() else out
}

## compile against a live connection. Without a pandas stage, head(n)
## also narrows the selection to the leading block holding its first n
## rows (see head_block), so a peek at a huge variable reads one corner
tbl_compile <- function(x, ctx, clamp = NULL, block = TRUE) {
  sp <- split_preds(x, ctx$dims, ctx$descending)
  pandas <- tbl_needs_pandas(x, sp$residual)
  cb <- coord_block(x, ctx, sp$residual)
  prefix <- NULL
  if (block && !pandas && !is.null(x$head_n)) {
    base <- compile_tbl(x, ctx$dims, ctx$descending, clamp = clamp,
                        coord_block = cb)
    prefix <- head_block(unlist(tbl_sizes(x$con, base)), x$head_n)
  }
  cmp <- function(stage) {
    compile_tbl(x, ctx$dims, ctx$descending, stage = stage, clamp = clamp,
                prefix = prefix, coord_block = cb)
  }
  list(statement = cmp("full"), xarray = cmp("xarray"), hull = cmp("hull"),
       pandas = pandas)
}

## Filters on non-dimension coordinates (2-D lat/lon of a curvilinear
## grid, a 1-D coordinate along time) cannot be a .sel(), so they stay in
## the pandas query; but the coordinates are checked here, at compile
## time, and the selection narrowed to the index block holding every
## cell that passes. Only coordinates are read. NULL when no such filter.
coord_block <- function(x, ctx, residual) {
  on_coord <- Filter(function(p) p$var %in% names(ctx$coords), residual)
  if (!length(on_coord)) return(NULL)
  con <- x$con
  base <- compile_tbl(x, ctx$dims, ctx$descending, stage = "xarray")
  obj <- import_builtins(convert = FALSE)$eval(base, tbl_scope(con))
  preds <- lapply(on_coord, function(p) {
    list(p$var, p$op, param_to_py(con, if (p$op == "%in%") I(p$value) else p$value))
  })
  py_to_r(con@ptr$coord_block(obj, preds))
}

## head() and select() run python-side only after a pandas query (and
## for a negative head(), which pandas defines); otherwise R applies
## them to the fetched rows and the statement stays an xarray object
tbl_needs_pandas <- function(x, residual) {
  length(residual) > 0L || (!is.null(x$head_n) && x$head_n < 0L)
}

## the steps R applies after the fetch, as dplyr text for show_query()
tbl_r_steps <- function(x, pandas) {
  if (pandas) return(character(0))
  ## backtick names R can't parse bare, e.g. `2m_temperature`
  cols <- ifelse(make.names(x$cols) == x$cols, x$cols,
                 paste0("`", x$cols, "`"))
  steps <- c(if (!is.null(x$head_n)) sprintf("head(%d)", x$head_n),
             if (!is.null(x$cols)) sprintf("select(%s)",
                                           paste(cols, collapse = ", ")))
  if (!length(steps)) return(character(0))
  paste(steps, collapse = " |> ")
}

## The first n rows of a C-order long form lie in a leading block: while
## n fits within one step of a dim (n <= product of the later sizes), that
## dim is pinned to its first index; at the first dim where it doesn't,
## take ceiling(n / inner) indices and every later dim whole. Returns the
## counts to isel from 0, named by dim
head_block <- function(sizes, n) {
  out <- integer(0)
  for (i in seq_along(sizes)) {
    inner <- prod(sizes[-seq_len(i)])
    if (n <= inner) {
      out[names(sizes)[i]] <- 1L
    } else {
      out[names(sizes)[i]] <- as.integer(min(sizes[[i]], ceiling(n / inner)))
      break
    }
  }
  out
}

tbl_scope <- function(con) py_dict("ds", list(conn_ds(con)), convert = FALSE)

tbl_sizes <- function(con, statement) {
  py_to_r(import_builtins(convert = FALSE)$eval(
    paste0("dict((", statement, ").sizes)"), tbl_scope(con)))
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

## stage: "full" is the whole statement; "xarray" stops before any
## pandas stage (what is read, so it sizes the collect guard); "hull" is
## the inclusive .sel() superset alone. `coord_block` is list(block =
## named c(start, stop) per dim, index = named sizes of coordinate-less
## dims): the block holding every cell whose non-dimension coordinates
## pass their filters (see coord_block())
compile_tbl <- function(x, dims, descending, stage = "full", clamp = NULL,
                        prefix = NULL, coord_block = NULL) {
  sp <- split_preds(x, dims, descending)

  statement <- paste0("ds[", py_repr_string(x$var), "]")
  if (length(sp$sel_args)) {
    statement <- paste0(statement, ".sel(",
                        paste(sp$sel_args, collapse = ", "), ")")
  }
  if (stage == "hull") return(statement)
  if (length(sp$refine)) {
    statement <- paste0(statement, ".pipe(lambda a: a.isel(",
                        paste(sp$refine, collapse = ", "), "))")
  }
  if (length(coord_block$block)) {
    ## pin positions on coordinate-less dims, so narrowing keeps them
    if (length(coord_block$index)) {
      statement <- paste0(statement, ".assign_coords(",
        paste(sprintf("%s=range(%d)", names(coord_block$index),
                      vapply(coord_block$index, as.integer, 1L)),
              collapse = ", "), ")")
    }
    b <- coord_block$block
    statement <- paste0(statement, ".isel(",
      paste(sprintf("%s=slice(%d, %d)", names(b),
                    vapply(b, function(v) as.integer(v[[1L]]), 1L),
                    vapply(b, function(v) as.integer(v[[2L]]), 1L)),
            collapse = ", "), ")")
  }
  for (block in list(clamp, prefix)) {
    if (!is.null(block)) {
      statement <- paste0(statement, ".isel(",
        paste(sprintf("%s=slice(0, %d)", names(block), as.integer(block)),
              collapse = ", "), ")")
    }
  }
  if (stage == "full" && tbl_needs_pandas(x, sp$residual)) {
    statement <- paste0(statement, ".pipe(_xrdbi_render)")
    if (length(sp$residual)) {
      statement <- paste0(statement, ".query('",
                          paste(vapply(sp$residual, q_pred, ""),
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

## sort predicates into the inclusive .sel() hull, the strict trims on
## dim indexes, and the residual only a pandas query can apply
split_preds <- function(x, dims, descending) {
  vars_by <- split(x$preds, vapply(x$preds, `[[`, "", "var"))
  dim_names <- if (is.null(dims)) names(vars_by) else
    intersect(names(vars_by), dims)

  sel_args <- character(0)
  refine <- character(0)
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
      ## strict bounds over-fetch the boundary cell; trim it with a
      ## boolean isel on the dimension's index (pandas comparison, the
      ## same semantics as a query, so date strings keep their meaning)
      ## and the result stays a DataArray
      strict <- Filter(function(p) p$op %in% c(">", "<"), rng)
      if (length(strict)) {
        idx <- paste0("a.indexes[", py_repr_string(nm), "]")
        refine <- c(refine, paste0(nm, "=", paste(vapply(strict, function(p) {
          paste0("(", idx, " ", p$op, " ", py_literal(p$value), ")")
        }, ""), collapse = " & ")))
      }
    } else {
      ## mixed forms on one dimension: no pushdown, all residual
      residual <- c(residual, ps)
    }
  }
  list(sel_args = sel_args, refine = refine, residual = residual)
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
    ## the instant, as naive UTC: how xarray stores times
    return(paste0('"', format(x, "%Y-%m-%dT%H:%M:%S", tz = "UTC"), '"'))
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

## the index block holding every cell whose non-dimension coordinates
## pass their filters: per dim, [first, last + 1) of the positions where
## any cell passes; [0, 0) everywhere when none does. `index` lists the
## block's dims that have no coordinate, with their sizes
xrdbi_coord_block_py <- r"---(
def _xrdbi_coord_block(obj, preds):
    import numpy as np, operator
    ops = {'<': operator.lt, '<=': operator.le, '>': operator.gt,
           '>=': operator.ge, '==': operator.eq}
    mask = None
    for name, op, value in preds:
        c = obj.coords[name]
        m = c.isin(np.atleast_1d(value)) if op == '%in%' else ops[op](c, value)
        # coordinates over different dims broadcast to their union
        mask = m if mask is None else (mask & m)
    block, index = {}, {}
    if mask is None:
        return {'block': block, 'index': index}
    mask = mask.load()
    for d in mask.dims:
        other = [o for o in mask.dims if o != d]
        hit = np.asarray(mask.any(dim=other).values if other else mask.values)
        idx = np.flatnonzero(hit)
        block[d] = [int(idx[0]), int(idx[-1]) + 1] if len(idx) else [0, 0]
        if d not in obj.coords:
            # a dim without a coordinate renders positions; narrowing it
            # would renumber them, so it is given 0..n-1 first
            index[d] = int(obj.sizes[d])
    return {'block': block, 'index': index}
)---"
