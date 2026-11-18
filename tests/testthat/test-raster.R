## xr_raster: renders a slab in gdalraster's in-memory format (the
## read_ds() vector-with-gis-attribute). Values in the fixtures encode
## position so any orientation error changes the numbers.

make_pattern_con <- function() {
  DBI::dbConnect(xarray(), builder = function(xr) {
    reticulate::py_run_string(paste(
      "import xarray as _xr, numpy as _np, pandas as _pd",
      "_lat = _np.linspace(-80.0, -60.0, 4)   # ASCENDING",
      "_latd = _np.linspace(-60.0, -80.0, 4)  # DESCENDING",
      "_lon = _np.linspace(0.0, 40.0, 5)",
      "_t = _np.arange(3.0)",
      "_v = (_t[:,None,None]*1e6 + _lat[None,:,None]*1000",
      "      + _lon[None,None,:]).astype('float32')",
      "_vd = (_latd[:,None]*1000 + _lon[None,:]).astype('float32')",
      "_dsr = _xr.Dataset(",
      "  {'sst': (('time','lat','lon'), _v),",
      "   'nth': (('latd','lon'), _vd),",
      "   'irr': (('lat','w'), _np.ones((4,3)))},",
      "  coords={'time': _pd.date_range('2026-01-01', periods=3),",
      "          'lat': _lat, 'latd': _latd, 'lon': _lon,",
      "          'w': [0.0, 1.0, 3.0]})",
      sep = "\n"), convert = FALSE)
    reticulate::py_eval("_dsr", convert = FALSE)
  })
}

expected_bbox <- c(-5, -80 - (20 / 3) / 2, 45, -60 + (20 / 3) / 2)

test_that("single band: gis attribute and orientation by value", {
  skip_if_no_xarray()
  con <- make_pattern_con()
  on.exit(DBI::dbDisconnect(con))

  r <- xr_raster(con, "ds.sst.isel(time=0)")
  g <- attr(r, "gis")
  expect_equal(g$type, "raster")
  expect_equal(g$dim, c(5, 4, 1))
  expect_equal(g$bbox, expected_bbox, tolerance = 1e-10)
  expect_equal(g$datatype, "Float32")
  expect_equal(g$srs, "")


  expect_length(r, 20L)
  ## ascending input flipped: first pixel is max(lat), min(lon)
  expect_equal(r[1], -60000)
  expect_equal(r[length(r)], -79960)
})

test_that("descending y needs no flip and renders identically", {
  skip_if_no_xarray()
  con <- make_pattern_con()
  on.exit(DBI::dbDisconnect(con))

  r <- xr_raster(con, "ds.nth")
  expect_equal(attr(r, "gis")$bbox, expected_bbox, tolerance = 1e-10)
  expect_equal(r[1], -60000)
  expect_equal(r[length(r)], -79960)
})

test_that("3-D renders band-sequential in dim order; as_list mirrors", {
  skip_if_no_xarray()
  con <- make_pattern_con()
  on.exit(DBI::dbDisconnect(con))

  r <- xr_raster(con, "ds.sst")
  g <- attr(r, "gis")
  expect_equal(g$dim, c(5, 4, 3))
  expect_equal(g$datatype, rep("Float32", 3))
  expect_length(r, 60L)
  expect_equal(r[1], -60000)
  expect_equal(r[1 + 20], 1e6 - 60000)
  expect_equal(r[1 + 40], 2e6 - 60000)

  rl <- xr_raster(con, "ds.sst", as_list = TRUE)
  expect_length(rl, 3L)
  expect_equal(rl[[2]][1], 1e6 - 60000)
  expect_equal(attr(rl, "gis")$dim, c(5, 4, 3))
})

test_that("plot_raster consumes the object directly", {
  skip_if_no_xarray()
  skip_if_not_installed("gdalraster")
  con <- make_pattern_con()
  on.exit(DBI::dbDisconnect(con))

  r <- xr_raster(con, "ds.sst.isel(time=0)")
expect_equal(r[c(10L, 11L, 6L, 2L, 14L, 20L, 9L, 1L, 7L, 16L)], c(-66626.6640625, -73333.3359375, -66666.6640625, -59990, -73303.3359375,
                                                                  -79960, -66636.6640625, -60000, -66656.6640625, -80000))
  expect_equal(attributes(r), list(gis = list(type = "raster", bbox = c(-5, -83.3333333333333,
                                                                             45, -56.6666666666667), dim = c(5, 4, 1), srs = "", datatype = "Float32")))
})

test_that("works from a held result", {
  skip_if_no_xarray()
  con <- make_pattern_con()
  on.exit(DBI::dbDisconnect(con))

  res <- DBI::dbSendQuery(con, "ds.sst.isel(time=1)")
  r <- xr_raster(res)
  expect_equal(r[1], 1e6 - 60000)
  DBI::dbClearResult(res)
  expect_false(DBI::dbIsValid(res))
})

