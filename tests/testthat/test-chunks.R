## xr_chunks(): the storage chunk grid of a stored variable, and the
## chunks a selection touches (R/chunks.R)

## the OISST-shaped fixture with a storage layout declared the way
## backends declare it: time 1, lat 2, lon 2 -> 3 x 2 x 3 chunks
make_chunked_con <- function() {
  DBI::dbConnect(xarray(), builder = function(xr) {
    reticulate::py_run_string(paste(
      "import xarray as _xr, numpy as _np, pandas as _pd",
      "_dsk = _xr.Dataset(",
      "  {'sst': (('time','lat','lon'), _np.arange(60.).reshape(3, 4, 5))},",
      "  coords={'time': _pd.date_range('2026-01-01', periods=3),",
      "          'lat': _np.linspace(-80, -60, 4), 'lon': _np.linspace(0, 40, 5)})",
      "_dsk.sst.encoding['preferred_chunks'] = {'time': 1, 'lat': 2, 'lon': 2}",
      sep = "\n"), convert = FALSE)
    reticulate::py_eval("_dsk", convert = FALSE)
  })
}

test_that("a whole variable maps its full storage grid, in C order", {
  skip_if_no_xarray()
  con <- make_chunked_con()
  on.exit(DBI::dbDisconnect(con))
  ch <- xr_chunks(con, "ds.sst")
  expect_identical(attr(ch, "chunking"), "storage")
  expect_equal(nrow(ch), 3 * 2 * 3)
  expect_equal(ch$time_chunk, rep(0:2, each = 6))
  expect_equal(ch$lon_chunk, rep(0:2, times = 6))
  ## lon 5 in chunks of 2: 0-2, 2-4, 4-5
  expect_equal(unique(ch[, c("lon_start", "lon_stop")]),
               data.frame(lon_start = c(0, 2, 4), lon_stop = c(2, 4, 5)))
  expect_equal(sum(ch$cells), 60)
  expect_equal(ch$selected, ch$cells)
  ## cell edges: lat steps by 20/3, so the first chunk spans
  ## -80 - 10/3 .. -80 + 20/3 + 10/3
  expect_equal(ch$lat_min[1], -80 - 10 / 3)
  expect_equal(ch$lat_max[1], -80 + 20 / 3 + 10 / 3)
  ## a time axis reports its first and last values
  expect_s3_class(ch$time_min, "POSIXct")
  expect_equal(ch$time_min, ch$time_max)
})

test_that("a selection maps the chunks it touches and how much of each", {
  skip_if_no_xarray()
  con <- make_chunked_con()
  on.exit(DBI::dbDisconnect(con))
  ## lat rows 1-2 straddle lat chunks 0 and 1; lon 0 and 4 sit in lon
  ## chunks 0 and 2; time 1 only
  ch <- xr_chunks(con, "ds.sst.isel(time=1, lat=slice(1, 3), lon=[0, 4])")
  expect_equal(nrow(ch), 1 * 2 * 2)
  expect_equal(unique(ch$time_chunk), 1)
  expect_equal(ch$lat_chunk, c(0, 0, 1, 1))
  expect_equal(ch$lon_chunk, c(0, 2, 0, 2))
  expect_equal(ch$selected, rep(1, 4))
  expect_equal(sum(ch$selected), 2 * 2)

  ## label selections place the same way, params included
  ch2 <- xr_chunks(con, "ds.sst.sel(time=t0, lat=slice(-75, -65))",
                   params = list(t0 = as.Date("2026-01-03")))
  expect_equal(unique(ch2$time_chunk), 2)
  expect_equal(sum(ch2$selected), 2 * 5)

  ## from a held result too
  res <- DBI::dbSendQuery(con, "ds.sst.isel(time=0)")
  on.exit(DBI::dbClearResult(res), add = TRUE)
  expect_equal(nrow(xr_chunks(res)), 2 * 3)
})

test_that("descending coordinates keep min below max", {
  skip_if_no_xarray()
  con <- make_desc_con()
  on.exit(DBI::dbDisconnect(con))
  ch <- xr_chunks(con, "ds.u")
  expect_identical(attr(ch, "chunking"), "none")
  expect_equal(nrow(ch), 1L)
  ## latitude 90 .. 50 in steps of 10: edges 95 .. 45
  expect_equal(c(ch$latitude_min, ch$latitude_max), c(45, 95))
})

