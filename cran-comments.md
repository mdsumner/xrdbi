## Submission

This is a new submission.

## Python requirement

xrdbi is a DBI backend for 'xarray' objects held in a Python session via
'reticulate'. Its Python requirements are declared with
`reticulate::py_require()` in `.onLoad()`, which only records them; no
Python is started or provisioned when the package loads.

* Tests that need Python call `skip_on_cran()` before anything touches
  reticulate, because checking for a Python module would initialize
  Python and provision an environment from PyPI. The tests that need no
  Python (statement compilation, row-window and head-block arithmetic,
  printing helpers) run on CRAN.
* Examples that need Python are in `\dontrun{}`: they require a Python
  environment with 'xarray' and an IO engine, plus remote or local data
  files. The driver example runs everywhere.

## R CMD check results

0 errors | 0 warnings | 1 note

* This is a new release.
