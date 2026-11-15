## grid tables: xr_grids() (R/grids.R) and tbl() over several variables
## (R/tbl.R)

## two members on (time, lat, lon), a 2-D variable on (lat, lon), and a
## 2-D coordinate
make_grids_con <- function() {
  DBI::dbConnect(xarray(), builder = function(xr) {
    reticulate::py_run_string(paste(
      "import xarray as _xr, numpy as _np, pandas as _pd",
      "_dsgr = _xr.Dataset(",
      "  {'sst': (('time','lat','lon'), _np.arange(60.).reshape(3, 4, 5)),",
      "   'ice': (('time','lat','lon'), _np.arange(60.).reshape(3, 4, 5) / 100),",
      "   'mask': (('lat','lon'), _np.ones((4, 5), 'int8'))},",
      "  coords={'time': _pd.date_range('2026-01-01', periods=3),",
      "          'lat': _np.linspace(-80, -60, 4), 'lon': _np.linspace(0, 40, 5),",
      "          'area': (('lat', 'lon'), _np.full((4, 5), 2.0))})",
      "_dsgr.sst.encoding['preferred_chunks'] = {'time': 1, 'lat': 2, 'lon': 2}",
      sep = "\n"), convert = FALSE)
    reticulate::py_eval("_dsgr", convert = FALSE)
  })
}

test_that("xr_grids lists meaning grids, with their coordinates", {
  skip_if_no_xarray()
  con <- make_grids_con()
  on.exit(DBI::dbDisconnect(con))
  g <- xr_grids(con)
  expect_identical(g$grid, c("time,lat,lon", "lat,lon"))
  expect_equal(g$n, c(2, 1))
  expect_equal(g$cells, c(60, 20))
  expect_identical(g$variables[[1]], c("sst", "ice"))
  ## sst has a storage layout, ice none: two chunk shapes
  expect_equal(g$chunkings, c(2, 1))
  expect_identical(g$coords, list("area", "area"))
})

test_that("the storage view keeps the character dimension of strings", {
  skip_if_no_xarray()
  f <- tempfile(fileext = ".nc")
  on.exit(unlink(f))
  reticulate::py_run_string(sprintf(paste(
    "import xarray as _xr, numpy as _np",
    "_xr.Dataset({'name': ('n', _np.array(['ab', 'cde'])), 'v': ('n', [1., 2.])}",
    "  ).to_netcdf('%s', encoding={'name': {'dtype': 'S1'}})", sep = "\n"), f),
    convert = FALSE)
  con <- DBI::dbConnect(xarray(), f)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  ## decoded, both are on n; stored, name has its characters too
  expect_identical(xr_grids(con)$grid, "n")
  s <- xr_grids(con, "storage")
  name_grid <- s$grid[vapply(s$variables, function(v) "name" %in% v, NA)]
  expect_match(name_grid, "^n,string")
  expect_true(is.na(s$cells[s$grid == name_grid]))
  expect_identical(s$roles[s$grid == "n"], "data:1")
  ## a storage grid's name makes a table of its members, and keeps it
  x <- tbl(con, name_grid)
  expect_output(print(x), paste0("grid ", name_grid, ": 1 member"))
  expect_identical(collect(x)$name, c("ab", "cde"))
})

test_that("a grid table has a column per member", {
  skip_if_no_xarray()
  con <- make_grids_con()
  on.exit(DBI::dbDisconnect(con))
  by_name <- tbl(con, "time,lat,lon")
  by_members <- tbl(con, c("sst", "ice"))
  expect_output(show_query(by_name), "ds[['sst', 'ice']]", fixed = TRUE)
  expect_identical(by_name$var, by_members$var)
  r <- collect(by_name |> filter(lat > -75, time == as.Date("2026-01-02")))
  expect_true(all(c("lat", "lon", "sst", "ice", "area") %in% names(r)))
  expect_equal(nrow(r), 3 * 5)
  ## the same values as each variable's own table
  one <- collect(tbl(con, "ice") |> filter(lat > -75, time == as.Date("2026-01-02")))
  expect_equal(r$ice, one$ice)
  expect_equal(r$ice, r$sst / 100)
})

