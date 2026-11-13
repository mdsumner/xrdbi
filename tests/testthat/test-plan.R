## A plain DataArray's long form is built in R (plan_result/plan_fetch,
## R/utils.R) instead of by pandas. It must match the pandas render
## exactly, whole and in chunks, for every shape it accepts; anything it
## declines must still render.

## the planned result, whole and in chunks of n, against the pandas render
expect_plan_matches <- function(con, statement, n = 7L) {
  obj <- DBI::dbSendQuery(con, statement)@ptr$obj
  plan <- plan_result(con, obj)
  expect_false(is.null(plan))
  ref <- frame_to_r(con, con@ptr$render(obj))

  whole <- DBI::dbGetQuery(con, statement)
  expect_identical(whole, ref)

  res <- DBI::dbSendQuery(con, statement)
  parts <- list()
  while (!DBI::dbHasCompleted(res)) parts[[length(parts) + 1L]] <- DBI::dbFetch(res, n = n)
  DBI::dbClearResult(res)
  chunked <- do.call(rbind, parts)
  rownames(chunked) <- NULL
  expect_identical(chunked, ref)
  invisible(whole)
}

test_that("dim coords, scalar coord and 2-D coord match the pandas render", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))
  ## (time, lat, lon) with zlev (0-d) and cell_area (lat, lon)
  df <- expect_plan_matches(con, "ds.sst")
  expect_named(df, c("time", "lat", "lon", "zlev", "cell_area", "sst"))
  expect_plan_matches(con, "ds.sst.isel(time=1)")
  expect_plan_matches(con, "ds.sst.sel(lat=slice(-75, -65))")
})

test_that("non-contiguous and reordered arrays flatten in C order", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))
  expect_plan_matches(con, "ds.sst.transpose('lon', 'time', 'lat')")
  expect_plan_matches(con, "ds.sst.isel(lon=slice(None, None, 2), lat=slice(None, None, -1))")
  expect_plan_matches(con, "ds.ice.isel(time=0, lon=2)")
})

test_that("dims without coordinates, descending coords", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))
  expect_plan_matches(con, "ds.sst.drop_vars(['lat', 'cell_area'])")
  expect_plan_matches(con, "xr.DataArray(ds.sst.values, dims=('a', 'b', 'c'), name='v')")

  dcon <- make_desc_con()
  on.exit(DBI::dbDisconnect(dcon), add = TRUE)
  expect_plan_matches(dcon, "ds.u")
})

test_that("string, cftime, timedelta coords and datetime values", {
  skip_if_no_xarray()
  skip_if_not(reticulate::py_module_available("cftime"),
              "python cftime not available")
  con <- DBI::dbConnect(xarray(), builder = function(xr) {
    reticulate::py_run_string(paste(
      "import xarray as _xr, numpy as _np, pandas as _pd",
      "_dsp = _xr.Dataset(",
      "  {'v': (('station', 'time'), _np.arange(6.).reshape(2, 3)),",
      "   'seen': (('station',), _pd.to_datetime(['2026-01-01', None]))},",
      "  coords={'station': ['A01', 'B02'],",
      "          'time': _xr.date_range('2026-01-01', periods=3,",
      "                                 calendar='360_day', use_cftime=True),",
      "          'lead': ('time', _pd.to_timedelta([0, 6, 12], 'h'))})",
      sep = "\n"), convert = FALSE)
    reticulate::py_eval("_dsp", convert = FALSE)
  })
  on.exit(DBI::dbDisconnect(con))
  expect_plan_matches(con, "ds.v", n = 4L)
  ## datetime-valued data with NaT
  df <- expect_plan_matches(con, "ds.seen", n = 1L)
  expect_equal(is.na(df$seen), c(FALSE, TRUE))
})

test_that("dbReadTable takes the plan for data variables", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))
  v <- reticulate::py_get_item(xr_dataset(con), "sst")
  expect_identical(DBI::dbReadTable(con, "sst"),
                   frame_to_r(con, con@ptr$render(v)))
})

