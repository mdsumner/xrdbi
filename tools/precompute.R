## Rebuild the pre-computed vignettes from their .Rmd.orig sources.
##
## CRAN builds vignettes without Python, so vignettes/xrdbi.Rmd ships with
## its output already in it. Run this from the package root, with the
## current xrdbi installed and a Python that has xarray and netCDF4:
##
##   R CMD INSTALL . && Rscript tools/precompute.R
##
## then check the diff of vignettes/xrdbi.Rmd before committing.

knitr::knit("vignettes/xrdbi.Rmd.orig", "vignettes/xrdbi.Rmd")
