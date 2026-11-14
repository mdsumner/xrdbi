# r-xrdbi: undo activate.sh, only if it set RETICULATE_PYTHON
if [ -n "${_R_XRDBI_SET_RETICULATE_PYTHON:-}" ]; then
  unset RETICULATE_PYTHON
  unset _R_XRDBI_SET_RETICULATE_PYTHON
fi
