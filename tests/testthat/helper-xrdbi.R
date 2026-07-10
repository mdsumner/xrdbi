skip_if_no_xarray <- function() {
  skip_if_not(reticulate::py_module_available("xarray"),
              "python xarray not available")
  skip_if_not(reticulate::py_module_available("pandas"),
              "python pandas not available")
}

## in-memory fixture, OISST-shaped: (time, lat, lon) with a scalar
## coordinate (zlev) and a 2-D non-dimension coordinate (cell_area),
## so that coords-as-tables rendering is exercised in all its shapes
make_con <- function() {
  DBI::dbConnect(xarray(), builder = function(xr) {
    reticulate::py_run_string(paste(
      "import xarray as _xr, numpy as _np, pandas as _pd",
      "_rng = _np.random.default_rng(42)",
      "_ds = _xr.Dataset(",
      "  {'sst': (('time','lat','lon'), _rng.random((3,4,5)).astype('float32')),",
      "   'ice': (('time','lat','lon'), _rng.random((3,4,5)).astype('float32'))},",
      "  coords={'time': _pd.date_range('2026-01-01', periods=3),",
      "          'lat': _np.linspace(-80,-60,4),",
      "          'lon': _np.linspace(0,40,5),",
      "          'zlev': 0.0,",
      "          'cell_area': (('lat','lon'), _np.ones((4,5)))})",
      sep = "\n"), convert = FALSE)
    reticulate::py_eval("_ds", convert = FALSE)
  })
}

## a descending-latitude fixture for the empty-result hint
make_desc_con <- function() {
  DBI::dbConnect(xarray(), builder = function(xr) {
    reticulate::py_run_string(paste(
      "import xarray as _xr, numpy as _np",
      "_dsd = _xr.Dataset(",
      "  {'u': (('latitude','longitude'), _np.zeros((5, 4)))},",
      "  coords={'latitude': _np.linspace(90, 50, 5),",
      "          'longitude': _np.linspace(0, 30, 4)})",
      sep = "\n"), convert = FALSE)
    reticulate::py_eval("_dsd", convert = FALSE)
  })
}

## GDAL autotest fixtures: set GDAL_AUTOTEST to your checkout, e.g.
## Sys.setenv(GDAL_AUTOTEST = "~/gdal/autotest"); tests skip when unset
gdal_autotest_dir <- function() {
  d <- Sys.getenv("GDAL_AUTOTEST", "")
  if (!nzchar(d)) {
    guess <- path.expand("~/gdal/autotest")
    if (dir.exists(guess)) d <- guess
  }
  path.expand(d)
}

gdal_fixture <- function(name) {
  f <- system.file("extdata", "autotest", name, package = "xrdbi")
  if (nzchar(f) && file.exists(f)) return(f)
  d <- gdal_autotest_dir()
  if (nzchar(d) && dir.exists(d)) {
    for (sub in c("gdrivers/data/netcdf", "gcore/data")) {
      f <- file.path(d, sub, name)
      if (file.exists(f)) return(f)
    }
  }
  skip(paste("fixture not vendored and no GDAL_AUTOTEST checkout:", name))
}

## open a fixture, skipping (not failing) if no netcdf engine can read it
open_fixture_con <- function(path, ...) {
  tryCatch(
    DBI::dbConnect(xarray(), path, ...),
    error = function(e) {
      skip(paste("could not open fixture (missing engine?):",
                 conditionMessage(e)))
    })
}
