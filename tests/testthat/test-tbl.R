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

test_that("select and head compose python-side", {
  x <- dplyr::select(utils::head(shell(), 7), time, lat, sst)
  expect_equal(
    compile1(x, dims = c("time", "lat", "lon")),
    paste0("ds['sst'].pipe(_xrdbi_render)",
           "[['time', 'lat', 'sst']].head(7)"))
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


