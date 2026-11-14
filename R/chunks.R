#' Map the chunks a selection touches
#'
#' The block structure of a stored variable as a table: one row per
#' storage chunk that the selection touches, with each chunk's index
#' range and coordinate extent along every dimension, and a rectangle
#' over the last two dimensions (y and x, as for [xr_raster()]). Run it
#' on the whole variable (`"ds.sst"`) to see its chunk grid, or on a
#' selection (`"ds.sst.sel(lat=slice(-60, -50))"`) to see which chunks
#' reading it
#' would touch.
#'
#' Chunk shapes come from the variable's `encoding["preferred_chunks"]`,
#' which xarray's backends (zarr, netCDF via netCDF4 or h5netcdf, GDAL
#' via gdalxarray, classic and multidimensional) set from the storage
#' layout. Without it, a dask-backed selection maps its own dask chunks;
#' otherwise the variable is one chunk. The selection is placed on the
#' source grid by its coordinate values, so it must be an orthogonal
#' selection of one stored variable (`sel()`/`isel()` by labels,
#' slices, or lists); pointwise selections onto a new dimension are not
#' supported. Nothing but coordinates is read.
#'
#' @param x an XarrayResult, or an XarrayConnection (with `statement`)
#' @param statement a Python expression selecting one stored variable,
#'   when `x` is a connection
#' @param params named list of values the statement refers to, when `x`
#'   is a connection (see [XarrayResult-class])
#' @param level `"chunks"` (the default) maps storage chunks; `"shards"`
#'   maps the shards of a sharded zarr v3 array, each a stored object
#'   holding a grid of inner chunks. At the chunk level a sharded array
#'   also gets a `d_shard` column per dimension, the shard each chunk
#'   lives in.
#' @param max_chunks guard on the number of rows, default
#'   `getOption("xrdbi.max_chunks", 1e6)`
#' @param force bypass the guard
#' @return a data frame, one row per chunk touched, chunks in C order
#'   (the last dimension fastest). For each dimension `d`: `d_chunk`, the
#'   chunk's index along `d`; `d_start` and `d_stop`, its 0-based index
#'   range, stop exclusive (as in `isel(d=slice(start, stop))`); and,
#'   when `d` has a coordinate, `d_min` and `d_max`, its extent: cell
#'   edges for a numeric coordinate, the first and last values
#'   otherwise. Then `cells`, the chunk's size in cells, and `selected`,
#'   how many of them the selection reads. When the last two dimensions
#'   have numeric coordinates and the wk package is installed,
#'   `geometry` is a [wk::rct()] over them, with the CRS when one is
#'   recorded (as for [xr_raster()]). On a curvilinear grid, where 2-D
#'   longitude/latitude coordinates (recognised by CF `standard_name`,
#'   units, or common names) span the last two dimensions, each chunk
#'   also gets the envelope of its block of those values (`lon_min`,
#'   `lon_max`, `lat_min`, `lat_max`, named after the coordinates; cell
#'   centres, so half a cell inside the edges, and not split at the
#'   antimeridian), and `geometry` is that envelope in OGC:CRS84 when
#'   the dimensions have no 1-D coordinates of their own. Attribute
#'   `chunking` says where
#'   the shapes came from: `"storage"`, `"shards"`, `"dask"` or `"none"`.
#' @seealso [xr_raster()] to read the cells; [XarrayResult-class] for
#'   statements and `params`; [xrdbi-package] for an overview.
#' @examples
#' \dontrun{
#' ## needs a Python environment with xarray (and here zarr, gcsfs)
#' con <- dbConnect(xarray(),
#'   "gs://gcp-public-data-arco-era5/ar/full_37-1h-0p25deg-chunk-1.zarr-v3",
#'   engine = "zarr", storage_options = reticulate::dict(token = "anon"))
#' ## one chunk per hour: a month of one variable reads 744 chunks
#' ch <- xr_chunks(con,
#'   "ds['2m_temperature'].sel(time=slice('1980-01-01', '1980-01-31'))")
#' nrow(ch)
#'
#' ## a GeoTIFF's block grid (gdalxarray needs the GDAL Python bindings;
#' ## multidim = FALSE opens it as a classic raster: one variable,
#' ## band_data, over (band, y, x))
#' tif <- system.file("extdata/autotest/rgbsmall.tif", package = "xrdbi")
#' con <- dbConnect(xarray(), tif, engine = "gdalxarray", multidim = FALSE)
#' ch <- xr_chunks(con, "ds.band_data")
#' ch[, c("band_chunk", "y_start", "y_stop", "x_start", "x_stop", "cells")]
#' plot(ch$geometry)
#' }
#' @export
xr_chunks <- function(x, statement = NULL, params = NULL,
                      level = c("chunks", "shards"),
                      max_chunks = getOption("xrdbi.max_chunks", 1e6),
                      force = FALSE) {
  level <- match.arg(level)
  if (inherits(x, "XarrayConnection")) {
    stopifnot(is.character(statement), length(statement) == 1L)
    res <- dbSendQuery(x, statement, params = params)
    on.exit(dbClearResult(res), add = TRUE)
  } else if (inherits(x, "XarrayResult")) {
    res <- x
  } else {
    stop("x must be an XarrayResult or XarrayConnection", call. = FALSE)
  }
  con <- res@ptr$conn
  ds <- conn_ds(con)
  m <- py_to_r(con@ptr$chunks(res@ptr$obj, ds, level))
  dims <- m$dims
  counts <- vapply(dims, function(d) length(d$ids), 1)
  n <- prod(counts)
  if (!isTRUE(force) && is.finite(max_chunks) && n > max_chunks) {
    stop(sprintf(paste0(
      "the selection touches %s chunks, above the guard (%s); select ",
      "less, raise options(xrdbi.max_chunks=), or use force = TRUE"),
      fmt_count(n), fmt_count(max_chunks)), call. = FALSE)
  }

  ## C order over the touched chunks, as the long form orders cells
  cols <- list()
  sel <- rep(1, n)
  cells <- rep(1, n)
  at <- vector("list", length(dims))
  for (i in seq_along(dims)) {
    d <- dims[[i]]
    idx <- rep(rep(seq_len(counts[i]), each = prod(counts[-seq_len(i)])),
               times = prod(counts[seq_len(i - 1L)]))
    at[[i]] <- idx
    nm <- d$name
    start <- as.numeric(d$start)
    stop_ <- as.numeric(d$stop)
    cols[[paste0(nm, "_chunk")]] <- as.numeric(d$ids)[idx]
    if (!is.null(d$shard)) {
      cols[[paste0(nm, "_shard")]] <- as.numeric(d$shard)[idx]
    }
    cols[[paste0(nm, "_start")]] <- start[idx]
    cols[[paste0(nm, "_stop")]] <- stop_[idx]
    if (!is.null(d$min)) {
      cols[[paste0(nm, "_min")]] <- column_to_r(d$min)[idx]
      cols[[paste0(nm, "_max")]] <- column_to_r(d$max)[idx]
    }
    cells <- cells * (stop_ - start)[idx]
    sel <- sel * as.numeric(d$selected)[idx]
  }
  cols$cells <- cells
  cols$selected <- sel

  ## a rectangle over the last two dims, (y, x) as for xr_raster()
  nd <- length(dims)
  if (nd >= 2L && isTRUE(dims[[nd]]$numeric) && isTRUE(dims[[nd - 1L]]$numeric) &&
      requireNamespace("wk", quietly = TRUE)) {
    yn <- dims[[nd - 1L]]$name
    xn <- dims[[nd]]$name
    src <- py_get_item(ds, m$var)
    bt <- import_builtins(convert = FALSE)
    wkt <- lift_srs(src, as.character(py_to_r(bt$list(src$coords))), ds)
    cols$geometry <- wk::rct(cols[[paste0(xn, "_min")]], cols[[paste0(yn, "_min")]],
                             cols[[paste0(xn, "_max")]], cols[[paste0(yn, "_max")]],
                             crs = if (nzchar(wkt)) wkt else NULL)
  }
  ## curvilinear: the envelope of each chunk's block of 2-D lon/lat
  env <- m$envelope
  if (!is.null(env)) {
    rc <- cbind(at[[nd - 1L]], at[[nd]])
    pick <- function(v) as.matrix(v)[rc]
    cols[[paste0(env$x, "_min")]] <- pick(env$xmin)
    cols[[paste0(env$x, "_max")]] <- pick(env$xmax)
    cols[[paste0(env$y, "_min")]] <- pick(env$ymin)
    cols[[paste0(env$y, "_max")]] <- pick(env$ymax)
    if (is.null(cols$geometry) && requireNamespace("wk", quietly = TRUE)) {
      cols$geometry <- wk::rct(cols[[paste0(env$x, "_min")]],
                               cols[[paste0(env$y, "_min")]],
                               cols[[paste0(env$x, "_max")]],
                               cols[[paste0(env$y, "_max")]], crs = "OGC:CRS84")
    }
  }
  out <- list2DF(cols, nrow = n)
  attr(out, "chunking") <- m$source
  out
}