test_that("no storage layout: dask chunks, else one chunk", {
  skip_if_no_xarray()
  con <- make_con()
  on.exit(DBI::dbDisconnect(con))
  one <- xr_chunks(con, "ds.sst")
  expect_identical(attr(one, "chunking"), "none")
  expect_equal(one$cells, 60)

  skip_if_not(reticulate::py_module_available("dask"), "python dask not available")
  dk <- xr_chunks(con, "ds.sst.chunk({'time': 2})")
  expect_identical(attr(dk, "chunking"), "dask")
  expect_equal(dk$time_start, c(0, 2))
  expect_equal(dk$time_stop, c(2, 3))
})

test_that("guard, refusals and the geometry column", {
  skip_if_no_xarray()
  con <- make_chunked_con()
  on.exit(DBI::dbDisconnect(con))
  expect_error(xr_chunks(con, "ds.sst", max_chunks = 10), "touches 18 chunks")
  expect_equal(nrow(xr_chunks(con, "ds.sst", max_chunks = 10, force = TRUE)), 18L)
  expect_error(xr_chunks(con, paste0(
    "ds.sst.isel(lat=xr.DataArray([0, 1], dims='pt'), ",
    "lon=xr.DataArray([0, 1], dims='pt'))")), "pointwise")
  expect_error(xr_chunks(con, "ds.sst.mean('time').rename('m')"),
               "one stored variable")
  ## a dim stripped of its coordinate, then subset, cannot be placed
  expect_error(xr_chunks(con, "ds.sst.drop_vars('lat').isel(lat=slice(1, 3))"),
               "'lat' has no coordinate and was subset")

  skip_if_not_installed("wk")
  ch <- xr_chunks(con, "ds.sst.isel(time=0)")
  expect_s3_class(ch$geometry, "wk_rct")
  expect_equal(unlist(wk::wk_bbox(ch$geometry))[1:4],
               c(xmin = -5, ymin = -80 - 10 / 3, xmax = 45, ymax = -60 + 10 / 3))
})

test_that("GDAL blocks via gdalxarray: same bbox and CRS as xr_raster", {
  skip_if_no_xarray()
  skip_if_not(reticulate::py_module_available("gdalxarray"),
              "python gdalxarray not available")
  skip_if_not_installed("wk")
  con <- tryCatch(
    DBI::dbConnect(xarray(), gdal_fixture("byte.tif"), engine = "gdalxarray",
                   multidim = FALSE),
    error = function(e) skip(paste("gdalxarray cannot open byte.tif:",
                                   conditionMessage(e))))
  on.exit(DBI::dbDisconnect(con))
  st <- "ds.band_data.isel(band=0, y=slice(2, 7), x=slice(3, 9))"
  ch <- xr_chunks(con, st)
  r <- xr_raster(con, "ds.band_data.isel(band=0)")
  expect_identical(attr(ch, "chunking"), "storage")
  expect_equal(sum(ch$selected), 5 * 6)
  ## a computed (RasterIndex) axis is placed like a stored one: the
  ## touched blocks cover rows 2-6 and columns 3-8, whatever the layout
  expect_lte(min(ch$y_start), 2)
  expect_gte(max(ch$y_stop), 7)
  expect_lte(min(ch$x_start), 3)
  expect_gte(max(ch$x_stop), 9)
  ## the CRS comes from gdalxarray's CRSIndex, for both renderings
  expect_true(nzchar(attr(r, "gis")$srs))
  expect_identical(wk::wk_crs(ch$geometry), attr(r, "gis")$srs)
  whole <- xr_chunks(con, "ds.band_data.isel(band=0)")
  expect_equal(unname(unlist(wk::wk_bbox(wk::wk_envelope(whole$geometry)))[1:4]),
               attr(r, "gis")$bbox)
})

