## pandas -> R conversion goes column by column through _xrdbi_columns
## (R/utils.R), not reticulate's whole-DataFrame conversion. Each case
## below was wrong on the old path; the comment says how.

skip_if_no_cftime <- function() {
  skip_if_not(reticulate::py_module_available("cftime"),
              "python cftime not available")
}

empty_con <- function() {
  DBI::dbConnect(xarray(), builder = function(xr) xr$Dataset())
}

py_frame <- function(code) {
  reticulate::py_run_string(paste("import numpy as np, pandas as pd",
                                   code, sep = "\n"), convert = FALSE)
  reticulate::py_eval("_f", convert = FALSE)
}

test_that("datetimes: NaT is NA, naive is UTC, tz-aware keeps its zone", {
  skip_if_no_xarray()
  con <- empty_con()
  on.exit(DBI::dbDisconnect(con))
  out <- frame_to_r(con, py_frame(paste(
    "_f = pd.DataFrame({",
    "  'naive': pd.date_range('2026-01-01 12:00', periods=3),",
    "  'nat':   pd.Series([pd.Timestamp('2026-01-01'), pd.NaT,",
    "                      pd.Timestamp('2026-01-03')]),",
    "  'sec':   pd.date_range('2026-01-01', periods=3).astype('datetime64[s]'),",
    "  'aware': pd.date_range('2026-01-01', periods=3, tz='Australia/Hobart')})",
    sep = "\n")))

  expect_s3_class(out$naive, "POSIXct")
  expect_equal(attr(out$naive, "tzone"), "UTC")
  expect_equal(out$naive[1], as.POSIXct("2026-01-01 12:00:00", tz = "UTC"))

  ## REGRESSION: reticulate reads NaT in a numpy datetime64 array as
  ## int64 min, i.e. 1677-09-21
  expect_equal(is.na(out$nat), c(FALSE, TRUE, FALSE))

  expect_equal(out$sec[3], as.POSIXct("2026-01-03", tz = "UTC"))

  ## same instant, displayed in the source zone
  expect_equal(attr(out$aware, "tzone"), "Australia/Hobart")
  expect_equal(as.numeric(out$aware[1]),
               as.numeric(as.POSIXct("2026-01-01", tz = "Australia/Hobart")))
})

test_that("timedeltas become difftime seconds", {
  skip_if_no_xarray()
  con <- empty_con()
  on.exit(DBI::dbDisconnect(con))
  out <- frame_to_r(con, py_frame(
    "_f = pd.DataFrame({'lead': pd.to_timedelta([1, None, 3], 'h')})"))
  ## REGRESSION: the old path gave a POSIXct column of NA
  expect_s3_class(out$lead, "difftime")
  expect_equal(units(out$lead), "secs")
  expect_equal(as.numeric(out$lead), c(3600, NA, 10800))
})

test_that("text: pandas strings, bytes, categoricals, mixed objects", {
  skip_if_no_xarray()
  con <- empty_con()
  on.exit(DBI::dbDisconnect(con))
  out <- frame_to_r(con, py_frame(paste(
    "_f = pd.DataFrame({",
    "  'str':   pd.Series(['a', None, 'c']),",
    "  'bytes': pd.Series([b'a', b'b', None], dtype=object),",
    "  'cat':   pd.Categorical(['x', None, 'x'], categories=['y', 'x'],",
    "                          ordered=True),",
    "  'mixed': pd.Series([[1], 'b', None], dtype=object)})",
    sep = "\n")))

  ## REGRESSION: pandas 3's default string dtype came back as an
  ## unconverted Python object inside the data.frame
  expect_identical(out$str, c("a", NA, "c"))
  expect_identical(out$bytes, c("a", "b", NA))
  ## REGRESSION: categoricals made the whole conversion error
  expect_identical(out$cat, factor(c("x", NA, "x"), levels = c("y", "x"),
                                   ordered = TRUE))
  ## unhashable objects fall back to one string per row, None still NA
  expect_identical(out$mixed, c("[1]", "b", NA))
})