## the chunk grid of a stored variable and where a selection falls on it
xrdbi_chunks_py <- r"---(
def _xrdbi_chunks(obj, ds, level='chunks'):
    import numpy as np, pandas as pd, xarray as xr
    if (not isinstance(obj, xr.DataArray) or obj.name is None
            or obj.name not in ds.variables):
        raise ValueError(
            'a chunk map needs a selection of one stored variable, '
            'e.g. ds.sst or ds.sst.isel(time=0)')
    src = ds[obj.name]
    extra = [d for d in obj.dims if d not in src.dims]
    if extra:
        raise ValueError(
            'pointwise selections onto a new dimension (%s) have no chunk map; '
            'select with slices or lists along existing dimensions' % ', '.join(extra))
    # zarr v3 sharding: each stored object (shard) holds a grid of inner
    # chunks; preferred_chunks is the inner chunk, encoding['shards'] the
    # shard, one size per dim in the variable's dim order
    shards = src.encoding.get('shards')
    shards = dict(zip(src.dims, (int(s) for s in shards))) if shards else {}
    if level == 'shards':
        if not shards:
            raise ValueError("'%s' is not stored in shards; use level = 'chunks'"
                             % obj.name)
        pc = shards
    else:
        pc = src.encoding.get('preferred_chunks') or {}
    if level == 'shards':
        source = 'shards'
    elif pc:
        source = 'storage'
    elif obj.chunks is not None:
        source = 'dask'
    else:
        source = 'none'

    def one(v):
        return _xrdbi_columns(pd.DataFrame({'x': v}))[0]

    def index_of(da, d):
        # a pandas index, or one built from the coordinate values when the
        # index is a custom one (e.g. rasterix's RasterIndex, computed
        # from an affine transform)
        try:
            return da.indexes[d]
        except Exception:
            return pd.Index(np.asarray(da[d].values))

    def locate(idx, values):
        pos = np.asarray(idx.get_indexer(values))
        if (pos < 0).any() and (idx.is_monotonic_increasing or idx.is_monotonic_decreasing):
            # computed coordinates can round differently between the full
            # grid and a subset: accept a match within a millionth of a step
            if len(idx) > 1 and np.asarray(idx).dtype.kind in 'iuf':
                tol = 1e-6 * float(np.min(np.abs(np.diff(np.asarray(idx, dtype='float64')))))
                pos = np.asarray(idx.get_indexer(values, method='nearest', tolerance=tol))
        return pos

    def place_2d(ydim, xdim):
        # dims without 1-D coordinates (typical of curvilinear grids) can
        # still be placed: 2-D coordinates are copied exactly into a
        # selection, so its first column and row are found in the source
        # by their (a, b) value pairs, when those pairs are unique
        cands = [k for k, c in src.coords.items()
                 if c.ndim == 2 and set(c.dims) == {ydim, xdim} and c.dtype.kind in 'iuf'
                 and k in obj.coords and obj[k].ndim == 2]
        if len(cands) < 2:
            return {}
        a, b = cands[0], cands[1]
        sa = np.asarray(src[a].transpose(ydim, xdim).values)
        sb = np.asarray(src[b].transpose(ydim, xdim).values)
        mi = pd.MultiIndex.from_arrays([sa.ravel(), sb.ravel()])
        if not mi.is_unique:
            return {}
        oa = np.asarray(obj[a].transpose(ydim, xdim).values)
        ob = np.asarray(obj[b].transpose(ydim, xdim).values)
        rows = mi.get_indexer(pd.MultiIndex.from_arrays([oa[:, 0], ob[:, 0]]))
        cols = mi.get_indexer(pd.MultiIndex.from_arrays([oa[0, :], ob[0, :]]))
        if (rows < 0).any() or (cols < 0).any():
            return {}
        nx = sa.shape[1]
        return {ydim: rows // nx, xdim: cols % nx}

    placed = {}
    if source in ('storage', 'shards') and len(src.dims) >= 2:
        ydim, xdim = src.dims[-2], src.dims[-1]
        if (ydim in obj.dims and xdim in obj.dims
                and not (ydim in src.xindexes and xdim in src.xindexes)):
            placed = place_2d(ydim, xdim)

    dims = []
    starts = {}
    for d in src.dims:
        n = int(src.sizes[d])
        has_index = d in src.xindexes or (d in src.coords and src[d].ndim == 1)
        # where the selection sits along d, as source positions
        if source == 'dask':
            # the dask grid belongs to the selection itself
            sizes = obj.chunksizes.get(d, (int(obj.sizes[d]),)) if d in obj.dims else (1,)
            bounds = np.concatenate([[0], np.cumsum(sizes)])
            pos = np.arange(int(obj.sizes[d])) if d in obj.dims else np.array([0])
            coord = obj[d] if d in obj.coords and d in obj.dims else None
        else:
            c = int(pc.get(d, n)) if source in ('storage', 'shards') else n
            bounds = np.append(np.arange(0, n, c), n)
            coord = src[d] if has_index else None
            if d in obj.dims:
                if has_index and d in obj.coords:
                    pos = locate(index_of(src, d), index_of(obj, d))
                    if (pos < 0).any():
                        raise ValueError("'%s' values of the selection are not all in "
                                         "the stored coordinate" % d)
                elif int(obj.sizes[d]) == n:
                    pos = np.arange(n)
                elif d in placed:
                    pos = np.asarray(placed[d])
                else:
                    raise ValueError("'%s' has no coordinate and was subset; its chunks "
                                     "cannot be placed" % d)
            elif has_index and d in obj.coords:
                pos = locate(index_of(src, d), [obj.coords[d].values[()]])
                if (pos < 0).any():
                    raise ValueError("'%s' value of the selection is not in the stored "
                                     "coordinate" % d)
            else:
                raise ValueError("'%s' was selected away without a coordinate; its "
                                 "chunk cannot be placed" % d)
        ids_all = np.searchsorted(bounds, pos, side='right') - 1
        ids, counts = np.unique(ids_all, return_counts=True)
        start, stop = bounds[ids], bounds[ids + 1]
        entry = {'name': d, 'ids': ids.astype('int64'), 'start': start.astype('int64'),
                 'stop': stop.astype('int64'), 'selected': counts.astype('int64'),
                 'min': None, 'max': None, 'numeric': False, 'shard': None}
        if level == 'chunks' and shards and source == 'storage':
            # the shard each inner chunk lives in
            entry['shard'] = (start // shards.get(d, n)).astype('int64')
        if coord is not None and coord.ndim == 1:
            v = np.asarray(coord.values)
            if v.dtype.kind in 'iuf' and len(v) > 0:
                v = v.astype('float64')
                if len(v) > 1:
                    mid = (v[1:] + v[:-1]) / 2
                    edges = np.concatenate([[2 * v[0] - mid[0]], mid, [2 * v[-1] - mid[-1]]])
                else:
                    edges = np.array([v[0] - 0.5, v[0] + 0.5])
                lo, hi = edges[start], edges[stop]
                entry['min'] = one(np.minimum(lo, hi))
                entry['max'] = one(np.maximum(lo, hi))
                entry['numeric'] = True
            else:
                entry['min'] = one(v[start])
                entry['max'] = one(v[stop - 1])
        dims.append(entry)
        starts[d] = bounds[:-1]
    out = {'var': str(obj.name), 'source': source, 'dims': dims, 'envelope': None}

    # curvilinear: 2-D longitude/latitude over the last two dims give each
    # chunk the envelope of its block of coordinate values
    if len(dims) >= 2:
        ydim, xdim = dims[-2]['name'], dims[-1]['name']
        ll = {}
        for k, c in src.coords.items():
            if c.ndim != 2 or set(c.dims) != {ydim, xdim} or c.dtype.kind not in 'iuf':
                continue
            sn = str(c.attrs.get('standard_name', '')).lower()
            un = str(c.attrs.get('units', '')).lower()
            nm = str(k).lower()
            if (sn == 'longitude' or un in ('degrees_east', 'degree_east', 'degrees_e')
                    or nm in ('lon', 'longitude', 'nav_lon', 'lon_rho', 'xlong', 'glamt')):
                ll.setdefault('x', k)
            elif (sn == 'latitude' or un in ('degrees_north', 'degree_north', 'degrees_n')
                    or nm in ('lat', 'latitude', 'nav_lat', 'lat_rho', 'xlat', 'gphit')):
                ll.setdefault('y', k)
        if 'x' in ll and 'y' in ll:
            iy = dims[-2]['ids']
            ix = dims[-1]['ids']
            env = {'x': str(ll['x']), 'y': str(ll['y'])}
            for axis in ('x', 'y'):
                a = np.asarray(src[ll[axis]].transpose(ydim, xdim).values, dtype='float64')
                lo = np.where(np.isnan(a), np.inf, a)
                hi = np.where(np.isnan(a), -np.inf, a)
                lo = np.minimum.reduceat(np.minimum.reduceat(lo, starts[ydim], axis=0),
                                         starts[xdim], axis=1)
                hi = np.maximum.reduceat(np.maximum.reduceat(hi, starts[ydim], axis=0),
                                         starts[xdim], axis=1)
                env[axis + 'min'] = lo[np.ix_(iy, ix)]
                env[axis + 'max'] = hi[np.ix_(iy, ix)]
            out['envelope'] = env
    return out
)---"
