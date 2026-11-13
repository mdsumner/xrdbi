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
#' @section Parameters:
#' `params` is a named list; each element becomes a Python variable of
#' that name in the statement's scope, beside `ds` and `xr`, so
#' `dbGetQuery(con, "ds.sst.sel(lat=lat0, method='nearest')",
#' params = list(lat0 = -60))` selects at `-60`. `dbBind()` evaluates the
#' statement again with new values and restarts the fetch. Values become:
#' * length-1 vectors: numpy scalars (wrap in [I()] to keep a 1-element
#'   array); longer vectors: 1-D numpy arrays. Factors become strings.
#' * `Date`: `datetime64[D]`; `POSIXct`: `datetime64[ns]` as UTC, the way
#'   xarray stores times; `NA` becomes `NaT`
#' * geometry (an sfc, the geometry column of an sf, or any wk vector):
#'   shapely geometries via WKB, as a numpy array; with a CRS, a
#'   geopandas `GeoSeries` carrying it (needs geopandas), the form xvec's
#'   `extract_points()` and `zonal_stats()` take
#' * data frames: pandas DataFrames
#' * reticulate Python objects: unchanged
#'
#' Names must be Python identifiers; `ds`, `xr` and names starting with
#' `_xrdbi` are reserved.
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
#' @param params named list of values the statement refers to by name;
#'   see the Parameters section
#' @param ... unused
#' @return
#' * `dbSendQuery()`: an XarrayResult
#' * `dbBind()`: the result, invisibly, ready to fetch from the start
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
#'
#' ## values from R, by name
#' dbGetQuery(con,
#'   "ds.sst.sel(lat=xr.DataArray(lats, dims='pt'),
#'               lon=xr.DataArray(lons, dims='pt'), method='nearest')",
#'   params = list(lats = c(-60, -55), lons = c(100, 140)))
#' res <- dbSendQuery(con, "ds.sst.sel(time=t0)",
#'                    params = list(t0 = as.Date("1981-09-01")))
#' dbBind(res, list(t0 = as.Date("1981-09-02")))
#' dbFetch(res, n = 5)
#' dbClearResult(res)
#'
#' ## geometry: sf or wk vectors become shapely (a GeoSeries with a CRS),
#' ## e.g. for xvec
#' pts <- wk::xy(c(100.1, 140.2), c(-60.3, -55.4), crs = "EPSG:4326")
#' dbGetQuery(con, "ds.sst.xvec.extract_points(pts, x_coords='lon', y_coords='lat')",
#'            params = list(pts = pts))
#' }
#' @export
setClass("XarrayResult", contains = "DBIResult",
  slots = list(ptr = "environment", statement = "character"))

#' @rdname XarrayResult-class
#' @export
#' @importFrom reticulate py_dict
setMethod("dbSendQuery", signature("XarrayConnection", "character"),
  function(conn, statement, ..., params = NULL) {
    ptr <- new.env(parent = emptyenv())
    ptr$conn <- conn
    ptr$params <- params
    ## lazy in xarray's sense: a selection graph, no bytes yet
    ptr$obj <- eval_statement(conn, statement, params)
    reset_fetch(ptr)
    ptr$valid <- TRUE
    new("XarrayResult", ptr = ptr, statement = statement)
  })

## a fresh fetch state: nothing rendered, cursor at the start
reset_fetch <- function(ptr) {
  ptr$df <- NULL          # pandas frame, if the render path is taken
  ptr$plan <- NULL        # R-built long form, if the plan path is taken
  ptr$cursor <- 0L
  ptr$nrow <- NA_integer_
  invisible(ptr)
}

#' @rdname XarrayResult-class
#' @export
setMethod("dbBind", "XarrayResult", function(res, params, ...) {
  ptr <- res@ptr
  if (!isTRUE(ptr$valid)) stop("result has been cleared", call. = FALSE)
  ptr$params <- params
  ptr$obj <- eval_statement(ptr$conn, res@statement, params)
  reset_fetch(ptr)
  invisible(res)
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
