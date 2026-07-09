## DBI surface against in-memory fixtures. Each block that encodes a
## session-discovered regression says so in a comment; do not simplify
## those away.

test_that("connect validates its arguments", {
  expect_error(DBI::dbConnect(xarray()), "exactly one")
  expect_error(DBI::dbConnect(xarray(), dsn = "x", object = 1), "exactly one")
})

test_that("connect, info, disconnect", {
  skip_if_no_xarray()
  con <- make_con()
  expect_true(DBI::dbIsValid(con))

  info <- DBI::dbGetInfo(con)
  expect_equal(info$sizes$time, 3L)
  expect_equal(info$sizes$lon, 5L)
  ## dbGetInfo preserves the data/coords distinction that dbListTables
  ## deliberately flattens
  expect_setequal(info$tables, c("sst", "ice"))

  expect_true(DBI::dbDisconnect(con))
  expect_false(DBI::dbIsValid(con))
  expect_error(DBI::dbListTables(con), "closed")
})

test_that("coordinates are tables too", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))

  tabs <- DBI::dbListTables(con)
  expect_setequal(tabs,
    c("sst", "ice", "time", "lat", "lon", "zlev", "cell_area"))
  expect_true(DBI::dbExistsTable(con, "lat"))
  expect_true(DBI::dbExistsTable(con, "cell_area"))
  expect_false(DBI::dbExistsTable(con, "nope"))
})

test_that("fields: data variable, dim coord, scalar coord, 2-D coord", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))

  f <- DBI::dbListFields(con, "sst")
  expect_equal(f[1:3], c("time", "lat", "lon"))       # dims, storage order
  expect_equal(f[length(f)], "sst")                    # variable last
  expect_setequal(f, c("time", "lat", "lon", "zlev", "cell_area", "sst"))

  ## a dimension coordinate is just itself
  expect_equal(DBI::dbListFields(con, "lat"), "lat")

  ## scalar coordinate
  expect_equal(DBI::dbListFields(con, "zlev"), "zlev")

  ## 2-D non-dim coordinate: dims, other coords, itself once (no self-dup)
  f2 <- DBI::dbListFields(con, "cell_area")
  expect_equal(sum(f2 == "cell_area"), 1L)
  expect_equal(f2[length(f2)], "cell_area")

  expect_error(DBI::dbListFields(con, "nope"), "no such variable")
})

test_that("dbReadTable renders every variable shape", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))

  ## data variable: tidy long form, all coords propagate
  df <- DBI::dbReadTable(con, "sst")
  expect_s3_class(df, "data.frame")
  expect_equal(nrow(df), 3L * 4L * 5L)
  expect_true(all(c("time", "lat", "lon", "zlev", "cell_area", "sst")
                  %in% names(df)))
  expect_s3_class(df$time, "POSIXct")

  ## REGRESSION: dim coords and scalar coords must route through the
  ## connection's render helper; the raw to_dataframe path raises
  ## "cannot insert lat, already exists" / "cannot convert a scalar"
  lat <- DBI::dbReadTable(con, "lat")
  expect_equal(dim(lat), c(4L, 1L))
  expect_equal(names(lat), "lat")
  expect_equal(lat$lat, seq(-80, -60, length.out = 4))

  zl <- DBI::dbReadTable(con, "zlev")
  expect_equal(dim(zl), c(1L, 1L))

  ## 2-D coord: no duplicated self column
  ca <- DBI::dbReadTable(con, "cell_area")
  expect_equal(sum(names(ca) == "cell_area"), 1L)
  expect_equal(nrow(ca), 4L * 5L)
})

test_that("dbReadTable guard fires, respects option and force", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))

  expect_error(DBI::dbReadTable(con, "sst", max_cells = 10),
               "exceeds the guard")
  expect_no_error(DBI::dbReadTable(con, "sst", max_cells = 10, force = TRUE))

  old <- options(xrdbi.max_cells = 10)
  on.exit(options(old), add = TRUE)
  expect_error(DBI::dbReadTable(con, "sst"), "exceeds the guard")
})