test_that("guard and kind errors", {
  skip_if_no_xarray()
  con <- make_pattern_con()
  on.exit(DBI::dbDisconnect(con))

  expect_error(xr_raster(con, "ds.sst", max_cells = 10), "exceeds the guard")
  expect_no_error(xr_raster(con, "ds.sst", max_cells = 10, force = TRUE))
  expect_error(xr_raster(con, "ds"), "select one variable")
  expect_error(xr_raster(con, "ds.irr"), "not regular")
  expect_error(xr_raster(con, "ds.sst.isel(time=0, lat=0)"),
               "2-D slab or 3-D")
  ## 4-D refuses with the explicit flatten recipe rather than guessing
  expect_error(xr_raster(con, "ds.sst.expand_dims(zlev=[0.0, 10.0])"),
               "stack\\(band=")
})

test_that("descending x and ascending y flip together; integers stay integer", {
  skip_if_no_xarray()
  ## value = band * 100 + row * 10 + col, indexed as stored: (y up, x west)
  con <- DBI::dbConnect(xarray(), builder = function(xr) {
    reticulate::py_run_string(paste(
      "import xarray as _xr, numpy as _np",
      "_b, _r, _c = _np.meshgrid(_np.arange(2), _np.arange(3), _np.arange(4), indexing='ij')",
      "_fx = _xr.Dataset({'v': (('band', 'y', 'x'), (_b*100 + _r*10 + _c).astype('int16'))},",
      "  coords={'band': [1, 2], 'y': [10., 20., 30.], 'x': [4., 3., 2., 1.]})",
      sep = "\n"), convert = FALSE)
    reticulate::py_eval("_fx", convert = FALSE)
  })
  on.exit(DBI::dbDisconnect(con))

  r <- xr_raster(con, "ds.v")
  g <- attr(r, "gis")
  expect_equal(g$dim, c(4, 3, 2))
  expect_equal(g$bbox, c(0.5, 5, 4.5, 35))
  expect_equal(g$datatype, rep("Int16", 2))
  expect_type(r, "integer")
  ## top-left pixel: last stored row (y = 30), last stored column (x = 1)
  expect_null(dim(r))
  want <- unlist(lapply(0:1, function(b) {
    as.vector(t(outer(2:0, 3:0, function(i, j) b * 100L + i * 10L + j)))
  }))
  expect_identical(as.vector(r), want)

  rl <- xr_raster(con, "ds.v", as_list = TRUE)
  expect_identical(rl[[1]], want[1:12])
  expect_identical(rl[[2]], want[13:24])
})

test_that("squeeze admits singleton dims", {
  skip_if_no_xarray()
  con <- make_pattern_con()
  on.exit(DBI::dbDisconnect(con))

  r <- xr_raster(con, "ds.sst.isel(time=slice(0, 1))")
  expect_equal(attr(r, "gis")$dim, c(5, 4, 1))
  expect_equal(r[1], -60000)
})

test_that("float32 coordinates are regular despite their rounding", {
  skip_if_no_xarray()
  ## REGRESSION: rotated_pole.nc's float32 x/y (0.44 degree steps) wobble
  ## by ~1e-5 of the step and failed a fixed 1e-6 tolerance
  con <- open_fixture_con(gdal_fixture("rotated_pole.nc"))
  on.exit(DBI::dbDisconnect(con))
  r <- xr_raster(con, "ds.tg")
  g <- attr(r, "gis")
  expect_equal(g$dim, c(137, 108, 1))
  ## cell centres -35.25 .. 24.59 and -23.65 .. 23.43, half a step out
  expect_equal(g$bbox, c(-35.25 - 0.22, -23.65 - 0.22, 24.59 + 0.22, 23.43 + 0.22),
               tolerance = 1e-5)

  ## a genuinely irregular axis still refuses
  expect_error(
    xr_raster(con, "ds.tg.isel(x=[0, 1, 3])"), "'x' coordinate is not regular")
})

test_that("tidy rendering is unaffected by the raster path", {
  skip_if_no_xarray()
  con <- make_pattern_con()
  on.exit(DBI::dbDisconnect(con))
  invisible(xr_raster(con, "ds.sst.isel(time=0)"))
  df <- DBI::dbGetQuery(con, "ds.sst.isel(time=0).sel(lat=slice(-80,-70))")
  expect_equal(nrow(df), 10L)
})


