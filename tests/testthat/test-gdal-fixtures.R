## Fixtures borrowed from the GDAL autotest suite. Set GDAL_AUTOTEST to
## your checkout (e.g. ~/gdal/autotest); everything here skips cleanly
## when it is absent. Expected values below were verified directly
## against these files with xarray 2026.4.0.

NC <- function(f) gdal_fixture(f)

test_that("trmm.nc: baseline tables, fields, query", {
  skip_if_no_xarray()
  con <- open_fixture_con(NC("trmm.nc"))
  on.exit(DBI::dbDisconnect(con))

  expect_true(DBI::dbExistsTable(con, "pcp"))
  expect_true(all(c("latitude", "longitude", "time")
                  %in% DBI::dbListTables(con)))

  f <- DBI::dbListFields(con, "pcp")
  expect_equal(f[length(f)], "pcp")

  info <- DBI::dbGetInfo(con)
  expect_equal(info$sizes$latitude, 40L)
  expect_equal(info$sizes$longitude, 40L)

  ## 4 lat rows x 40 lons (verified: 160)
  df <- DBI::dbGetQuery(con,
    "ds.pcp.sel(latitude=slice(-19.875, -19.0)).isel(time=0)")
  expect_equal(nrow(df), 160L)
  expect_true(all(c("latitude", "longitude", "pcp") %in% names(df)))

  ## dim coord as a table
  lats <- DBI::dbReadTable(con, "latitude")
  expect_equal(dim(lats), c(40L, 1L))
})

test_that("two_vars_scale_offset.nc: CF packing decodes through the veneer", {
  skip_if_no_xarray()
  con <- open_fixture_con(NC("two_vars_scale_offset.nc"))
  on.exit(DBI::dbDisconnect(con))

  expect_true(all(c("z", "q") %in% DBI::dbListTables(con)))

  ## packed shorts decode to float via scale_factor/add_offset;
  ## verified corner values: z[0,0] == 2.5, q[0,0] == 12.5
  z00 <- DBI::dbGetQuery(con, "ds.z.isel(x=0, y=0)")
  expect_equal(z00$z, 2.5)
  q00 <- DBI::dbGetQuery(con, "ds.q.isel(x=0, y=0)")
  expect_equal(q00$q, 12.5)

  ## whole-variable read is float post-decode
  z <- DBI::dbReadTable(con, "z")
  expect_type(z$z, "double")
  expect_equal(nrow(z), 21L * 21L)
})

test_that("descending latitude in a real file triggers the hint", {
  skip_if_no_xarray()
  con <- open_fixture_con(
    NC("actual_range_with_order_different_than_latitude.nc"))
  on.exit(DBI::dbDisconnect(con))

  ## latitude runs -16.875 .. -16.925 (DESCENDING); the ascending slice
  ## selects nothing and the veneer says why
  expect_message(
    DBI::dbGetQuery(con,
      "ds.CRW_HOTSPOT.sel(latitude=slice(-16.93, -16.87))"),
    "DESCENDING")

  ## sliced in coordinate order: 1 time x 2 lat x 2 lon (verified)
  df <- DBI::dbGetQuery(con,
    "ds.CRW_HOTSPOT.sel(latitude=slice(-16.87, -16.93))")
  expect_equal(nrow(df), 4L)
})

## The grid-mapping variable is engine-dependent, so each test names its
## engine: without one, xarray falls through to whichever engine can open
## the file (gdalxarray, when netCDF4 is missing) and the test would check
## the wrong thing.
test_that("rotated_pole.nc via netcdf4: a 0-d data variable (grid mapping) renders", {
  skip_if_no_xarray()
  skip_if_not(reticulate::py_module_available("netCDF4"),
              "python netCDF4 not available")
  con <- open_fixture_con(NC("rotated_pole.nc"), engine = "netcdf4")
  on.exit(DBI::dbDisconnect(con))

  expect_true(DBI::dbExistsTable(con, "tg"))
  f <- DBI::dbListFields(con, "tg")
  expect_equal(f[1:2], c("y", "x"))

  ## netcdf4 keeps 'projection' as a 0-d data variable
  expect_true(DBI::dbExistsTable(con, "projection"))
  p <- DBI::dbGetQuery(con, "ds.projection")
  expect_equal(nrow(p), 1L)
  p2 <- DBI::dbReadTable(con, "projection")
  expect_equal(nrow(p2), 1L)
})

test_that("rotated_pole.nc via gdalxarray (classic): the grid mapping becomes the srs", {
  skip_if_no_xarray()
  skip_if_not(reticulate::py_module_available("gdalxarray"),
              "python gdalxarray not available")
  con <- open_fixture_con(NC("rotated_pole.nc"), engine = "gdalxarray",
                          multidim = FALSE)
  on.exit(DBI::dbDisconnect(con))

  ## GDAL folds 'projection' into the CRS, which gdalxarray carries on
  ## an xproj CRSIndex; xr_raster() lifts it from there
  expect_false(DBI::dbExistsTable(con, "projection"))
  r <- xr_raster(con, "ds.band_data")
  g <- attr(r, "gis")
  expect_equal(g$dim, c(137, 108, 1))
  ## GDAL names it "Rotated_pole" with a "Pole rotation" conversion;
  ## match loosely so a GDAL change to the naming does not break this
  expect_match(g$srs, "rotat", ignore.case = TRUE)
})
