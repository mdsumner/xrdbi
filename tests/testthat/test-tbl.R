## Pure compile tests: no python, no connection. A tbl shell with
## con = NULL parses and compiles; dims/descending are passed
## explicitly. Every asserted statement string was validated against
## xarray directly.

shell <- function(var = "sst") xrdbi:::new_tbl_xarray(NULL, var)
compile1 <- function(x, dims, descending = character()) {
  xrdbi:::compile_tbl(x, dims = dims, descending = descending)
}

test_that("inclusive range predicates compile to an exact sel hull", {
  x <- dplyr::filter(shell(), lat >= -80, lat <= -70)
  expect_equal(compile1(x, dims = c("time", "lat", "lon")),
               "ds['sst'].sel(lat=slice(-80, -70))")
})

test_that("one-sided ranges leave the open end as None", {
  x <- dplyr::filter(shell(), lat <= -70)
  expect_equal(compile1(x, dims = c("time", "lat", "lon")),
               "ds['sst'].sel(lat=slice(None, -70))")
})

test_that("descending dims get an oriented slice", {
  x <- dplyr::filter(shell("u"), latitude > 18, latitude < 19)
  expect_equal(
    compile1(x, dims = c("latitude", "longitude"),
             descending = "latitude"),
    paste0("ds['u'].sel(latitude=slice(19, 18))",
           ".pipe(lambda a: a.isel(latitude=(a.indexes['latitude'] > 18)",
           " & (a.indexes['latitude'] < 19)))"))
})

test_that("strict bounds push the hull and trim it on the index", {
  x <- dplyr::filter(shell(), lat > -80, lat <= -70)
  expect_equal(
    compile1(x, dims = c("time", "lat", "lon")),
    paste0("ds['sst'].sel(lat=slice(-80, -70))",
           ".pipe(lambda a: a.isel(lat=(a.indexes['lat'] > -80)))"))

  ## strict on two dims, the hull stage without the trim
  x <- dplyr::filter(shell(), lat > -80, lon < 30)
  expect_equal(
    compile1(x, dims = c("time", "lat", "lon")),
    paste0("ds['sst'].sel(lat=slice(-80, None), lon=slice(None, 30))",
           ".pipe(lambda a: a.isel(lat=(a.indexes['lat'] > -80), ",
           "lon=(a.indexes['lon'] < 30)))"))
  expect_equal(
    xrdbi:::compile_tbl(x, dims = c("time", "lat", "lon"),
                        descending = character(), stage = "hull"),
    "ds['sst'].sel(lat=slice(-80, None), lon=slice(None, 30))")
})

test_that("equality and membership are exact pushdowns", {
  x <- dplyr::filter(shell(), time == as.Date("2026-01-02"))
  expect_equal(compile1(x, dims = c("time", "lat", "lon")),
               "ds['sst'].sel(time='2026-01-02')")

  x <- dplyr::filter(shell(), lat %in% c(-80, -60))
  expect_equal(compile1(x, dims = c("time", "lat", "lon")),
               "ds['sst'].sel(lat=[-80, -60])")
})

test_that("value predicates are residual-only", {
  x <- dplyr::filter(shell(), sst > 10)
  expect_equal(
    compile1(x, dims = c("time", "lat", "lon")),
    "ds['sst'].pipe(_xrdbi_render).query('`sst` > 10')")
})

test_that("dim hull and value residual combine in one statement", {
  x <- dplyr::filter(shell(), lat >= -80, lat <= -70, sst > 10)
  expect_equal(
    compile1(x, dims = c("time", "lat", "lon")),
    paste0("ds['sst'].sel(lat=slice(-80, -70))",
           ".pipe(_xrdbi_render).query('`sst` > 10')"))
})

test_that("between, reversed comparisons, parentheses, & all parse", {
  x <- dplyr::filter(shell(), between(lat, -80, -70))
  expect_equal(compile1(x, dims = "lat"),
               "ds['sst'].sel(lat=slice(-80, -70))")

  x <- dplyr::filter(shell(), -70 >= lat)      # flips to lat <= -70
  expect_equal(compile1(x, dims = "lat"),
               "ds['sst'].sel(lat=slice(None, -70))")

  x <- dplyr::filter(shell(), (lat >= -80) & (lat <= -70))
  expect_equal(compile1(x, dims = "lat"),
               "ds['sst'].sel(lat=slice(-80, -70))")
})

