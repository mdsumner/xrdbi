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
  frame_to_r(conn, conn@ptr$render(obj))
}

## pandas DataFrame -> R data.frame, column by column. reticulate's
## whole-frame conversion takes ~2 s per million rows on a datetime
## column, turns timedeltas into NA dates, leaves pandas' default string
## dtype as a Python object, and errors on categoricals. The Python
## helper hands over plain numpy buffers plus what R needs to rebuild
## each type; see xrdbi_columns_py.
frame_to_r <- function(conn, df) {
  bt <- import_builtins(convert = FALSE)
  n <- py_to_r(bt$len(df))
  cols <- py_to_r(conn@ptr$columns(df))
  out <- lapply(cols, column_to_r)
  names(out) <- vapply(cols, function(col) col$name, "")
  list2DF(out, nrow = n)
}

column_to_r <- function(col) {
  v <- col$values
  dim(v) <- NULL
  v <- switch(col$kind,
    time = .POSIXct(v, tz = if (col$tz %in% OlsonNames()) col$tz else "UTC"),
    difftime = as.difftime(v, units = "secs"),
    text = ,
    factor = {
      ## 0-based codes, -1 for missing
      idx <- v + 1L
      idx[idx < 1L] <- NA_integer_
      lev <- as.character(unlist(col$levels))
      if (col$kind == "text") {
        lev[idx]
      } else {
        structure(idx, levels = lev,
                  class = c(if (isTRUE(col$ordered)) "ordered", "factor"))
      }
    },
    v)
  if (!is.null(col$na)) v[as.vector(col$na)] <- NA
  v
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

## one dict per column: 'values' is a numpy array reticulate converts
## directly; 'kind' says how R rebuilds the type:
##   plain    numbers and booleans as-is
##   time     float seconds since the epoch, 'tz' for display (naive = UTC)
##   difftime float seconds
##   text     0-based codes into 'levels' (strings, bytes, cftime, ...)
##   factor   0-based codes into 'levels', with 'ordered'
## 'na' is a boolean mask where the values buffer can't hold a missing
## value itself (NaT, nullable integers), else None
xrdbi_columns_py <- r"---(
def _xrdbi_columns(df):
    import numpy as np, pandas as pd

    def text(u):
        if isinstance(u, bytes):
            return u.decode('utf-8', 'replace')
        return u if isinstance(u, str) else str(u)

    out = []
    for i in range(df.shape[1]):
        s = df.iloc[:, i]
        d = s.dtype
        col = {'name': str(df.columns[i]), 'kind': 'plain', 'na': None,
               'tz': 'UTC'}
        if isinstance(d, pd.DatetimeTZDtype):
            col['tz'] = str(d.tz)
            s = s.dt.tz_convert('UTC').dt.tz_localize(None)
            d = s.dtype
        if isinstance(d, pd.CategoricalDtype):
            col['kind'] = 'factor'
            col['values'] = s.cat.codes.to_numpy().astype('int32')
            col['levels'] = np.array([text(c) for c in d.categories],
                                     dtype=object)
            col['ordered'] = bool(d.ordered)
        elif isinstance(d, np.dtype) and d.kind in 'Mm':
            v = s.to_numpy()
            unit = np.datetime_data(v.dtype)[0]
            if unit in ('Y', 'M', 'generic'):
                v = v.astype(d.kind + '8[s]')
                unit = 's'
            na = np.isnat(v)
            scale = np.timedelta64(1, unit) / np.timedelta64(1, 's')
            col['values'] = v.view('int64').astype('float64') * scale
            col['kind'] = 'time' if d.kind == 'M' else 'difftime'
            if na.any():
                col['na'] = na
        elif isinstance(d, np.dtype) and d.kind in 'biufc':
            v = s.to_numpy()
            if d.kind == 'f' and d.itemsize < 4:
                v = v.astype('float32')
            col['values'] = v
        elif (getattr(d, 'numpy_dtype', None) is not None
              and d.numpy_dtype.kind in 'biuf'):
            # nullable (masked or arrow-backed) numbers and booleans
            nd = d.numpy_dtype
            na = s.isna().to_numpy()
            col['values'] = s.to_numpy(dtype=nd,
                                       na_value=False if nd.kind == 'b' else 0)
            if na.any():
                col['na'] = na
        else:
            # anything else becomes text; factorize so each distinct value
            # is converted once (a cftime coordinate repeats through the
            # long form)
            try:
                codes, uniques = pd.factorize(s, use_na_sentinel=True)
            except TypeError:
                # unhashable objects: one level per row
                codes = np.where(s.isna().to_numpy(), -1, np.arange(len(s)))
                uniques = s.to_numpy()
            col['kind'] = 'text'
            col['values'] = codes.astype('int32')
            col['levels'] = np.array([text(u) for u in uniques], dtype=object)
        out.append(col)
    return out
)---"

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


