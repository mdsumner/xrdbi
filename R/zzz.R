.onLoad <- function(libname, pkgname) {
  ## the core only: xarray (bringing pandas and numpy) and one netCDF
  ## engine. Other IO engines are declared where they are used, e.g.
  ## reticulate::py_require(c("zarr", "gcsfs")) before connecting; see
  ## ?xrdbi. gdalxarray needs the GDAL Python bindings, which pip cannot
  ## install, so it is not declared here: use conda or a GDAL image.
  reticulate::py_require(c("xarray", "netCDF4"))
}