test_that("zarr v3 shards: the shard grid, and the shard of each chunk", {
  skip_if_no_xarray()
  skip_if_not(reticulate::py_module_available("zarr"), "python zarr not available")
  zv <- reticulate::py_to_r(reticulate::import("zarr")$`__version__`)
  skip_if(package_version(sub("[^0-9.].*$", "", zv)) < "3.0", "zarr < 3 has no shards")
  path <- file.path(tempfile("sharded"), "s.zarr")
  dir.create(dirname(path))
  on.exit(unlink(dirname(path), recursive = TRUE))
  ## (time 4, y 120, x 200) in chunks (1, 20, 25), shards (2, 60, 100):
  ## 2 x 2 x 2 shards, each holding 2 x 3 x 4 = 24 chunks
  reticulate::py_run_string(sprintf(paste(
    "import xarray as _xr, numpy as _np, pandas as _pd",
    "_xr.Dataset({'v': (('time', 'y', 'x'), _np.zeros((4, 120, 200), 'float32'))},",
    "  coords={'time': _pd.date_range('2026-01-01', periods=4),",
    "          'y': _np.arange(120) + 0.5, 'x': _np.arange(200) + 0.5}).to_zarr(",
    "  '%s', mode='w', zarr_format=3, consolidated=False,",
    "  encoding={'v': {'chunks': (1, 20, 25), 'shards': (2, 60, 100)}})",
    sep = "\n"), path), convert = FALSE)
  con <- DBI::dbConnect(xarray(), path, engine = "zarr", consolidated = FALSE)
  on.exit(DBI::dbDisconnect(con), add = TRUE)

  sh <- xr_chunks(con, "ds.v", level = "shards")
  expect_identical(attr(sh, "chunking"), "shards")
  expect_equal(nrow(sh), 8L)
  expect_equal(unique(sh$cells), 2 * 60 * 100)

  ch <- xr_chunks(con, "ds.v")
  expect_identical(attr(ch, "chunking"), "storage")
  expect_equal(nrow(ch), 4 * 6 * 8)
  per_shard <- table(paste(ch$time_shard, ch$y_shard, ch$x_shard))
  expect_equal(as.vector(per_shard), rep(24, 8))

  ## a window across a shard corner: rows 50-69, columns 90-109
  st <- "ds.v.isel(time=1, y=slice(50, 70), x=slice(90, 110))"
  expect_equal(nrow(xr_chunks(con, st, level = "shards")), 1 * 2 * 2)
  w <- xr_chunks(con, st)
  expect_equal(w$y_chunk, c(2, 2, 3, 3))
  expect_equal(w$x_chunk, c(3, 4, 3, 4))
  expect_equal(sum(w$selected), 20 * 20)

  expect_error(xr_chunks(make_chunked_con(), "ds.sst", level = "shards"),
               "not stored in shards")
})

test_that("curvilinear: each chunk gets the envelope of its 2-D lon/lat", {
  skip_if_no_xarray()
  ## dims (y 6, x 8) without 1-D coords; 2-D lon/lat recognised by
  ## standard_name; storage chunks (3, 4) -> 2 x 2 blocks
  con <- DBI::dbConnect(xarray(), builder = function(xr) {
    reticulate::py_run_string(paste(
      "import xarray as _xr, numpy as _np",
      "_Y, _X = _np.meshgrid(_np.arange(6.), _np.arange(8.), indexing='ij')",
      "_dsc = _xr.Dataset({'t': (('y', 'x'), _X + 10 * _Y)},",
      "  coords={'nav_lon': (('y', 'x'), 100 + 2 * _X + 0.5 * _Y, {'standard_name': 'longitude'}),",
      "          'nav_lat': (('y', 'x'), -60 + 1.5 * _Y - 0.25 * _X, {'standard_name': 'latitude'})})",
      "_dsc.t.encoding['preferred_chunks'] = {'y': 3, 'x': 4}",
      sep = "\n"), convert = FALSE)
    reticulate::py_eval("_dsc", convert = FALSE)
  })
  on.exit(DBI::dbDisconnect(con))
  ch <- xr_chunks(con, "ds.t")
  expect_equal(nrow(ch), 4L)
  Y <- matrix(0:5, 6, 8)
  X <- matrix(0:7, 6, 8, byrow = TRUE)
  lon <- 100 + 2 * X + 0.5 * Y
  lat <- -60 + 1.5 * Y - 0.25 * X
  for (k in seq_len(4)) {
    r <- (ch$y_start[k] + 1):ch$y_stop[k]
    cl <- (ch$x_start[k] + 1):ch$x_stop[k]
    expect_equal(c(ch$nav_lon_min[k], ch$nav_lon_max[k]), range(lon[r, cl]))
    expect_equal(c(ch$nav_lat_min[k], ch$nav_lat_max[k]), range(lat[r, cl]))
  }
  ## a selection keeps only the blocks it touches, envelopes intact
  w <- xr_chunks(con, "ds.t.isel(y=slice(4, 6), x=slice(1, 6))")
  expect_equal(w$y_chunk, c(1, 1))
  expect_equal(w$nav_lon_min, ch$nav_lon_min[ch$y_chunk == 1])

  skip_if_not_installed("wk")
  expect_identical(wk::wk_crs(ch$geometry), "OGC:CRS84")
  expect_equal(unlist(wk::wk_bbox(ch$geometry))[1:4],
               c(xmin = min(lon), ymin = min(lat), xmax = max(lon), ymax = max(lat)))
})
