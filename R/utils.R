## error if an xarray object would materialize more cells than allowed
guard_cells <- function(obj, max_cells, force) {
  if (isTRUE(force)) return(invisible(NULL))
  bt <- import_builtins(convert = FALSE)
  n <- tryCatch({
    if (py_to_r(bt$hasattr(obj, "data_vars"))) {
      ## a Dataset has no .size: its long form is every dim combination
      ## times each data variable
      rows <- prod(as.numeric(unlist(py_to_r(bt$list(obj$sizes$values())))))
      rows * max(1, py_to_r(bt$len(obj$data_vars)))
    } else {
      ## float, not int: reticulate wraps a Python int above 2^31 into an
      ## R integer (2^31 -> NA, 1.7e10 -> negative), which disarmed the
      ## guard for exactly the reads it exists to stop
      py_to_r(bt$float(obj$size))
    }
  }, error = function(e) NA)
  if (!is.na(n) && is.finite(max_cells) && n > max_cells) {
    stop(sprintf(paste0(
      "materializing %s cells exceeds the guard (%s); ",
      "subset first, raise options(xrdbi.max_cells=), or use force = TRUE"),
      fmt_count(n), fmt_count(max_cells)),
      call. = FALSE)
  }
  invisible(NULL)
}

## names joined by ", ", cut to fit `width` with a total (ERA5 has 277)
fit_names <- function(x, width) {
  line <- paste(x, collapse = ", ")
  if (nchar(line) <= width) return(line)
  tail <- sprintf(", ... (%d total)", length(x))
  fits <- sum(cumsum(nchar(x) + 2L) - 2L <= width - nchar(tail))
  paste0(paste(x[seq_len(max(1L, fits))], collapse = ", "), tail)
}

## 20000000000 -> "20,000,000,000" (format() alone goes scientific)
fmt_count <- function(n) {
  format(n, big.mark = ",", scientific = FALSE, trim = TRUE)
}

## the rendering: tidy long form, one row per cell
render_dataframe <- function(conn, obj) {
  plan <- plan_result(conn, obj)
  out <- if (!is.null(plan)) plan_fetch(conn, plan, 0, plan$n) else
    frame_to_r(conn, conn@ptr$render(obj))
  set_geom_crs(out, geom_crs(conn, obj))
}

## The long form repeats every coordinate once per cell. For a
## DataArray or Dataset, R builds the dim, 1-D and scalar columns itself
## (rep() over the 1-D values) and only N-D variables, flattened in C
## order, cross from Python. NULL means the object needs the pandas
## render (0-d, empty, MultiIndex or other non-dim indexes, pandas
## extension arrays, a DataArray name that is also a coordinate, or not
## xarray at all).
plan_result <- function(conn, obj) {
  p <- conn@ptr$plan(obj)
  if (inherits(p, "python.builtin.NoneType")) return(NULL)
  meta <- py_to_r(py_get_item(p, 0L))
  shape <- as.numeric(unlist(meta$shape))
  cols <- lapply(meta$cols, function(col) {
    if (!is.null(col$col)) col$vals <- column_to_r(col$col)
    col$col <- NULL
    col
  })
  list(shape = shape, n = prod(shape), cols = cols,
       flats = py_get_item(p, 1L))
}

## rows [start, stop) of a planned result, 0-based
plan_fetch <- function(conn, plan, start, stop) {
  len <- stop - start
  shape <- plan$shape
  whole <- start == 0 && stop == plan$n
  out <- lapply(plan$cols, function(col) {
    switch(col$kind,
      dim = {
        ax <- col$axis + 1L
        inner <- prod(shape[-seq_len(ax)])
        if (whole) {
          rep(rep(col$vals, each = inner),
              times = prod(shape[seq_len(ax - 1L)]))
        } else {
          col$vals[dim_window(shape[ax], inner, start, len)]
        }
      },
      scalar = rep(col$vals, len),
      flat = column_to_r(py_to_r(conn@ptr$slice(
        py_get_item(plan$flats, as.integer(col$flat)), start, stop))))
  })
  names(out) <- vapply(plan$cols, function(col) col$name, "")
  list2DF(out, nrow = len)
}