test_that("select and head stay R-side unless a value filter needs pandas", {
  ## no residual: the statement stays an xarray object; head() and
  ## select() apply to the fetched rows (head_block narrows it when live)
  x <- dplyr::select(utils::head(shell(), 7), time, lat, sst)
  expect_equal(compile1(x, dims = c("time", "lat", "lon")), "ds['sst']")
  expect_equal(xrdbi:::tbl_r_steps(x, pandas = FALSE),
               "head(7) |> select(time, lat, sst)")
  expect_output(dplyr::show_query(x),
                "# then in R: head(7) |> select(time, lat, sst)", fixed = TRUE)

  ## a value filter must run before head(), so all three go python-side
  x <- dplyr::select(utils::head(dplyr::filter(shell(), sst > 10), 7),
                     time, lat, sst)
  expect_equal(
    compile1(x, dims = c("time", "lat", "lon")),
    paste0("ds['sst'].pipe(_xrdbi_render).query('`sst` > 10')",
           "[['time', 'lat', 'sst']].head(7)"))
  expect_equal(xrdbi:::tbl_r_steps(x, pandas = TRUE), character(0))

  ## a negative head() is pandas' "all but the last n"
  expect_equal(compile1(utils::head(shell(), -2), dims = "lat"),
               "ds['sst'].pipe(_xrdbi_render).head(-2)")
})

test_that("head_block holds the first n rows of the C-order long form", {
  ## brute force: the first n rows of the full grid are exactly the first
  ## n rows of the block's own C-order long form
  c_order <- function(sizes) {
    g <- rev(expand.grid(lapply(rev(sizes), function(s) seq_len(s) - 1L)))
    unname(as.matrix(g))
  }
  bad <- character(0)
  for (sizes in list(c(a = 3), c(a = 2, b = 3), c(a = 3, b = 1, c = 4),
                     c(a = 2, b = 3, c = 2), c(a = 1, b = 5))) {
    full <- c_order(sizes)
    for (n in 0:(nrow(full) + 1L)) {
      blk <- xrdbi:::head_block(sizes, n)
      bsizes <- sizes
      bsizes[names(blk)] <- blk
      bf <- c_order(bsizes)
      k <- min(n, nrow(full))
      ok <- nrow(bf) >= k &&
        identical(full[seq_len(k), , drop = FALSE], bf[seq_len(k), , drop = FALSE])
      if (!ok) bad <- c(bad, sprintf("%s n=%d", paste(sizes, collapse = "x"), n))
    }
  }
  expect_identical(bad, character(0))
})

test_that("odd variable names are backticked in residuals", {
  x <- dplyr::filter(shell("100m_u_component_of_wind"),
                     `100m_u_component_of_wind` > 10)
  expect_equal(
    compile1(x, dims = c("time", "latitude", "longitude")),
    paste0("ds['100m_u_component_of_wind'].pipe(_xrdbi_render)",
           ".query('`100m_u_component_of_wind` > 10')"))
})

test_that("unsupported expressions error with guidance", {
  expect_error(dplyr::filter(shell(), lat + 1 > 0), "unsupported filter")
  expect_error(dplyr::filter(shell(), grepl("x", name)), "unsupported filter")
})

## ---- integration: real python, in-memory fixtures --------------------

test_that("tbl pipeline collects correctly", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))

  df <- dplyr::tbl(con, "sst") |>
    dplyr::filter(lat >= -80, lat <= -70) |>
    dplyr::collect()
  expect_equal(nrow(df), 3L * 2L * 5L)
  expect_true(all(df$lat <= -70))

  ## residual value predicate applies python-side
  df2 <- dplyr::tbl(con, "sst") |>
    dplyr::filter(lat >= -80, lat <= -70, sst > 0.5) |>
    dplyr::collect()
  expect_true(all(df2$sst > 0.5))
  expect_lte(nrow(df2), nrow(df))

  ## select + head
  df3 <- dplyr::tbl(con, "sst") |>
    dplyr::select(time, lat, sst) |> head(7) |> dplyr::collect()
  expect_equal(dim(df3), c(7L, 3L))
  expect_equal(names(df3), c("time", "lat", "sst"))
})

test_that("head() and select() in R match the same steps on the full result", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))
  t <- dplyr::tbl(con, "sst")
  all <- as.data.frame(dplyr::collect(t))
  ## 3 x 4 x 5 = 60 rows: every block shape, past the end too
  for (n in c(0L, 1L, 4L, 5L, 6L, 19L, 20L, 21L, 59L, 60L, 61L)) {
    got <- as.data.frame(dplyr::collect(utils::head(t, n)))
    expect_identical(got, utils::head(all, n), label = paste("head", n))
  }
  got <- as.data.frame(dplyr::collect(
    dplyr::select(utils::head(dplyr::filter(t, lat > -80), 7), lon, sst, time)))
  want <- utils::head(all[all$lat > -80, c("lon", "sst", "time")], 7)
  rownames(want) <- NULL
  expect_identical(got, want)

  ## head() narrows the selection to the block holding its rows
  expect_match(tbl_statement(utils::head(t, 7)),
               ".isel(time=slice(0, 1), lat=slice(0, 2))", fixed = TRUE)
})

