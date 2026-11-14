# r-xrdbi: point reticulate at this environment's Python, where conda put
# xarray, netCDF4, GDAL and gdalxarray. Without this, reticulate ignores
# an activated conda environment and provisions its own from PyPI, where
# gdalxarray cannot work. A RETICULATE_PYTHON the user set is left alone.
if [ -z "${RETICULATE_PYTHON:-}" ]; then
  export RETICULATE_PYTHON="${CONDA_PREFIX}/bin/python"
  export _R_XRDBI_SET_RETICULATE_PYTHON=1
fi
