@REM r-xrdbi: undo activate.bat, only if it set RETICULATE_PYTHON
@if defined _R_XRDBI_SET_RETICULATE_PYTHON (
  @set "RETICULATE_PYTHON="
  @set "_R_XRDBI_SET_RETICULATE_PYTHON="
)