test_that("the collect guard counts what is read, and force reaches dbFetch", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))
  old <- options(xrdbi.max_cells = 10)
  on.exit(options(old), add = TRUE)
  t <- dplyr::tbl(con, "sst")
  expect_error(dplyr::collect(t), "60 cells")
  ## REGRESSION: collect(force = TRUE) still hit dbFetch's own guard
  expect_equal(nrow(dplyr::collect(t, force = TRUE)), 60L)
  ## head(5) reads a 5-cell block, under the guard without force
  expect_equal(nrow(dplyr::collect(utils::head(t, 5))), 5L)
})

test_that("descending coordinates just work through the tbl layer", {
  skip_if_no_xarray()
  con <- make_desc_con()
  on.exit(DBI::dbDisconnect(con))

  ## the ERA5 gotcha, dissolved: a range is a range, orientation is
  ## the collect step's problem
  df <- dplyr::tbl(con, "u") |>
    dplyr::filter(latitude >= 60, latitude <= 70) |>
    dplyr::collect()
  expect_equal(sort(unique(df$latitude)), c(60, 70))
  expect_equal(nrow(df), 2L * 4L)
})

test_that("filter validates field names against the variable", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))
  expect_error(dplyr::filter(dplyr::tbl(con, "sst"), nonesuch > 1),
               "unknown field")
  expect_error(dplyr::select(dplyr::tbl(con, "sst"), nonesuch),
               "unknown field")
})

test_that("show_query prints the compiled python", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))
  x <- dplyr::filter(dplyr::tbl(con, "sst"), lat >= -80, lat <= -70)
  expect_output(dplyr::show_query(x), "sel\\(lat=slice\\(-80, -70\\)\\)",
                fixed = FALSE)


  x1 <- dplyr::filter(dplyr::tbl(con, "sst"),
               time >= as.Date("1980-01-01"), time <= as.Date("1980-01-31"))
  expect_output(dplyr::show_query(x1),   "sel\\(time=slice\\('1980-01-01', '1980-01-31'\\)\\)", fixed = FALSE)
  expect_equal(compile_tbl(x1, dims = "time", descending = FALSE, stage = "hull"),
  "ds['sst'].sel(time=slice('1980-01-01', '1980-01-31'))")

  x2 <- dplyr::filter(dplyr::tbl(con, "sst"), lat > -80, sst > 0.5)
  expect_equal(
    compile_tbl(x2, dims = c("time", "lat", "lon"),
                descending = character(), stage = "hull"),
    "ds['sst'].sel(lat=slice(-80, None))")
  expect_match(
    compile_tbl(x2, dims = c("time", "lat", "lon"),
                descending = character()),
    ".query(", fixed = TRUE)
})

test_that("strict dim bounds collect the same rows as filtering in R", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))
  all <- DBI::dbReadTable(con, "sst")
  ## lat is -80, -73.3, -66.7, -60; lon is 0, 10, 20, 30, 40; time daily
  ## from 2026-01-01; each bound lands exactly on a coordinate value
  x <- dplyr::filter(dplyr::tbl(con, "sst"), lat > -80, lat < -60,
                     lon > 10, time < as.Date("2026-01-03"))
  got <- as.data.frame(dplyr::collect(x))
  want <- all[all$lat > -80 & all$lat < -60 & all$lon > 10 &
                all$time < as.POSIXct("2026-01-03", tz = "UTC"), ]
  rownames(want) <- NULL
  expect_equal(nrow(got), 2L * 2L * 3L)
  expect_identical(got, want)

  ## the statement stays an xarray object, so it takes the R-built path
  stmt <- tbl_statement(x)
  expect_false(grepl("_xrdbi_render", stmt, fixed = TRUE))
  res <- DBI::dbSendQuery(con, stmt)
  on.exit(DBI::dbClearResult(res), add = TRUE)
  expect_false(is.null(plan_result(con, res@ptr$obj)))

  ## descending coordinate
  dcon <- make_desc_con()
  on.exit(DBI::dbDisconnect(dcon), add = TRUE)
  d <- as.data.frame(dplyr::collect(
    dplyr::filter(dplyr::tbl(dcon, "u"), latitude > 60, latitude < 90)))
  expect_identical(sort(unique(d$latitude)), c(70, 80))
})


