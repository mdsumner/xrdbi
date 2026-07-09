.onLoad <- function(libname, pkgname) {
  reticulate::py_require(c("xarray", "pandas", "numpy", "gdalxarray", "netcdf4"))
}
