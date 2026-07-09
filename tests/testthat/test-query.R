## These tests need no Python: xr_query() returns strings, and those
## strings are the contract that a future tbl()/dplyr layer compiles to.
## They run everywhere, including CI without a Python environment.

test_that("xr_query compiles the documented forms", {
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
  expect_equal(xr_query(), "ds")
})

test_that("single var is DataArray access, multiple is Dataset subset", {
  expect_equal(xr_query(vars = "sst"), "ds['sst']")
  expect_equal(xr_query(vars = c("a", "b", "c")), "ds[['a', 'b', 'c']]")
})

test_that("length-2 non-character values become slices, everywhere", {
  ## documented rule: length 2 = slice; this includes isel, where a pair
  ## of specific indices must be written as three-or-more or via list()
  expect_equal(xr_query(isel = list(time = c(0, 10))),
               "ds.isel(time=slice(0, 10))")
  ## Date pairs slice too
  expect_equal(
    xr_query(sel = list(time = as.Date(c("1981-09-01", "1981-09-05")))),
    "ds.sel(time=slice('1981-09-01', '1981-09-05'))")
  ## character pairs do NOT slice (documented: !is.character)
  expect_equal(xr_query(sel = list(time = c("1981-09-01", "1981-09-05"))),
               "ds.sel(time=['1981-09-01', '1981-09-05'])")
})

test_that("scalar literal forms", {
  expect_equal(xr_query(sel = list(lat = -80)), "ds.sel(lat=-80)")
  expect_equal(xr_query(sel = list(name = "station_1")),
               "ds.sel(name='station_1')")
  expect_equal(xr_query(sel = list(mask = TRUE)), "ds.sel(mask=True)")
  expect_equal(xr_query(isel = list(time = -1)), "ds.isel(time=-1)")
  ## POSIXct formats to seconds resolution
  t0 <- as.POSIXct("1981-09-01 12:00:00", tz = "UTC")
  expect_equal(xr_query(sel = list(time = t0)),
               "ds.sel(time='1981-09-01T12:00:00')")
})

test_that("numeric literals avoid scientific notation", {
  expect_equal(xr_query(isel = list(time = 16000)), "ds.isel(time=16000)")
  expect_equal(xr_query(sel = list(lon = 100000)), "ds.sel(lon=100000)")
  expect_equal(xr_query(sel = list(lat = 0.125)), "ds.sel(lat=0.125)")
})

test_that("variable names with quotes are escaped", {
  expect_equal(xr_query(vars = "o'brien"), "ds['o\\'brien']")
})

test_that("dimension names must be python identifiers", {
  expect_error(xr_query(sel = list(`bad name` = 1)),
               "not a valid Python identifier")
  expect_error(xr_query(sel = list(`0lat` = 1)),
               "not a valid Python identifier")
})

test_that("indexers must be named lists", {
  expect_error(xr_query(sel = list(1, 2)))
  expect_error(xr_query(isel = list(0)))
})

test_that("order of application is vars, sel, isel, tail", {
  expect_equal(
    xr_query(vars = "sst", isel = list(time = 0), sel = list(lat = -80),
             tail = ".mean()"),
    "ds['sst'].sel(lat=-80).isel(time=0).mean()")
})
