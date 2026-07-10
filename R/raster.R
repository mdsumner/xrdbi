#' Render a result in gdalraster's in-memory raster format
#'
#' An alternate rendering: where [DBI::dbFetch()] gives the tidy
#' long-form data frame, `xr_raster()` gives the slab in the same
#' in-memory form as gdalraster `read_ds()` a plain vector of pixel
#' values in left-to-right, top-to-bottom order, band-sequential, with
#' a `gis` attribute carrying `type`, `bbox`, `dim`, `srs`, and
#' `datatype`. No dataset is created and no bytes go through GDAL; the
#' array converts directly via numpy (no pandas hop), and gdalraster
#' is not needed at all.
#'
#' The selected object must be a DataArray that squeezes to 2 or 3
#' dimensions: (y, x) for a single band, (band, y, x) for a stack
#' (e.g. a time series of slabs). The y and x dimension coordinates
#' must be 1-D and regular; the half-cell bbox expansion assumes
#' cell-centre coordinates. Ascending or descending coordinate order
#' is handled on either axis (rows and columns are reordered into
#' top-left pixel order). Curvilinear grids have no affine rendering
#' and error.
#'
#' @param x an XarrayResult, or an XarrayConnection (with `statement`)
#' @param statement a Python expression, when `x` is a connection
#' @param as_list if TRUE, a list of band vectors instead of one
#'   band-interleaved vector
#' @param max_cells guard threshold, as elsewhere
#' @param force bypass the guard
#' @return a vector (or list of band vectors) with attribute `gis`,
#'   interchangeable with the output of gdalraster `read_ds`
#' @export
xr_raster <- function(x, statement = NULL,  as_list = FALSE,
                      max_cells = getOption("xrdbi.max_cells", 1e7),
                      force = FALSE) {
  made_res <- FALSE
  if (inherits(x, "XarrayConnection")) {
    stopifnot(is.character(statement), length(statement) == 1L)
    res <- dbSendQuery(x, statement)
    made_res <- TRUE
    on.exit(dbClearResult(res), add = TRUE)
  } else if (inherits(x, "XarrayResult")) {
    res <- x
  } else {
    stop("x must be an XarrayResult or XarrayConnection", call. = FALSE)
  }

  con <- res@ptr$conn
  xr <- conn_xr(con)
  bt <- reticulate::import_builtins(convert = FALSE)
  np <- reticulate::import("numpy", convert = FALSE)
  obj <- res@ptr$obj

  if (py_to_r(bt$isinstance(obj, xr$Dataset))) {
    stop("statement selects a Dataset; select one variable, e.g. ",
         "ds['sst']...", call. = FALSE)
  }
  if (!py_to_r(bt$isinstance(obj, xr$DataArray))) {
    stop("statement did not produce an xarray DataArray", call. = FALSE)
  }

  obj <- obj$squeeze()
  ndim <- py_to_r(bt$int(obj$ndim))
  if (!ndim %in% c(2L, 3L)) {
    dn <- as.character(py_to_r(bt$list(obj$dims)))
    dd <- paste(dn, collapse = ", ")
    hint <- if (ndim > 3L) {
      extras <- dn[seq_len(ndim - 2L)]
      yx <- dn[c(ndim - 1L, ndim)]
      paste0(
        "; the band axis is a single flat dimension, so either select ",
        "(e.g. .isel(", extras[1L], "=0)) or flatten explicitly in the ",
        "statement: .stack(band=(",
        paste(sprintf("'%s'", extras), collapse = ", "),
        ")).transpose('band', ",
        paste(sprintf("'%s'", yx), collapse = ", "), ")")
    } else "; select further (e.g. isel a time)"
    stop("need a 2-D slab or 3-D (band, y, x) stack after squeezing; ",
         "got ", ndim, " dims: ", dd, hint, call. = FALSE)
  }

  dims <- as.character(py_to_r(bt$list(obj$dims)))
  ydim <- dims[ndim - 1L]
  xdim <- dims[ndim]
  coords <- as.character(py_to_r(bt$list(obj$coords)))
  for (d in c(ydim, xdim)) {
    if (!d %in% coords) {
      stop("dimension '", d, "' has no coordinate; cannot place cells",
           call. = FALSE)
    }
  }

  cvals <- function(d) as.numeric(py_to_r(np$asarray(py_get_item(obj, d))))
  yv <- cvals(ydim)
  xv <- cvals(xdim)
  step_of <- function(v, nm) {
    if (length(v) < 2L) {
      stop("cannot infer resolution from a length-1 '", nm,
           "' coordinate", call. = FALSE)
    }
    d <- diff(v)
    tol <- 1e-6 * abs(d[1L]) + 1e-12
    if (any(abs(d - d[1L]) > tol)) {
      stop("'", nm, "' coordinate is not regular; no affine rendering ",
           "(warp first)", call. = FALSE)
    }
    d[1L]
  }
  ystep <- step_of(yv, ydim)
  xstep <- step_of(xv, xdim)

  guard_cells(obj, max_cells, force)
  vals <- py_to_r(obj$values)

  nbands <- if (ndim == 3L) dim(vals)[1L] else 1L
  ysize <- length(yv)
  xsize <- length(xv)

  dtype <- switch(py_to_r(obj$dtype$name),
    float32 = "Float32", float64 = "Float64",
    int8 = "Int8", int16 = "Int16", int32 = "Int32", int64 = "Int64",
    uint8 = "Byte", uint16 = "UInt16", uint32 = "UInt32",
    stop("unsupported dtype for raster rendering: ",
         py_to_r(obj$dtype$name), call. = FALSE))

  xres <- abs(xstep); yres <- abs(ystep)
  bbox <- c(min(xv) - xres / 2, min(yv) - yres / 2,
            max(xv) + xres / 2, max(yv) + yres / 2)


  ## into GDAL's top-left, left-to-right, top-to-bottom pixel order
  orient <- function(m) {
    if (ystep > 0) m <- m[nrow(m):1L, , drop = FALSE]
    if (xstep < 0) m <- m[, ncol(m):1L, drop = FALSE]
    as.vector(t(m))
  }
  band_vec <- function(b) {
    m <- if (ndim == 3L) vals[b, , , drop = TRUE] else vals
    dim(m) <- c(ysize, xsize)
    orient(m)
  }

  out <- if (isTRUE(as_list)) {
    lapply(seq_len(nbands), band_vec)
  } else {
    unlist(lapply(seq_len(nbands), band_vec), use.names = FALSE)
  }

  wkt <- lift_srs(obj, coords, conn_ds(con))
  attr(out, "gis") <- list(type = "raster",
                           bbox = bbox,
                           dim = as.numeric(c(xsize, ysize, nbands)),
                           srs = wkt,  ## FIXME
                           datatype = rep(dtype, nbands))
  out
}

