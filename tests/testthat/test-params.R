## params: named R values become Python variables in the statement scope
## (R/params.R). Name checks need no Python and run everywhere.

skip_if_no_py_module <- function(m) {
  skip_if_not(reticulate::py_module_available(m),
              paste("python", m, "not available"))
}

test_that("params names are checked before anything reaches Python", {
  expect_silent(check_param_names(NULL))
  expect_silent(check_param_names(list()))
  expect_silent(check_param_names(list(lat0 = 1, `_ok` = 2)))
  expect_error(check_param_names(list(1)), "needs a name")
  expect_error(check_param_names(list(a = 1, 2)), "needs a name")
  expect_error(check_param_names(list(`2x` = 1)), "Python identifiers: 2x")
  expect_error(check_param_names(list(`a.b` = 1)), "Python identifiers")
  expect_error(check_param_names(list(ds = 1)), "shadow the statement scope: ds")
  expect_error(check_param_names(list(`_xrdbi_render` = 1)), "shadow")
  expect_error(check_param_names(list(a = 1, a = 2)), "duplicated params names: a")
  expect_error(check_param_names(data.frame(a = 1)), "named list")
  expect_error(check_param_names(c(a = 1)), "named list")
})

test_that("scalars, vectors and times arrive as numpy values", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))
  ptype <- function(v) {
    reticulate::py_to_r(reticulate::py_eval(
      "lambda o: type(o).__name__ + ' ' + str(getattr(o, 'dtype', ''))")(
        param_to_py(con, v)))
  }
  expect_identical(ptype(1.5), "float64 float64")
  expect_identical(ptype(I(1.5)), "ndarray float64")
  expect_identical(ptype(c(1, 2)), "ndarray float64")
  expect_match(ptype(1:3), "^ndarray int")
  expect_identical(ptype(c(TRUE, FALSE)), "ndarray bool")
  expect_identical(ptype(factor(c("a", "b"))), "ndarray <U1")
  expect_identical(ptype(as.Date("2026-01-02")), "datetime64 datetime64[D]")
  expect_identical(ptype(as.POSIXct("2026-01-02 03:04:05", tz = "UTC")),
                   "datetime64 datetime64[ns]")
  expect_identical(ptype(data.frame(a = 1)), "DataFrame ")
  ## a Python object passes through untouched
  o <- reticulate::py_eval("[1, 2]", convert = FALSE)
  expect_identical(ptype(o), "list ")

  ## the instant survives, as naive UTC; NA becomes NaT
  t <- as.POSIXct(c("2026-01-02 03:04:05", NA), tz = "Australia/Hobart")
  got <- DBI::dbGetQuery(con, "xr.DataArray(ts, dims='i', name='t')",
                         params = list(ts = t))
  expect_equal(as.numeric(got$t[1]), as.numeric(t[1]))
  expect_true(is.na(got$t[2]))
})

test_that("params drive selections: a scalar, a point set, a date", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))
  all <- DBI::dbGetQuery(con, "ds.sst")

  one <- DBI::dbGetQuery(con, "ds.sst.sel(lat=lat0).isel(time=0)",
                         params = list(lat0 = -60))
  expect_true(all(one$lat == -60))
  expect_equal(nrow(one), 5L)

  pts <- DBI::dbGetQuery(con, paste0(
    "ds.sst.isel(time=0).sel(lat=xr.DataArray(lats, dims='pt'), ",
    "lon=xr.DataArray(lons, dims='pt'), method='nearest')"),
    params = list(lats = c(-79, -61), lons = c(1, 39)))
  expect_equal(pts$lat, c(-80, -60))
  expect_equal(pts$lon, c(0, 40))

  d <- DBI::dbGetQuery(con, "ds.sst.sel(time=t0)",
                       params = list(t0 = as.Date("2026-01-02")))
  want <- all[all$time == as.POSIXct("2026-01-02", tz = "UTC"), "sst"]
  expect_equal(d$sst, want)

  ## I() keeps a 1-element array, so the dimension stays
  k <- DBI::dbGetQuery(con, "ds.sst.isel(time=0).sel(lat=lats)",
                       params = list(lats = I(-60)))
  expect_true("lat" %in% names(k))
})

test_that("dbBind evaluates again and restarts the fetch", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))
  res <- DBI::dbSendQuery(con, "ds.sst.sel(lat=lat0).isel(time=0)",
                          params = list(lat0 = -80))
  on.exit(DBI::dbClearResult(res), add = TRUE)
  a <- DBI::dbFetch(res, n = 2)
  expect_true(all(a$lat == -80))
  expect_identical(DBI::dbBind(res, list(lat0 = -60)), res)
  expect_false(DBI::dbHasCompleted(res))
  b <- DBI::dbFetch(res)
  expect_equal(nrow(b), 5L)
  expect_true(all(b$lat == -60))
})

test_that("an unbound name explains params; xr_raster takes params", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))
  expect_error(DBI::dbGetQuery(con, "ds.sst.sel(lat=lat0)"),
               "names in params")
  expect_error(DBI::dbGetQuery(con, "ds", params = list(xr = 1)), "reserved")
  r <- xr_raster(con, "ds.sst.isel(time=t)", params = list(t = 1L))
  expect_equal(attr(r, "gis")$dim, c(5, 4, 1))
})

test_that("geometry becomes shapely, or a GeoSeries with its CRS", {
  skip_if_no_xarray()
  skip_if_not_installed("wk")
  skip_if_no_py_module("shapely")
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))

  g <- wk::wkt(c("POINT (1 2)", "LINESTRING (0 0, 1 1)", NA))
  got <- DBI::dbGetQuery(con, paste0(
    "xr.DataArray([type(pts).__name__] + ",
    "[('None' if p is None else p.wkt) for p in pts], dims='i', name='v')"),
    params = list(pts = g))
  expect_identical(got$v, c("ndarray", "POINT (1 2)", "LINESTRING (0 0, 1 1)",
                            "None"))

  skip_if_no_py_module("geopandas")
  crs <- DBI::dbGetQuery(con,
    "xr.DataArray([type(pts).__name__, str(pts.crs.to_epsg()), str(len(pts))], dims='i', name='v')",
    params = list(pts = wk::xy(c(1, 2), c(3, 4), crs = "EPSG:4326")))
  expect_identical(crs$v, c("GeoSeries", "4326", "2"))

  skip_if_not_installed("sf")
  s <- sf::st_as_sf(data.frame(id = 1:3, x = 1:3, y = 4:6),
                    coords = c("x", "y"), crs = 3031)
  got <- DBI::dbGetQuery(con,
    "xr.DataArray([str(len(g)), str(g.crs.to_epsg())], dims='i', name='v')",
    params = list(g = s))
  expect_identical(got$v, c("3", "3031"))
})

test_that("xvec extracts points given from R", {
  skip_if_no_xarray()
  skip_if_not_installed("wk")
  skip_if_no_py_module("xvec")
  skip_if_no_py_module("geopandas")
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))
  pts <- wk::xy(c(1, 39), c(-79, -61), crs = "EPSG:4326")
  got <- DBI::dbGetQuery(con,
    "ds.sst.xvec.extract_points(pts, x_coords='lon', y_coords='lat')",
    params = list(pts = pts))
  ## one row per time per point, geometry carried along
  expect_equal(nrow(got), 3L * 2L)
  all <- DBI::dbGetQuery(con, "ds.sst")
  want <- all[all$lat == -80 & all$lon == 0, "sst"]
  expect_equal(got$sst[got$geometry == "POINT (1 -79)"], want)
})
