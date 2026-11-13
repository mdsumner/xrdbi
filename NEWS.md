# xrdbi (development version)

## Chunk maps

* New `xr_chunks()` maps the storage chunks a selection touches: one row
  per chunk with, for each dimension, its chunk index, its 0-based
  `start`/`stop` index range (as in `isel(slice(start, stop))`) and its
  coordinate extent (cell edges for numeric axes), then `cells` and how
  many are `selected`, and a `wk::rct()` over the two spatial dimensions
  with the CRS. On a whole variable it is the chunk grid; on a selection,
  the chunks reading it would touch. Shapes come from
  `encoding['preferred_chunks']`, which zarr, netCDF (netCDF4, h5netcdf)
  and gdalxarray (classic blocks and multidimensional) all set; without
  it a dask grid, else one chunk. Only coordinates are read, and a
  `max_chunks` guard covers stores like ERA5 (1.3 million time chunks).

* `xr_chunks(level = "shards")` maps the shards of a sharded zarr v3
  array, each a stored object holding a grid of inner chunks; at the
  default chunk level a sharded array gets a `d_shard` column per
  dimension, the shard each chunk lives in.

* On curvilinear grids `xr_chunks()` gives each chunk the envelope of its
  block of 2-D longitude/latitude (`lon_min` ... `lat_max`, named after the
  coordinates, recognised by CF `standard_name`, units or common names),
  and uses it as `geometry` (OGC:CRS84) when the grid has no 1-D axes.
  Selections on index-only dimensions (`isel(eta_rho=...)`) are placed
  through the 2-D coordinates, whose value pairs are copied exactly.

## Query parameters

* `dbSendQuery()`, `dbGetQuery()` and `xr_raster()` take `params`, a named
  list whose elements become Python variables in the statement's scope
  beside `ds` and `xr`: `dbGetQuery(con, "ds.sst.sel(lat=lat0,
  method='nearest')", params = list(lat0 = -60))`. Length-1 vectors
  become numpy scalars (`I()` keeps an array), longer ones numpy arrays,
  `Date` and `POSIXct` become `datetime64` (UTC, `NA` as `NaT`), data
  frames pandas, and geometry (sf, sfc, wk vectors) shapely, or a
  geopandas `GeoSeries` when it has a CRS, so xvec's `extract_points()`
  and `zonal_stats()` can be driven from R.

* `dbBind()` evaluates a result's statement again with new `params` and
  restarts its fetch.

* An unbound name in a statement now says how to pass it.

## CRAN preparation

* Loading xrdbi now declares only its core Python requirements, xarray
  and netCDF4 (local netCDF-3 and netCDF-4). It declared gdalxarray too,
  which pip can install but not make work (it needs the GDAL Python
  bindings), so a provisioned environment carried it, its dependencies
  and an xarray warning for nothing. Other engines are declared where
  used, e.g. `reticulate::py_require(c("zarr", "gcsfs"))`, before or
  after connecting; `?xrdbi` lists the common ones, and each README
  example declares what it needs. A new user, with no Python
  configured, can run the README's OISST and ERA5 examples as written.

* Tests that need Python skip on CRAN. Checking for the Python modules
  is itself what starts reticulate, which with no Python configured
  provisions an environment from PyPI into the user cache. The tests
  that need no Python (statement compilation, row windows, head blocks)
  still run there.

* Every DBI method is documented: connection methods on
  `?XarrayConnection-class`, result methods (with `dbSendQuery()`) on
  `?XarrayResult-class`, driver methods on `?xarray`. Every exported
  function documents its return value and has examples; those needing
  Python are in `\dontrun{}`.

* DESCRIPTION declares the Python requirement in `SystemRequirements`,
  links xarray, credits the GDAL/OGR contributors for the vendored test
  fixtures (see `inst/COPYRIGHTS`), and requires reticulate >= 1.41.0,
  the first release with `py_require()` (which `.onLoad()` calls).

## README

* The README gains a live chunk-map section: the 1024 x 1024 block grid
  of a Sentinel-2 Cloud-Optimized GeoTIFF, and a window's touched blocks
  shaded by how much of each it reads (figure in `man/figures/`).

* The README is now `README.Rmd`, built live with
  `devtools::build_readme()` against the remote examples (OISST over HTTPS,
  ARCO ERA5 on GCS, the OISST multidim VRT via gdalxarray), and it gains a
  dplyr section.

