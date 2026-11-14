@REM r-xrdbi: point reticulate at this environment's Python (see activate.sh)
@if not defined RETICULATE_PYTHON (
  @set "RETICULATE_PYTHON=%CONDA_PREFIX%\python.exe"
  @set "_R_XRDBI_SET_RETICULATE_PYTHON=1"
)
