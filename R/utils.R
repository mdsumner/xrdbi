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
render_dataframe <- function(conn, obj) {
  df <- conn@ptr$render(obj)
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
  "    if isinstance(obj, (xr.Dataset, xr.DataArray)):",
  "        if 0 in dict(obj.sizes).values():",
  "            # empty selection: frame from metadata, read no bytes",
  "            # (some backends, e.g. GDAL mdim, reject zero-count reads)",
  "            if isinstance(obj, xr.DataArray):",
  "                name = obj.name if obj.name is not None else 'value'",
  "                cols = [*obj.dims,",
  "                        *(c for c in obj.coords",
  "                          if c not in obj.dims and c != name),",
  "                        name]",
  "            else:",
  "                cols = [*obj.dims,",
  "                        *(c for c in obj.coords if c not in obj.dims),",
  "                        *obj.data_vars]",
  "            return pd.DataFrame(columns=list(dict.fromkeys(cols)))",
  "    if isinstance(obj, xr.Dataset):",
  "        return obj.to_dataframe().reset_index()",
  "    if isinstance(obj, xr.DataArray):",
  "        name = obj.name if obj.name is not None else 'value'",
  "        if obj.ndim == 0:",
  "            return pd.DataFrame({name: [obj.values[()]]})",
  "        if name in obj.dims:",
  "            return pd.DataFrame({name: np.asarray(obj)})",
  "        if name in obj.coords:",
  "            obj = obj.drop_vars(name)",
  "        return obj.to_dataframe().reset_index()",
  "    if isinstance(obj, pd.DataFrame):",
  "        return obj",
  "    return pd.DataFrame({'value': [obj]})",
  sep = "\n")

xrdbi_hint_py <- paste(
  "def _xrdbi_empty_hint(obj, ds):",
  "    import xarray as xr",
  "    if not isinstance(obj, (xr.Dataset, xr.DataArray)):",
  "        return None",
  "    msgs = []",
  "    for dim, size in obj.sizes.items():",
  "        if size != 0:",
  "            continue",
  "        if dim in ds.indexes:",
  "            idx = ds.indexes[dim]",
  "            lo, hi = idx[0], idx[-1]",
  "            if idx.is_monotonic_decreasing:",
  "                msgs.append(",
  "                    \"'%s' selected nothing: this coordinate is DESCENDING \"",
  "                    \"(%s .. %s) and label slices follow coordinate order; \"",
  "                    \"try slice(hi, lo)\" % (dim, lo, hi))",
  "            else:",
  "                msgs.append(",
  "                    \"'%s' selected nothing (coordinate spans %s .. %s)\"",
  "                    % (dim, lo, hi))",
  "        else:",
  "            msgs.append(\"'%s' selected nothing\" % dim)",
  "    return '; '.join(msgs) if msgs else None",
  sep = "\n")