## Fixes

* `xr_raster()` finds the CRS that gdalxarray records in an xproj
  `CRSIndex` (its `crs` coordinate has no attributes), or that a rasterix
  `RasterIndex` carries; `srs` was empty for gdalxarray rasters.

* A 0-d data variable renders with its scalar coordinates ahead of its
  value, as `to_dataframe()` would: a single cell, or a nearest-point
  lookup, keeps where it is (`time`, `lat`, `lon`, ...) instead of only
  the value. A 0-d coordinate still renders just itself.

* `xr_raster()` accepts regular grids stored as float32. Their rounding
  (about 1.2e-7 of each value) made the steps of e.g. a 0.44 degree
  rotated-pole grid vary by 1e-5 of the step, failing a fixed 1e-6
  tolerance; the tolerance now scales with the coordinate's precision,
  and the step is the mean over the axis.

* The cell guard never fired above 2^31 cells, so it missed exactly the
  reads it exists to stop. reticulate converts a Python int that large
  into a wrapped R integer (2^31 became `NA`, 17 billion became
  -179,869,184), so `dbReadTable(con, "sst")` on the full OISST record
  started rendering 17 billion cells instead of erroring. Sizes now cross
  as doubles, in `dbFetch()`, `dbReadTable()` and `collect()`, and guard
  messages print counts in full.

* Printing a connection cuts the variable list to the console width,
  with a total (ERA5 has 273 data variables).

* `show_query()` backticks non-syntactic names in the R steps line, so it
  is valid R.

## Faster, type-faithful conversion to R

* `dbFetch()`, `dbGetQuery()`, `dbReadTable()` and `collect()` now convert the
  rendered pandas frame column by column from numpy buffers instead of with
  reticulate's whole-DataFrame conversion. A 10M-row fetch with a time
  dimension drops from ~22 s to ~1.2 s; nearly all the old cost was
  reticulate's handling of a datetime column.

* Types that were wrong before now convert properly: NaT is `NA` (it was
  1677-09-21 in a numpy route), timedeltas are `difftime` seconds (they were
  `NA` dates), pandas string columns such as string coordinates are character
  (they were left as Python objects), categoricals are factors (they made the
  fetch error), cftime values from non-standard calendars are ISO strings
  (they were a list of Python objects), bytes are decoded, and nullable
  integers and booleans keep `NA`.

* For a plain DataArray (the usual `ds.var.sel(...)` statement, and `tbl()`
  pipelines whose filters all push down to `.sel()`), the long form is now
  built in R: only the values, flattened in C order, cross from Python, and
  the coordinate columns are repeated with `rep()`. The 10M-row fetch drops
  again to ~0.55 s, and `dbFetch(n = )` builds only the rows asked for
  (10 chunks of 1M rows: ~0.4 s in total). The output is identical to the
  pandas render. Datasets, 0-d and empty results, MultiIndex coordinates
  and pandas-stage statements still go through the pandas render.

* `head()` and `select()` in `tbl()` pipelines no longer force a pandas
  stage unless a filter on data values needs one. They apply in R to the
  fetched rows, and `head(n)` first narrows the selection to the leading
  block holding its first `n` rows. `head(10)` on a lazy 207M-cell
  variable collects in 0.07 s and reads one chunk; before, it tripped the
  cell guard, and with `force` it rendered the whole selection in pandas.
  `show_query()` and the printed tbl list the R steps.

* `collect(force = TRUE)` works again for pipelines that compile to a plain
  xarray selection. `collect()` honoured `force`, but `dbFetch()` checked
  the guard again without it. The collect guard now counts the cells
  actually read (strict trims and the `head()` block included).

* Datasets now take the R-built path too, mirroring xarray's
  `to_dataframe()`: rows are every combination of the Dataset's dims, and
  each non-index variable is broadcast across them, whether or not the
  variables share dims. 10M rows x 2 variables: 0.78 s instead of 1.71 s,
  identical output. Stacked (MultiIndex) dims, other non-dim indexes and
  pandas extension arrays still use the pandas render.

* The cell guard now applies to Datasets. A Dataset has no `.size`, so
  the guard silently never fired: `dbGetQuery(con, "ds")` on a large store
  would try to load all of it. It now counts rows x data variables.

