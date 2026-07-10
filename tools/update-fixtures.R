# tools/update-fixtures.R
#
# Vendor a curated set of GDAL autotest data files into
# inst/extdata/gdal-autotest/ so tests are self-contained. Run from the
# package root with GDAL_AUTOTEST pointing at a GDAL checkout's
# autotest directory (only needed when UPDATING fixtures, never for
# testing):
#
#   GDAL_AUTOTEST=~/gdal/autotest Rscript tools/update-fixtures.R
#
# GDAL is MIT/X licensed; the vendored files carry that license. See
# the PROVENANCE file written alongside the fixtures.

manifest <- c(
  ## netcdf: baseline, CF packing, descending latitude, grid mapping
  "gdrivers/data/netcdf/trmm.nc",
  "gdrivers/data/netcdf/two_vars_scale_offset.nc",
  "gdrivers/data/netcdf/actual_range_with_order_different_than_latitude.nc",
  "gdrivers/data/netcdf/rotated_pole.nc",
  ## gtiff: the canonical tiny single-band, and a small 3-band RGB
  "gcore/data/byte.tif",
  "gcore/data/rgbsmall.tif"
)

src <- Sys.getenv("GDAL_AUTOTEST", "")
if (!nzchar(src)) src <- path.expand("~/gdal/autotest")
src <- path.expand(src)
if (!dir.exists(src)) {
  stop("set GDAL_AUTOTEST to a GDAL checkout's autotest directory")
}

dst_root <- file.path("inst", "extdata", "autotest")

if (anyDuplicated(basename(manifest))) {
  stop("manifest basenames collide; rename in the manifest")
}

copied <- character(0)
for (rel in manifest) {
  from <- file.path(src, rel)
  if (!file.exists(from)) {
    warning("missing in checkout, skipped: ", rel)
    next
  }
  to <- file.path(dst_root, basename(rel))
  dir.create(dst_root, recursive = TRUE, showWarnings = FALSE)
  file.copy(from, to, overwrite = TRUE)
  copied <- c(copied, sprintf("%s  <-  %s  (%d bytes)",
                              basename(rel), rel, file.size(to)))
}

## provenance record
gdal_ref <- tryCatch(
  system2("git", c("-C", src, "rev-parse", "HEAD"),
          stdout = TRUE, stderr = FALSE)[1],
  error = function(e) NA_character_)

writeLines(c(
  "Fixtures vendored from the GDAL autotest suite",
  "https://github.com/OSGeo/gdal (MIT/X license)",
  if (!is.na(gdal_ref)) paste("source commit:", gdal_ref),
  paste("vendored:", format(Sys.Date())),
  "",
  "files:",
  paste(" ", copied)
), file.path(dst_root, "PROVENANCE"))

cat("vendored", length(copied), "files into", dst_root, "\n")
cat(paste(" ", copied, collapse = "\n"), "\n")