#' @importFrom reticulate py_get_item
## tier-1 srs lift, verbatim and in order of specificity:
## 1. a spatial_ref/crs COORDINATE on the object (rioxarray convention;
##    coordinates propagate through selection)
## 2. the object's own grid_mapping attr naming a variable in the
##    PARENT dataset (CF convention: the grid-mapping variable is a
##    0-d data variable and does NOT propagate through selection)
## 3. a variable named spatial_ref/crs in the parent dataset
## In every case we only read an authored crs_wkt/spatial_ref WKT
## string; CF parameter interpretation is deliberately out of scope.
lift_srs <- function(obj, coords, ds_parent) {
  wkt_from <- function(attrs) {
    for (key in c("crs_wkt", "spatial_ref")) {
      v <- tryCatch(py_to_r(attrs$get(key)), error = function(e) NULL)
      if (is.character(v) && length(v) == 1L && nzchar(v)) return(v)
    }
    NULL
  }
  var_attrs <- function(container, nm) {
    tryCatch(py_get_item(container, nm)$attrs, error = function(e) NULL)
  }

  ## 1. coordinate on the object itself
  for (nm in intersect(c("spatial_ref", "crs"), coords)) {
    w <- wkt_from(py_get_item(obj, nm)$attrs)
    if (!is.null(w)) return(w)
  }
  ## 2. follow the grid_mapping pointer into the parent dataset
  gm <- tryCatch(py_to_r(obj$attrs$get("grid_mapping")),
                 error = function(e) NULL)
  if (is.character(gm) && length(gm) == 1L && nzchar(gm)) {
    ## CF allows "name: coord ..." forms; take the leading token
    gm <- sub("[: ].*$", "", gm)
    a <- var_attrs(ds_parent, gm)
    if (!is.null(a)) {
      w <- wkt_from(a)
      if (!is.null(w)) return(w)
    }
  }
  ## 3. conventional names at the dataset level
  for (nm in c("spatial_ref", "crs")) {
    a <- var_attrs(ds_parent, nm)
    if (!is.null(a)) {
      w <- wkt_from(a)
      if (!is.null(w)) return(w)
    }
  }
  ""
}