test_that("statements evaluate with ds and xr in scope", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))

  ## REGRESSION: statement scope must be built with explicit string keys
  ## (py_dict); reticulate::dict() resolves names against calling-frame
  ## variables, making the local Dataset an (unhashable) dict key
  df <- DBI::dbGetQuery(con, "ds.sst.isel(time=0).sel(lat=slice(-80, -70))")
  expect_equal(nrow(df), 2L * 5L)
  expect_true(all(df$lat <= -70))

  ## xr is in scope too
  one <- DBI::dbGetQuery(con, "xr.DataArray(1.0)")
  expect_equal(dim(one), c(1L, 1L))

  ## scalars come back as a one-cell frame named value
  m <- DBI::dbGetQuery(con, "float(ds.sst.mean())")
  expect_equal(dim(m), c(1L, 1L))
  expect_true(is.numeric(m$value))
})

test_that("0-d datetime renders as POSIXct, not integer nanoseconds", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))

  ## REGRESSION: .item() on ns-precision datetime64 returns raw integer
  ## nanoseconds; the renderer must use values[()] instead
  t1 <- DBI::dbGetQuery(con, "ds.time.isel(time=-1)")
  expect_equal(dim(t1), c(1L, 1L))
  expect_s3_class(t1$time, "POSIXct")
  expect_false(is.numeric(t1$time))
})

test_that("empty selections emit a kind message", {
  skip_if_no_xarray()
  con <- make_desc_con()
  on.exit(DBI::dbDisconnect(con))

  ## descending coordinate + ascending slice = empty; the hint names it
  expect_message(
    DBI::dbGetQuery(con, "ds.u.sel(latitude=slice(60, 70))"),
    "DESCENDING")

  ## out-of-range on the ascending coord reports the span
  expect_message(
    DBI::dbGetQuery(con, "ds.u.sel(longitude=slice(100, 200))"),
    "coordinate spans")

  ## non-empty results say nothing
  expect_no_message(
    DBI::dbGetQuery(con, "ds.u.sel(latitude=slice(70, 60))"))
})

test_that("dbSendQuery is lazy and dbFetch paginates python-side", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))

  res <- DBI::dbSendQuery(con, "ds.sst.isel(time=0)")
  expect_false(DBI::dbHasCompleted(res))
  expect_equal(DBI::dbGetStatement(res), "ds.sst.isel(time=0)")

  a <- DBI::dbFetch(res, n = 7)
  expect_equal(nrow(a), 7L)
  expect_false(DBI::dbHasCompleted(res))
  expect_equal(DBI::dbGetRowCount(res), 7L)

  b <- DBI::dbFetch(res)
  expect_equal(nrow(b), 20L - 7L)
  expect_true(DBI::dbHasCompleted(res))
  expect_equal(DBI::dbGetRowCount(res), 20L)

  ## fetch past the end is empty, same columns
  z <- DBI::dbFetch(res, n = 5)
  expect_equal(nrow(z), 0L)
  expect_equal(names(z), names(a))

  DBI::dbClearResult(res)
  expect_false(DBI::dbIsValid(res))
  expect_error(DBI::dbFetch(res), "cleared")
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

test_that("escape hatches return live python handles", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))

  expect_s3_class(xr_dataset(con), "python.builtin.object")
  expect_s3_class(xr_module(con), "python.builtin.object")
})

test_that("transactions error with the icechunk pointer", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))
  expect_error(DBI::dbBegin(con), "icechunk")
  expect_error(DBI::dbCommit(con), "icechunk")
  expect_error(DBI::dbRollback(con), "icechunk")
})

test_that("quoting compiles to python accessors", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))
  expect_equal(as.character(DBI::dbQuoteIdentifier(con, "sst")), "ds['sst']")
  expect_equal(as.character(DBI::dbQuoteString(con, "a'b")), "'a\\'b'")
})
