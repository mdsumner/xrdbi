## Fixtures borrowed from the GDAL autotest suite. Set GDAL_AUTOTEST to
## your checkout (e.g. ~/gdal/autotest); everything here skips cleanly
## when it is absent. Expected values below were verified directly
## against these files with xarray 2026.4.0.

NC <- function(f) gdal_fixture("gdrivers", "data", "netcdf", f)

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

test_that("rotated_pole.nc: a 0-d data variable (grid mapping) renders", {
  skip_if_no_xarray()
  con <- open_fixture_con(NC("rotated_pole.nc"))
  on.exit(DBI::dbDisconnect(con))

  expect_true(DBI::dbExistsTable(con, "tg"))
  f <- DBI::dbListFields(con, "tg")
  expect_equal(f[1:2], c("y", "x"))

  ## grid-mapping variables are engine-dependent: netcdf4 exposes
  ## 'projection' as a 0-d data variable, GDAL-backed engines fold it
  ## into SRS metadata
  if (!DBI::dbExistsTable(con, "projection")) {
    skip("this engine does not expose the grid-mapping variable")
  }
  p <- DBI::dbGetQuery(con, "ds.projection")
  expect_equal(nrow(p), 1L)
  p2 <- DBI::dbReadTable(con, "projection")
  expect_equal(nrow(p2), 1L)
})
