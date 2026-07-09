# xrdbi 0.0.1.9000 (development)



Initial  DBI backend for xarray: the "database" is a live
Python session (reticulate) holding an xarray object.

## Features

* `dplyr` verbs over any xarray-openable source; dimension filters push down to
oriented label slices, value filters apply before conversion; one inspectable
python statement. `tbl(con, var)` returns a lazy spec; filter/select/head accumulate;
`collect()` compiles ONE python statement and runs it through
`dbGetQuery`. Dimension predicates push down to an inclusive `.sel` hull
(fewer chunks touched); strict bounds and data-variable predicates
remain as a pandas `.query` applied before conversion to R (pushdown
with residuals). At collect, each hull dimension is probed for
direction and the slice oriented to match, so range filters work
identically on ascending and descending coordinates. `show_query()` prints the
compiled python.


* Three connect forms via `dbConnect(xarray(), ...)`: a `dsn` string
  that xarray can open (open function selectable via `open =`, keyword
  arguments passed through), a `builder` function receiving the xarray
  module (for icechunk sessions, virtualizarr, multi-step opens), or an
  existing Python `object` adopted from the session.

* Statements are Python expressions evaluated with `ds` and `xr` in
  scope. `dbSendQuery()` is lazy (builds the selection graph, moves no
  bytes); rendering to the tidy long-form data frame happens at
  `dbFetch()`, paginated Python-side.

* `xr_query()` compiles a structured spec (vars, sel, isel, method,
  tail) to an inspectable Python expression string. `isel` is
  zero-based, faithfully: values are interpolated, not translated.

* Coordinates are tables too: `dbListTables()` lists `ds.variables`
  (data variables and coordinates); the data/coords split remains
  available via `dbGetInfo()`. Dimension coordinates render as a single
  column of their values; scalar coordinates and scalar results as a
  one-row frame; a non-dimension coordinate's self-reference is
  deduplicated.

* All results funnel through a single Python-side renderer installed at
  connect, covering Dataset, DataArray (including 0-d), and plain
  Python values.

* Kind messages on empty results: when a selection collapses a
  dimension to zero, the parent coordinate is inspected and the message
  reports a DESCENDING coordinate (label slices follow coordinate
  order; try slice(hi, lo)) or the coordinate span (catches
  out-of-range values and -180..180 vs 0..360 longitude conventions).

* Whole-variable reads are guarded against accidental terabyte
  renderings (`options(xrdbi.max_cells = )`, or `force = TRUE`).

* Escape hatches: `xr_dataset(con)` and `xr_module(con)` return the
  live Python handles.

* Transactions (`dbBegin`/`dbCommit`/`dbRollback`) error with a pointer
  to the intended mapping onto icechunk sessions and commits.

## Fixes

* Statement scope is built with `py_dict()` and explicit character
  keys; `reticulate::dict()` resolves argument names against calling
  frame variables, which made the local `ds` Dataset a dict key
  (unhashable) (#nn).

* Removed use of a nonexistent `reticulate::py_slice()`; pagination
  uses builtins `slice`.

* 0-d renderings use `values[()]` rather than `.item()`, which returns
  raw integer nanoseconds for ns-precision datetimes.

## Documentation

* Worked examples against real sources: OISST NetCDF over HTTPS
  (h5netcdf), ARCO ERA5 zarr v3 on anonymous GCS (including the
  descending-latitude gotcha, kept in as a lesson), and an OISST daily
  multidim VRT mosaic via the gdalxarray engine (deferred credential
  errors, connection-as-snapshot semantics).

* Guidance on `chunks`: omit for lazy zarr-backed arrays and fast
  connects; `chunks = dict()` wraps variables in dask at native storage
  chunking, which for finely-chunked stores can cost minutes of task
  graph construction (observed: 96s vs 7s on a 1-timestep-per-chunk
  store). Note the differing defaults of `open_dataset` (None) and
  `open_zarr` ("auto").

## Planned

* dbplyr-style laziness via `tbl()` in the dtplyr/duckplyr mould:
  capture dplyr verbs, compile to `xr_query()` specs (filter on dim
  coords to sel/isel, value predicates to where, summarise to
  reductions).

* Alternate renderings as sibling verbs on a result, leaving the
  `dbFetch()` data frame contract intact: `xr_array()` (values plus
  dims and coords, skipping the pandas hop) and `xr_raster()`
  (SpatRaster from a regular-grid slab).

* DataTree groups as schemas, write support (to_zarr / icechunk
  commit), registry integration (`dbConnect(xarray(), dsn(...))`).