test_that("select() decides which members are read", {
  skip_if_no_xarray()
  con <- make_grids_con()
  on.exit(DBI::dbDisconnect(con))
  g <- tbl(con, c("sst", "ice"))
  just_ice <- g |> select(time, lat, lon, ice)
  expect_output(show_query(just_ice), "ds[['ice']]", fixed = TRUE)
  expect_identical(names(collect(just_ice)), c("time", "lat", "lon", "ice"))
  ## a filter on an unselected member reads it, then drops it
  hot <- g |> filter(sst > 50) |> select(lat, lon, ice)
  expect_output(show_query(hot), "ds[['sst', 'ice']]", fixed = TRUE)
  r <- collect(hot)
  expect_identical(names(r), c("lat", "lon", "ice"))
  expect_equal(nrow(r), 9)
  expect_true(all(r$ice > 0.5))
  expect_error(g |> select(lat, lon), "select at least one member")
  ## head() on a grid takes the first rows of every member read
  h <- collect(g |> head(3))
  expect_equal(nrow(h), 3)
  expect_equal(h$sst, 0:2)
})

test_that("grid tables refuse what would broadcast or is not a member", {
  skip_if_no_xarray()
  con <- make_grids_con()
  on.exit(DBI::dbDisconnect(con))
  expect_error(tbl(con, c("sst", "mask")), "on different grids \\(time,lat,lon; lat,lon\\)")
  expect_error(tbl(con, c("sst", "area")), "area is a coordinate")
  expect_error(tbl(con, c("sst", "nope")), "no such variable\\(s\\): nope")
  expect_error(tbl(con, c("sst", "sst")), "named twice")
  expect_error(tbl(con, "nope"), "no such variable or grid: nope")
  expect_error(tbl(con, c("sst", "ice")) |> filter(nope > 1), "unknown field")
})

test_that("the guard counts values, cells times members", {
  skip_if_no_xarray()
  con <- make_grids_con()
  on.exit(DBI::dbDisconnect(con))
  g <- tbl(con, c("sst", "ice"))
  expect_error(collect(g, max_cells = 100),
               "120 values \\(cells times members\\)")
  expect_equal(nrow(collect(g |> select(time, lat, lon, sst), max_cells = 100)), 60)
  expect_equal(nrow(collect(g, max_cells = 100, force = TRUE)), 60)
})

test_that("printing a grid previews its first members", {
  skip_if_no_xarray()
  con <- make_grids_con()
  on.exit(DBI::dbDisconnect(con))
  g <- tbl(con, "time,lat,lon")
  expect_output(print(g), "grid time,lat,lon: 2 members, reading 2")
  expect_output(print(g), "at most one chunk per member")
  withr_opt <- options(xrdbi.preview_members = 1)
  on.exit(options(withr_opt), add = TRUE)
  out <- capture.output(print(g))
  expect_true(any(grepl("preview shows 1 of 2 members", out)))
  expect_false(any(grepl("\\bice\\b", out[-(1:2)])))
})

test_that("xr_chunks() maps what a tbl reads", {
  skip_if_no_xarray()
  con <- make_grids_con()
  on.exit(DBI::dbDisconnect(con))
  g <- tbl(con, c("sst", "ice")) |> filter(lat > -75)
  ch <- xr_chunks(g)
  expect_equal(as.vector(table(ch$array)[c("sst", "ice")]), c(3 * 2 * 3, 1))
  expect_identical(attr(ch, "chunking"), c(sst = "storage", ice = "none"))
  ## only the members read
  expect_identical(unique(xr_chunks(g |> select(lat, ice))$array), "ice")
  ## one variable's table, the same as its statement
  one <- tbl(con, "sst") |> filter(lat > -75)
  expect_identical(xr_chunks(one), xr_chunks(con, "ds['sst'].sel(lat=slice(-75, None)).pipe(lambda a: a.isel(lat=(a['lat'].to_index() > -75)))"))
})