* A 0-d Dataset (every dim selected to one value) renders as one row; it
  errored in `to_dataframe()`.

* `tbl()` filters on non-dimension coordinates (2-D `lat`/`lon` of a
  curvilinear grid, a 1-D coordinate along `time`) narrow the read to the
  index block holding every cell that passes, computed from the
  coordinates at collect time; the pandas query still applies them
  exactly inside the block. On a 40 x 60 grid a lat/lon box reads 507 of
  7,200 cells. The collect guard counts the narrowed read, and the
  preview's note no longer blames value filters for coordinate filters.

* Strict bounds on a dimension in `tbl()` filters (`lat > 18`,
  `time < as.Date(...)`) no longer drop to a pandas `.query()`. The
  inclusive `.sel()` hull is trimmed with a boolean `.isel()` on the
  dimension's index, which uses the same pandas comparison as the query, so
  date strings keep their meaning. The statement stays a DataArray and takes
  the R-built path: 4.8M rows collect in 0.43 s instead of 1.16 s, with
  identical output. Filters on data variables, `select()` and `head()` still
  use the pandas stage.

* Datetimes without a zone now carry `tzone = "UTC"`, so they display as the
  instant the source means regardless of the session zone. Timezone-aware
  datetimes keep their zone.

* The GDAL autotest fixture tests had been skipping because of a stale
  helper call; they run again.

## xr_raster(): raster rendering of a result

* Printing a `tbl` now renders a lazy preview - sizes from metadata, the first cells
clamped to at most one chunk read, tibble-formatted, with
`options(xrdbi.print_preview = FALSE)` to opt out; and the compiled pandas stage
routes through the connection's renderer (`.pipe(_xrdbi_render`), visible in
`show_query()`), so coordinate tables, 0-d results, and empty selections behave
identically in tbl pipelines and raw statements.

* New `xr_raster()` renders a slab in gdalraster's in-memory raster
  format: a plain vector of pixel values (left-to-right, top-to-bottom,
  band-sequential; `as_list = TRUE` for a list of band vectors) with a
  `gis` attribute carrying `type`, `bbox`, `dim`, `srs`, and
  `datatype` -- interchangeable with the output of
  `gdalraster::read_ds()`, and compatible with `ximage::ximage()`. 

* Where `dbFetch()` renders the tidy long-form data frame, this is a
  sibling rendering on the same lazy result: `xr_raster(res)` on an
  XarrayResult, or `xr_raster(con, statement)`. The DBI contract is
  untouched. The array is a rendering format; so is the data frame; so
  is this.

* Shapes: 2-D (y, x) single band, or 3-D (band, y, x) band-sequential
  stack (a time series of slabs; dim order preserved, so band b is
  unambiguously e.g. time[b]). 4-D and higher refuse with an error
  carrying the explicit flatten recipe (e.g.
  `.stack(band=('zlev','time')).transpose('band','lat','lon')`),
  because the gis format has no band-names field and silent flattening
  would invent an ordering the object cannot record. y and x are
  positionally the last two dims (CF/xarray convention). Dimension
  coordinates must be regular ("warp first" otherwise); the half-cell
  bbox expansion assumes cell centres; ascending or descending order
  on either axis is handled. The `xrdbi.max_cells` guard applies.

## CRS: lifted

* `gis$srs` is populated by a verbatim lift, in order of specificity:
  a `spatial_ref`/`crs` coordinate on the object ; the variable's CF `grid_mapping` pointer followed into
  the parent dataset (grid-mapping variables are 0-d data variables
  and do not propagate through selection); or conventional names at
  the dataset level (catching statements that strip attrs, e.g.
  arithmetic). Only an authored `crs_wkt`/`spatial_ref` WKT string is
  ever read; CF projection-parameter interpretation is deliberately
  out of scope. 

## Self-contained test fixtures

* A curated set of GDAL autotest files (four netCDFs exercising CF
  packing, descending latitude, and grid mappings, plus the canonical
  byte.tif and 3-band rgbsmall.tif) is vendored flat into
  `inst/extdata/autotest/` (~100 KB) with a PROVENANCE file recording
  source paths, commit, and the MIT/X license.
  `tools/update-fixtures.R` re-vendors from a checkout; the
  GDAL_AUTOTEST environment variable is now only needed when updating
  fixtures, never for testing.


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
