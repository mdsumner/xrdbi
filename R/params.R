## Query parameters: a named list whose elements become Python variables
## in the statement's scope, next to `ds` and `xr`. See ?XarrayResult-class.

## names a statement already uses, or that would shadow its scope
param_reserved <- c("ds", "xr")

## error unless `params` is NULL or a named list of valid, free names
check_param_names <- function(params) {
  if (is.null(params)) return(invisible(NULL))
  if (!is.list(params) || is.data.frame(params)) {
    stop("params must be a named list, e.g. params = list(lat0 = -60)",
         call. = FALSE)
  }
  nms <- names(params)
  if (!length(params)) return(invisible(NULL))
  if (is.null(nms) || any(!nzchar(nms))) {
    stop("every element of params needs a name: the name is the Python ",
         "variable the statement refers to", call. = FALSE)
  }
  bad <- nms[!grepl("^[A-Za-z_][A-Za-z0-9_]*$", nms)]
  if (length(bad)) {
    stop("params names must be Python identifiers: ",
         paste(bad, collapse = ", "), call. = FALSE)
  }
  taken <- nms[nms %in% param_reserved | startsWith(nms, "_xrdbi")]
  if (length(taken)) {
    stop("params names would shadow the statement scope: ",
         paste(taken, collapse = ", "), " (ds, xr and _xrdbi* are reserved)",
         call. = FALSE)
  }
  dup <- unique(nms[duplicated(nms)])
  if (length(dup)) {
    stop("duplicated params names: ", paste(dup, collapse = ", "),
         call. = FALSE)
  }
  invisible(NULL)
}

is_geometry <- function(x) {
  inherits(x, c("sf", "sfc", "wk_wkb", "wk_wkt", "wk_xy", "wk_rct",
                "wk_crc"))
}

## one R value as a Python object (not converted back)
param_to_py <- function(conn, x) {
  np <- import("numpy", convert = FALSE)
  if (inherits(x, "python.builtin.object")) return(x)
  if (is_geometry(x)) {
    if (!requireNamespace("wk", quietly = TRUE)) {
      stop("geometry params need the 'wk' package", call. = FALSE)
    }
    ## an sf data frame contributes its geometry column
    if (inherits(x, "sf")) x <- x[[attr(x, "sf_column")]]
    crs <- wk::wk_crs(x)
    crs <- if (is.null(crs)) NULL else wk::wk_crs_proj_definition(crs)
    wkb <- unclass(wk::as_wkb(x))
    attributes(wkb) <- NULL
    return(conn@ptr$geometry(r_to_py(wkb), crs))
  }
  if (is.data.frame(x)) return(r_to_py(x))
  if (is.atomic(x) && length(x)) {
    keep_array <- inherits(x, "AsIs")
    if (keep_array) class(x) <- setdiff(class(x), "AsIs")
    iso <- function(s) np$atleast_1d(np$array(as.list(ifelse(is.na(x), "NaT", s))))
    arr <- if (inherits(x, "Date")) {
      np$atleast_1d(iso(format(x, "%Y-%m-%d"))$astype("datetime64[D]"))
    } else if (inherits(x, "POSIXct")) {
      ## an instant, as naive UTC: how xarray stores times
      iso(format(x, "%Y-%m-%dT%H:%M:%OS6", tz = "UTC"))$astype("datetime64[ns]")
    } else {
      if (is.factor(x)) x <- as.character(x)
      x <- unclass(x)
      names(x) <- NULL
      np$atleast_1d(np$asarray(x))
    }
    ## R has no scalars: length 1 is a numpy scalar unless kept with I()
    if (length(x) == 1L && !keep_array) arr <- py_get_item(arr, 0L)
    return(arr)
  }
  r_to_py(x)
}

## the statement scope: ds, xr, the render helper, then the params
statement_scope <- function(conn, params) {
  check_param_names(params)
  keys <- c("ds", "xr", "_xrdbi_render")
  vals <- list(conn_ds(conn), conn_xr(conn), conn@ptr$render)
  if (length(params)) {
    keys <- c(keys, names(params))
    vals <- c(vals, lapply(params, function(x) param_to_py(conn, x)))
  }
  py_dict(keys, vals, convert = FALSE)
}

## evaluate a statement in its scope; Python's NameError gets a hint
eval_statement <- function(conn, statement, params) {
  scope <- statement_scope(conn, params)
  bt <- import_builtins(convert = FALSE)
  tryCatch(bt$eval(statement, scope), error = function(e) {
    msg <- conditionMessage(e)
    if (grepl("NameError", msg, fixed = TRUE)) {
      stop(msg, "\nxrdbi: a statement sees `ds`, `xr` and the names in ",
           "params; pass values with params = list(name = value)",
           call. = FALSE)
    }
    stop(e)
  })
}

## turns WKB into shapely geometries; a CRS makes a geopandas GeoSeries,
## the form xvec's extract_points() and zonal_stats() take with a CRS
xrdbi_geometry_py <- r"---(
def _xrdbi_geometry(wkb, crs):
    import numpy as np, shapely
    g = shapely.from_wkb(np.array(
        [None if b is None else bytes(b) for b in wkb], dtype=object))
    if crs is None:
        return g
    try:
        import geopandas
    except ImportError:
        raise ImportError(
            'a geometry parameter with a CRS becomes a geopandas.GeoSeries; '
            'install geopandas, or drop the CRS in R with wk::wk_set_crs(x, NULL)')
    return geopandas.GeoSeries(g, crs=crs)
)---"