test_that("Datasets match the pandas render", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))
  ## shared dims, plus a 0-d and a 2-D coordinate
  df <- expect_plan_matches(con, "ds")
  expect_named(df, c("time", "lat", "lon", "sst", "ice", "zlev", "cell_area"))
  expect_plan_matches(con, "ds[['sst']].isel(lon=slice(1, 4))")
  ## variables over different dims broadcast to every dim combination
  expect_plan_matches(con, paste0(
    "ds.assign(tmean=ds.sst.mean(('lat', 'lon')), clim=ds.sst.mean('time'),",
    " k=xr.DataArray(1.5), label=xr.DataArray(['a', 'b', 'c'], dims='time'))"))
  ## a variable stored in another dim order is transposed into the
  ## Dataset's order
  expect_plan_matches(con, "ds.assign(sst=ds.sst.transpose('lon', 'lat', 'time'))")
  ## dims without coordinates
  expect_plan_matches(con, "ds.drop_vars(['lat', 'cell_area'])")
})

test_that("the cell guard counts a Dataset's long form", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))
  ## 3 x 4 x 5 rows, two data variables
  expect_error(DBI::dbGetQuery(con, "ds", max_cells = 119), "120 cells")
  expect_equal(nrow(DBI::dbGetQuery(con, "ds", max_cells = 120)), 60L)
  expect_equal(nrow(DBI::dbGetQuery(con, "ds", max_cells = 1, force = TRUE)),
               60L)
})

test_that("the guard fires above 2^31 cells", {
  skip_if_no_xarray()
  ## a zero-stride view: 2e10 cells that cost no memory
  con <- DBI::dbConnect(xarray(), builder = function(xr) {
    reticulate::py_run_string(paste(
      "import xarray as _xr, numpy as _np",
      "_big = _xr.Dataset({'v': (('y', 'x'),",
      "  _np.broadcast_to(_np.float32(0), (200000, 100000)))})",
      sep = "\n"), convert = FALSE)
    reticulate::py_eval("_big", convert = FALSE)
  })
  on.exit(DBI::dbDisconnect(con))
  ## REGRESSION: reticulate wrapped the int size into a negative R
  ## integer, so the guard passed and the fetch tried to render it all
  expect_error(DBI::dbGetQuery(con, "ds.v"), "20,000,000,000 cells")
  expect_error(DBI::dbReadTable(con, "v"), "20,000,000,000 cells")
  expect_error(DBI::dbGetQuery(con, "ds"), "20,000,000,000 cells")
  expect_error(dplyr::collect(dplyr::tbl(con, "v")), "20,000,000,000 cells")
  ## and a head() still reads only its block
  expect_equal(nrow(dplyr::collect(utils::head(dplyr::tbl(con, "v"), 3))), 3L)
})

test_that("shapes the plan declines still render", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))
  declined <- c(
    "ds.sst.isel(time=0, lat=0, lon=0)",    # 0-d
    "ds.isel(time=0, lat=0, lon=0)",        # 0-d Dataset
    "ds.sst.isel(time=slice(0, 0))",        # empty
    "ds.isel(time=slice(0, 0))",            # empty Dataset
    "ds.lat",                               # name is its own dim
    "ds.cell_area",                         # name is a coordinate
    "ds.sst.stack(cell=('lat', 'lon'))",    # MultiIndex
    "ds.stack(cell=('lat', 'lon'))",        # MultiIndex Dataset
    "ds.sst.pipe(_xrdbi_render)")           # already a DataFrame
  for (s in declined) {
    obj <- DBI::dbSendQuery(con, s)@ptr$obj
    expect_null(plan_result(con, obj), label = s)
    expect_s3_class(suppressMessages(DBI::dbGetQuery(con, s)), "data.frame")
  }

  ## REGRESSION: a 0-d Dataset errored in to_dataframe; it is one row
  one <- DBI::dbGetQuery(con, "ds.isel(time=0, lat=0, lon=0)")
  expect_equal(nrow(one), 1L)
  expect_named(one, c("sst", "ice", "time", "lat", "lon", "zlev", "cell_area"))
})

test_that("dim_window equals the row arithmetic for every window", {
  bad <- character(0)
  for (n in 1:4) for (inner in 1:5) for (outer in 1:3) {
    N <- n * inner * outer
    for (s in 0:(N - 1)) for (l in 0:(N - s)) {
      ref <- as.integer(((s + seq_len(l) - 1) %/% inner) %% n + 1)
      if (!identical(dim_window(n, inner, s, l), ref)) {
        bad <- c(bad, sprintf("n=%d inner=%d start=%d len=%d", n, inner, s, l))
      }
    }
  }
  expect_identical(bad, character(0))
})