test_that("srs lifts via CF grid_mapping pointer and dataset fallback", {
  skip_if_no_xarray()
  con <- DBI::dbConnect(xarray(), builder = function(xr) {
    reticulate::py_run_string(paste(
      "import xarray as _xr, numpy as _np",
      "_p = _xr.Dataset({'sst': (('y','x'), _np.ones((3,4), dtype='float32')),",
      "                  'crs': ((), _np.int32(0))},",
      "  coords={'y': _np.linspace(0., 200., 3),",
      "          'x': _np.linspace(0., 300., 4)})",
      "_p.sst.attrs['grid_mapping'] = 'crs'",
      sep = "\n"), convert = FALSE)
    reticulate::py_eval("_p", convert = FALSE)
  })
  on.exit(DBI::dbDisconnect(con))
  crs <- reticulate::py_get_item(xr_dataset(con), "crs")
  reticulate::py_set_item(crs$attrs, "grid_mapping_name",
                          "polar_stereographic")
  reticulate::py_set_item(crs$attrs, "crs_wkt", "PROJCRS[test]")
  reticulate::py_set_item(crs$attrs, "spatial_ref", "PROJCRS[test]")

  ## the crs data variable does not propagate through selection; the
  ## grid_mapping pointer on the variable finds it in the parent
  r <- xr_raster(con, "ds.sst")
  expect_identical(attr(r, "gis")$srs, "PROJCRS[test]")

  ## arithmetic strips attrs; conventional names at dataset level catch it
  r2 <- xr_raster(con, "ds.sst * 1.0")
  expect_identical(attr(r2, "gis")$srs, "PROJCRS[test]")


})

test_that("vector cubes and non-numeric axes refuse with a reason", {
  skip_if_no_xarray()
  skip_if_not(reticulate::py_module_available("shapely"),
              "python shapely not available")
  con <- DBI::dbConnect(xarray(), builder = function(xr) {
    reticulate::py_run_string(paste(
      "import xarray as _xr, numpy as _np, pandas as _pd, shapely as _sh",
      "_vc = _xr.Dataset({'v': (('time', 'geometry'), _np.arange(6.).reshape(2, 3))},",
      "  coords={'time': _pd.date_range('2026-01-01', periods=2),",
      "          'geometry': _np.array([_sh.Point(1, 2), _sh.Point(3, 4), _sh.Point(5, 6)], dtype=object)})",
      sep = "\n"), convert = FALSE)
    reticulate::py_eval("_vc", convert = FALSE)
  })
  on.exit(DBI::dbDisconnect(con))
  ## REGRESSION: this failed inside R with "'list' object cannot be
  ## coerced to type 'double'"
  expect_error(xr_raster(con, "ds.v"), "'geometry' holds geometries: a vector data cube")
  ## numeric in place of geometry, time last: time cannot be an x axis
  expect_error(xr_raster(con, paste0(
    "ds.v.assign_coords(geometry=[1.0, 2.0, 3.0]).transpose('geometry', 'time')")),
               "'time' coordinate is not numeric \\(M dtype\\)")
})

test_that("srs from CF grid_mapping parameters, when nothing authored", {
  skip_if_no_xarray()
  skip_if_not(reticulate::py_module_available("pyproj"),
              "python pyproj not available")
  ## Antarctic polar stereographic (EPSG:3031) as CF parameters only
  make <- function(wkt = NULL) {
    DBI::dbConnect(xarray(), builder = function(xr) {
      reticulate::py_run_string(paste(
        "import xarray as _xr, numpy as _np",
        "_ps = _xr.Dataset({'v': (('y', 'x'), _np.zeros((4, 5)), {'grid_mapping': 'crs'}),",
        "  'crs': ((), 0, {'grid_mapping_name': 'polar_stereographic',",
        "    'latitude_of_projection_origin': -90.0, 'standard_parallel': -71.0,",
        "    'straight_vertical_longitude_from_pole': 0.0,",
        "    'false_easting': 0.0, 'false_northing': 0.0,",
        "    'semi_major_axis': 6378137.0, 'inverse_flattening': 298.257223563})},",
        "  coords={'y': _np.arange(4) * 1e5, 'x': _np.arange(5) * 1e5})",
        sep = "\n"), convert = FALSE)
      ds <- reticulate::py_eval("_ps", convert = FALSE)
      if (!is.null(wkt)) {
        reticulate::py_get_item(ds, "crs")$attrs$update(list(crs_wkt = wkt))
      }
      ds
    })
  }
  con <- make()
  on.exit(DBI::dbDisconnect(con))
  srs <- attr(xr_raster(con, "ds.v"), "gis")$srs
  expect_match(srs, "Polar Stereographic")
  expect_match(srs, "-71")
  skip_if_not_installed("wk")
  expect_identical(wk::wk_crs(xr_chunks(con, "ds.v")$geometry), srs)

  ## authored WKT still wins over the parameters
  con2 <- make(wkt = "AUTHORED")
  on.exit(DBI::dbDisconnect(con2), add = TRUE)
  expect_identical(attr(xr_raster(con2, "ds.v"), "gis")$srs, "AUTHORED")
})
