## error if an xarray object would materialize more cells than allowed
guard_cells <- function(obj, max_cells, force) {
  if (isTRUE(force)) return(invisible(NULL))
  bt <- import_builtins(convert = FALSE)
  n <- tryCatch(py_to_r(bt$int(obj$size)), error = function(e) NA)
  if (!is.na(n) && is.finite(max_cells) && n > max_cells) {
    stop(sprintf(paste0(
      "materializing %s cells exceeds the guard (%s); ",
      "subset first, raise options(xrdbi.max_cells=), or use force = TRUE"),
      format(n, big.mark = ","), format(max_cells, big.mark = ",")),
      call. = FALSE)
  }
  invisible(NULL)
}

## the rendering: tidy long form, one row per cell
render_dataframe <- function(obj) {
  df <- obj$to_dataframe()$reset_index()
  out <- py_to_r(df)
  rownames(out) <- NULL
  out
}

## quote an R string as a Python string literal
py_repr_string <- function(x) {
  stopifnot(is.character(x), length(x) == 1L)
  paste0("'", gsub("'", "\\\\'", gsub("\\\\", "\\\\\\\\", x)), "'")
}


xrdbi_render_py <- paste(
  "def _xrdbi_render(obj):",
  "    import xarray as xr, pandas as pd, numpy as np",
  "    if isinstance(obj, xr.Dataset):",
  "        return obj.to_dataframe().reset_index()",
  "    if isinstance(obj, xr.DataArray):",
  "        name = obj.name if obj.name is not None else 'value'",
  "        if obj.ndim == 0:",
  "            return pd.DataFrame({name: [obj.item()]})",
  "        if name in obj.dims:",
  "            return pd.DataFrame({name: np.asarray(obj)})",
  "        if name in obj.coords:",
  "            obj = obj.drop_vars(name)",
  "        return obj.to_dataframe().reset_index()",
  "    return pd.DataFrame({'value': [obj]})",
  sep = "\n")
