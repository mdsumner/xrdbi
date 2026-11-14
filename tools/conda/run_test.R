## r-xrdbi recipe test: the activation script points reticulate at this
## environment's Python, and the GDAL engine works there
library(xrdbi)
rp <- Sys.getenv("RETICULATE_PYTHON")
stopifnot(nzchar(rp))
cfg <- reticulate::py_config()
stopifnot(normalizePath(rp) == normalizePath(cfg$python))
engines <- reticulate::py_eval("list(__import__('xarray').backends.list_engines())")
stopifnot(all(c("netcdf4", "gdalxarray") %in% engines))
con <- DBI::dbConnect(xarray(), builder = function(xr) {
  xr$Dataset(list(v = reticulate::tuple(list("x"), c(1, 2, 3))))
})
stopifnot(identical(DBI::dbGetQuery(con, "ds.v")$v, c(1, 2, 3)))
DBI::dbDisconnect(con)