test_that("numbers: nullable types keep NA, small floats widen", {
  skip_if_no_xarray()
  con <- empty_con()
  on.exit(DBI::dbDisconnect(con))
  out <- frame_to_r(con, py_frame(paste(
    "_f = pd.DataFrame({",
    "  'i16':  np.array([1, 2, 3], dtype='int16'),",
    "  'u32':  np.array([1, 2, 4000000000], dtype='uint32'),",
    "  'f16':  np.array([1.5, np.nan, 3], dtype='float16'),",
    "  'f32':  np.array([1.5, np.nan, 3], dtype='float32'),",
    "  'b':    [True, False, True],",
    "  'I32':  pd.array([1, None, 3], dtype='Int32'),",
    "  'I64':  pd.array([1, None, 3], dtype='Int64'),",
    "  'bna':  pd.array([True, None, False], dtype='boolean')})",
    sep = "\n")))

  expect_identical(out$i16, 1:3)
  expect_identical(out$u32, c(1, 2, 4e9))
  expect_identical(out$f16, c(1.5, NaN, 3))
  expect_identical(out$f32, c(1.5, NaN, 3))
  expect_identical(out$b, c(TRUE, FALSE, TRUE))
  expect_identical(out$I32, c(1L, NA, 3L))
  ## int64 is double in R, as for plain numpy int64
  expect_identical(out$I64, c(1, NA, 3))
  expect_identical(out$bna, c(TRUE, NA, FALSE))
})

test_that("names are kept verbatim and empty frames keep their columns", {
  skip_if_no_xarray()
  con <- empty_con()
  on.exit(DBI::dbDisconnect(con))
  out <- frame_to_r(con, py_frame(
    "_f = pd.DataFrame({'100m_u': [1.0], 'a b': [2.0]})"))
  expect_named(out, c("100m_u", "a b"))

  out0 <- frame_to_r(con, py_frame(
    "_f = pd.DataFrame(columns=['time', 'lat', 'sst'])"))
  expect_named(out0, c("time", "lat", "sst"))
  expect_equal(nrow(out0), 0L)
})

test_that("xarray string, cftime and timedelta coords fetch as R types", {
  skip_if_no_xarray()
  skip_if_no_cftime()
  con <- DBI::dbConnect(xarray(), builder = function(xr) {
    reticulate::py_run_string(paste(
      "import xarray as _xr, numpy as _np, pandas as _pd",
      "_dsc = _xr.Dataset(",
      "  {'v': (('station', 'time'), _np.arange(6.).reshape(2, 3))},",
      "  coords={'station': ['A01', 'B02'],",
      "          'time': _xr.date_range('2026-01-01', periods=3,",
      "                                 calendar='360_day', use_cftime=True),",
      "          'lead': ('time', _pd.to_timedelta([0, 6, 12], 'h'))})",
      sep = "\n"), convert = FALSE)
    reticulate::py_eval("_dsc", convert = FALSE)
  })
  on.exit(DBI::dbDisconnect(con))

  df <- DBI::dbGetQuery(con, "ds.v")
  ## REGRESSION: station was an ArrowStringArray object, time a list of
  ## cftime objects, lead a POSIXct of NA
  expect_identical(df$station, rep(c("A01", "B02"), each = 3))
  ## non-standard calendars have no POSIXct; their ISO text is exact
  expect_identical(df$time[1:3], c("2026-01-01 00:00:00",
                                   "2026-01-02 00:00:00",
                                   "2026-01-03 00:00:00"))
  expect_equal(as.numeric(df$lead[1:3]), c(0, 21600, 43200))

  ## chunked fetch gives the same rows
  res <- DBI::dbSendQuery(con, "ds.v")
  a <- DBI::dbFetch(res, n = 4)
  b <- DBI::dbFetch(res, n = 4)
  DBI::dbClearResult(res)
  expect_equal(rbind(a, b), df)
})
