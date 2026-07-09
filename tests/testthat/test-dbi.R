skip_if_no_xarray <- function() {
  skip_if_not(reticulate::py_module_available("xarray"),
              "python xarray not available")
  skip_if_not(reticulate::py_module_available("pandas"),
              "python pandas not available")
}

## small OISST-shaped fixture: (time, lat, lon)
make_con <- function() {
  DBI::dbConnect(xarray(), builder = function(xr) {
    reticulate::py_run_string(paste(
      "import xarray as _xr, numpy as _np, pandas as _pd",
      "_rng = _np.random.default_rng(42)",
      "_ds = _xr.Dataset(",
      "  {'sst': (('time','lat','lon'), _rng.random((3,4,5)).astype('float32')),",
      "   'ice': (('time','lat','lon'), _rng.random((3,4,5)).astype('float32'))},",
      "  coords={'time': _pd.date_range('2026-01-01', periods=3),",
      "          'lat': _np.linspace(-80,-60,4),",
      "          'lon': _np.linspace(0,40,5)})",
      sep = "\n"), convert = FALSE)
    reticulate::py_eval("_ds", convert = FALSE)
  })
}

test_that("connect, list, fields, info", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))

  expect_true(DBI::dbIsValid(con))
  expect_setequal(DBI::dbListTables(con), c("sst", "ice"))
  expect_true(DBI::dbExistsTable(con, "sst"))
  expect_false(DBI::dbExistsTable(con, "nope"))

  fields <- DBI::dbListFields(con, "sst")
  expect_equal(fields, c("time", "lat", "lon", "sst"))

  info <- DBI::dbGetInfo(con)
  expect_equal(info$sizes$time, 3L)
  expect_equal(info$sizes$lon, 5L)
})

test_that("dbReadTable renders tidy long form with guard", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))

  df <- DBI::dbReadTable(con, "sst")
  expect_s3_class(df, "data.frame")
  expect_equal(nrow(df), 3L * 4L * 5L)
  expect_setequal(names(df), c("time", "lat", "lon", "sst"))
  expect_s3_class(df$time, "POSIXct")

  expect_error(DBI::dbReadTable(con, "sst", max_cells = 10),
               "exceeds the guard")
  expect_silent(DBI::dbReadTable(con, "sst", max_cells = 10, force = TRUE))
})

test_that("dbGetQuery evaluates python over ds and xr", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))

  df <- DBI::dbGetQuery(con, "ds.sst.isel(time=0).sel(lat=slice(-80,-70))")
  expect_equal(nrow(df), 2L * 5L)
  expect_true(all(df$lat <= -70))

  ## scalar results come back as a one-cell frame
  m <- DBI::dbGetQuery(con, "float(ds.sst.mean())")
  expect_equal(dim(m), c(1L, 1L))
  expect_true(is.numeric(m$value))
})

test_that("dbSendQuery is lazy and dbFetch paginates", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))

  res <- DBI::dbSendQuery(con, "ds.sst.isel(time=0)")
  expect_false(DBI::dbHasCompleted(res))

  a <- DBI::dbFetch(res, n = 7)
  expect_equal(nrow(a), 7L)
  expect_false(DBI::dbHasCompleted(res))

  b <- DBI::dbFetch(res)
  expect_equal(nrow(b), 20L - 7L)
  expect_true(DBI::dbHasCompleted(res))
  expect_equal(DBI::dbGetRowCount(res), 20L)

  DBI::dbClearResult(res)
  expect_false(DBI::dbIsValid(res))
})

test_that("xr_query compiles the expected python", {
  expect_equal(
    xr_query(vars = "sst", sel = list(lat = c(-80, -60)), isel = list(time = 0)),
    "ds['sst'].sel(lat=slice(-80, -60)).isel(time=0)")
  expect_equal(
    xr_query(vars = c("sst", "ice")),
    "ds[['sst', 'ice']]")
  expect_equal(
    xr_query(sel = list(time = as.Date("2026-01-02")), method = "nearest"),
    "ds.sel(time='2026-01-02', method='nearest')")
  expect_equal(
    xr_query(vars = "sst", isel = list(lon = c(0, 2, 4))),
    "ds['sst'].isel(lon=[0, 2, 4])")
  expect_equal(
    xr_query(vars = "sst", tail = ".mean('time')"),
    "ds['sst'].mean('time')")
})

test_that("xr_query round-trips through dbGetQuery", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))

  q <- xr_query(vars = "sst", isel = list(time = 0),
                sel = list(lat = c(-80, -70)))
  df <- DBI::dbGetQuery(con, q)
  expect_equal(nrow(df), 2L * 5L)
})

test_that("escape hatch returns live python handles", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))

  ds <- xr_dataset(con)
  expect_s3_class(ds, "python.builtin.object")
  xr <- xr_module(con)
  expect_s3_class(xr, "python.builtin.object")
})