## 1-based indices into a dimension's n values for rows [start,
## start + len) of the C-order long form, where each value repeats
## `inner` times per pass. Equivalent to ((row %/% inner) %% n) + 1 but
## built with rep(): R's %/% and %% on doubles cost ~0.25 s per million
## rows, this ~5 ms
dim_window <- function(n, inner, start, len) {
  if (len < 1) return(integer(0))
  period <- n * inner
  if (period <= len) {
    ## the chunk spans whole periods: rotate one period, recycle it
    p0 <- start %% period
    pat <- rep(seq_len(n), each = inner)
    if (p0 > 0) pat <- pat[c((p0 + 1):period, seq_len(p0))]
    rep_len(pat, len)
  } else {
    ## the chunk sits inside about one period: one run per value touched
    k <- seq(start %/% inner, (start + len - 1) %/% inner)
    runs <- rep(inner, length(k))
    runs[1L] <- min(inner - start %% inner, len)
    if (length(k) > 1L) runs[length(k)] <- (start + len - 1) %% inner + 1
    rep(as.integer(k %% n) + 1L, times = runs)
  }
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

## the CRS of each geometry coordinate of an xarray object (named list)
geom_crs <- function(conn, obj) {
  tryCatch(py_to_r(conn@ptr$geom_crs(obj)), error = function(e) list())
}

## put those CRSs on the matching wk columns of a fetched frame
set_geom_crs <- function(df, crs) {
  for (nm in intersect(names(crs), names(df))) {
    if (inherits(df[[nm]], "wk_wkb")) df[[nm]] <- wk::wk_set_crs(df[[nm]], crs[[nm]])
  }
  df
}

column_to_r <- function(col) {
  v <- col$values
  dim(v) <- NULL
  v <- switch(col$kind,
    time = .POSIXct(v, tz = if (col$tz %in% OlsonNames()) col$tz else "UTC"),
    difftime = as.difftime(v, units = "secs"),
    wkb = {
      ## 0-based codes into the geometries, -1 for missing
      idx <- v + 1L
      idx[idx < 1L] <- NA_integer_
      buf <- as.raw(as.vector(col$levels))
      len <- as.vector(col$lengths)
      ends <- cumsum(len)
      geoms <- lapply(seq_along(len), function(i) {
        if (len[i] == 0) NULL else buf[(ends[i] - len[i] + 1):ends[i]]
      })
      wk::wkb(geoms)[idx]
    },
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
  "        if len(obj.dims) == 0:",
  "            # to_dataframe refuses 0-d: one row, a column per variable",
  "            return pd.DataFrame({k: [v.values[()]]",
  "                                 for k, v in obj.variables.items()})",
  "        return obj.to_dataframe().reset_index()",
  "    if isinstance(obj, xr.DataArray):",
  "        name = obj.name if obj.name is not None else 'value'",
  "        if obj.ndim == 0:",
  "            # one row. A coordinate renders just itself, as its table",
  "            # does; a data variable keeps its scalar coords (what were",
  "            # dims before selecting, e.g. a nearest point's lat/lon)",
  "            # ahead of its value, as to_dataframe would for 0-d",
  "            if name in obj.coords:",
  "                return pd.DataFrame({name: [obj.values[()]]})",
  "            cols = {k: [v.values[()]] for k, v in obj.coords.items()}",
  "            cols[name] = [obj.values[()]]",
  "            return pd.DataFrame(cols)",
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
            col['values'] = codes.astype('int32')
            first = next((u for u in uniques if u is not None), None)
            if (_XRDBI_GEOMETRY == 'wkb' and first is not None
                    and type(first).__module__.startswith('shapely')):
                # geometry (e.g. an xvec cube's geometry coordinate): WKB,
                # one uint8 buffer plus each geometry's length, which R
                # splits into a wk::wkb vector
                import shapely
                blobs = [b'' if u is None else shapely.to_wkb(u) for u in uniques]
                col['kind'] = 'wkb'
                col['levels'] = np.frombuffer(b''.join(blobs), dtype='uint8')
                col['lengths'] = np.array([len(b) for b in blobs], dtype='int64')
            else:
                col['kind'] = 'text'
                col['levels'] = np.array([text(u) for u in uniques], dtype=object)
        out.append(col)
    return out

# geometry renders as WKB (R has wk) or WKT text (set at connect)
_XRDBI_GEOMETRY = 'wkb'

def _xrdbi_geom_crs(obj):
    # the CRS of each geometry coordinate, from its index (xvec's
    # GeometryIndex carries one): an authority code when there is one
    out = {}
    for name, ix in getattr(obj, 'xindexes', {}).items():
        crs = getattr(ix, 'crs', None)
        if crs is None or name not in obj.coords or obj[name].dtype != object:
            continue
        auth = crs.to_authority()
        out[str(name)] = ':'.join(auth) if auth else crs.to_wkt()
    return out
)---"

## plan for building the long form in R (see plan_result): returns
## (meta, flats) or None. It mirrors xarray's Dataset._to_dataframe:
## rows are the C-order product of the dims (a DataArray's own order, a
## Dataset's list(ds.dims)); columns are the dim indexes, then every
## non-index variable in storage order, broadcast to all dims (a
## DataArray goes through to_dataset(name=), as to_dataframe does).
## meta['cols'] kinds: 'dim' (1-D values in 'col', repeated along
## 'axis'), 'scalar' (one value in 'col'), 'flat' (index into flats: a
## C-order 1-D array, sliced per fetch by _xrdbi_slice)
xrdbi_plan_py <- r"---(
def _xrdbi_plan(obj):
    import xarray as xr, numpy as np, pandas as pd
    if isinstance(obj, xr.DataArray):
        name = obj.name if obj.name is not None else 'value'
        if name in obj.dims or name in obj.coords:
            return None
        ds = obj.to_dataset(name=name)
        dims = list(obj.dims)
    elif isinstance(obj, xr.Dataset):
        ds = obj
        dims = list(obj.dims)
    else:
        return None
    sizes = {d: int(ds.sizes[d]) for d in dims}
    if not dims or 0 in sizes.values():
        return None
    # decline what _to_dataframe treats specially: indexes that are not
    # exactly the dim coordinates (MultiIndex levels, custom indexes) and
    # pandas extension arrays
    if set(ds.xindexes) != {d for d in dims if d in ds.variables}:
        return None
    if not all(isinstance(v.dtype, np.dtype) for v in ds.variables.values()):
        return None

    def one(nm, v):
        return _xrdbi_columns(pd.DataFrame({nm: v}))[0]

    cols, flats = [], []
    for i, d in enumerate(dims):
        # a dim without a coordinate gives 0..n-1, as to_dataframe does
        v = ds.indexes[d] if d in ds.xindexes else np.arange(sizes[d])
        cols.append({'name': d, 'kind': 'dim', 'axis': i, 'col': one(d, v)})
    for k, v in ds.variables.items():
        if k in ds.xindexes:
            continue
        if v.ndim == 0:
            cols.append({'name': k, 'kind': 'scalar',
                         'col': one(k, [v.values[()]])})
        elif v.ndim == 1:
            cols.append({'name': k, 'kind': 'dim',
                         'axis': dims.index(v.dims[0]),
                         'col': one(k, v.values)})
        else:
            flats.append(v.set_dims(sizes).values.reshape(-1))
            cols.append({'name': k, 'kind': 'flat', 'flat': len(flats) - 1})
    return ({'shape': [sizes[d] for d in dims], 'cols': cols}, flats)

def _xrdbi_slice(flat, start, stop):
    import pandas as pd
    v = flat[int(start):int(stop)]
    if v.dtype.kind in 'biu' or (v.dtype.kind == 'f' and v.dtype.itemsize >= 4):
        # plain numbers need no pandas round trip
        return {'name': 'x', 'kind': 'plain', 'na': None, 'tz': 'UTC',
                'values': v}
    return _xrdbi_columns(pd.DataFrame({'x': v}))[0]
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


