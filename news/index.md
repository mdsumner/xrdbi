# Changelog

## xrdbi (development version)

### Documentation

- Reference pages corrected in a documentation sweep: examples now use
  the vendored fixtures (`trmm.nc`, `rgbsmall.tif`) so they run as
  pasted, and no longer select an exact date that misses 12:00 times,
  use xvec without importing it, pass `chunks = list()` (a Python list)
  or open zarr on the dask path. Statements that compute
  (e.g. `.mean()`) are documented as running at
  [`dbSendQuery()`](https://dbi.r-dbi.org/reference/dbSendQuery.html),
  before the guard, which sizes only the result.
  [`?tbl_xarray`](https://mdsumner.github.io/xrdbi/reference/tbl_xarray.md)
  lists the supported verbs and filter forms, the guard and `force`, and
  the preview options;
  [`?xr_raster`](https://mdsumner.github.io/xrdbi/reference/xr_raster.md)
  says y and x are the last two dimensions and how `srs` is found;
  [`?xr_query`](https://mdsumner.github.io/xrdbi/reference/xr_query.md)
  says character vectors are labels, not ranges.

- [`?xrdbi`](https://mdsumner.github.io/xrdbi/reference/xrdbi-package.md)
  is now the package’s overview page: how xarray maps to DBI (tables,
  fields, statements, the long form), the functions by task, the guards
  and the four options (`xrdbi.max_cells`, `xrdbi.max_chunks`,
  `xrdbi.print_n` and `xrdbi.print_preview`, the last two previously
  undocumented), which R packages are used when installed, and the
  Python requirements. Every reference page links onward with a See also
  section, and
  [`?dbConnect`](https://dbi.r-dbi.org/reference/dbConnect.html) says
  what `multidim = FALSE` does for the gdalxarray engine.

- A pkgdown site (<https://mdsumner.github.io/xrdbi/>), built by a
  GitHub Action in the `ghcr.io/hypertidy/gdal-r-python` image so live
  articles can reach GDAL and public cloud data. The reference index is
  grouped by task.

- New “Get started” vignette, pre-computed: its outputs are knitted
  locally from `vignettes/xrdbi.Rmd.orig` on the bundled `trmm.nc`
  (`tools/precompute.R`), so it builds on CRAN without Python. New
  “Python environments” article: letting reticulate manage Python, your
  own Python, conda and pixi (and what reticulate needs there), the
  gdal-r-python image, and how to check what you have. The deploy step
  installs rsync, which the image lacks and the deploy action needs. The
  site’s R dependencies install with pak’s system requirements off and
  without upgrading the image’s packages: apt’s GDAL and GEOS beside the
  image’s own gave shapely the wrong `libgeos_c.so.1`, and a smoke step
  now loads sf and shapely together before the build. The build turns
  off dask’s array query planning, which the image turns on and under
  which `open_mfdataset()` fails; “Python environments” says how.

- Eight more articles, built live on the site: “Querying with dplyr”
  (how each verb compiles and what gets read), “Parameters”, “From
  arrays to rows” (the shape and types of results, and when work
  happens), “Data sources” (a cookbook: netCDF over HTTPS, many files,
  zarr on Google Cloud and S3, GDAL rasters and VRTs, virtual stores),
  “Rasters”, “Chunk maps”, “Curvilinear grids and vector cubes”, and
  “Design notes”. The articles index groups them, and Get started and
  [`?xrdbi`](https://mdsumner.github.io/xrdbi/reference/xrdbi-package.md)
  link to them.

- The README is now a landing page: what xrdbi is, installation, one
  live example on ERA5 (a value, a dplyr filter, the guard, and a global
  hour rendered with
  [`xr_raster()`](https://mdsumner.github.io/xrdbi/reference/xr_raster.md)),
  and links to the articles. Its tutorial sections moved to the
  articles. `tools/build-readme.sh` knits it live in the gdal-r-python
  image. “Data sources” now opens a real icechunk repository (BRAN daily
  salinity on Source Cooperative, a virtual store over NCI THREDDS) in
  place of placeholder names, replacing the README’s icechunk example,
  whose repository no longer exists.

### Chunk maps

- New
  [`xr_chunks()`](https://mdsumner.github.io/xrdbi/reference/xr_chunks.md)
  maps the storage chunks a selection touches: one row per chunk with,
  for each dimension, its chunk index, its 0-based `start`/`stop` index
  range (as in `isel(slice(start, stop))`) and its coordinate extent
  (cell edges for numeric axes), then `cells` and how many are
  `selected`, and a
  [`wk::rct()`](https://paleolimbot.github.io/wk/reference/rct.html)
  over the two spatial dimensions with the CRS. On a whole variable it
  is the chunk grid; on a selection, the chunks reading it would touch.
  Shapes come from `encoding['preferred_chunks']`, which zarr, netCDF
  (netCDF4, h5netcdf) and gdalxarray (classic blocks and
  multidimensional) all set; without it a dask grid, else one chunk.
  Only coordinates are read, and a `max_chunks` guard covers stores like
  ERA5 (1.3 million time chunks).

- `xr_chunks(level = "shards")` maps the shards of a sharded zarr v3
  array, each a stored object holding a grid of inner chunks; at the
  default chunk level a sharded array gets a `d_shard` column per
  dimension, the shard each chunk lives in.

- On curvilinear grids
  [`xr_chunks()`](https://mdsumner.github.io/xrdbi/reference/xr_chunks.md)
  gives each chunk the envelope of its block of 2-D longitude/latitude
  (`lon_min` … `lat_max`, named after the coordinates, recognised by CF
  `standard_name`, units or common names), and uses it as `geometry`
  (OGC:CRS84) when the grid has no 1-D axes. Selections on index-only
  dimensions (`isel(eta_rho=...)`) are placed through the 2-D
  coordinates, whose value pairs are copied exactly.

### Vector data cubes

- Geometry (the geometry coordinate of an xvec vector data cube, or any
  column of shapely objects) arrives as
  [`wk::wkb`](https://paleolimbot.github.io/wk/reference/wkb.html)
  instead of WKT text, carrying the CRS of xvec’s `GeometryIndex`, so it
  goes straight into sf
  ([`sf::st_as_sfc()`](https://r-spatial.github.io/sf/reference/st_as_sfc.html)).
  Each distinct geometry crosses once, as one byte buffer. Without the
  wk package it is WKT text, as before.

- [`xr_raster()`](https://mdsumner.github.io/xrdbi/reference/xr_raster.md)
  refuses a vector data cube with a reason (its geometry dimension has
  no raster rendering; use
  [`dbGetQuery()`](https://dbi.r-dbi.org/reference/dbGetQuery.html)),
  and any non-numeric y or x axis likewise; both failed with “‘list’
  object cannot be coerced to type ‘double’”.

### Query parameters

- [`dbSendQuery()`](https://dbi.r-dbi.org/reference/dbSendQuery.html),
  [`dbGetQuery()`](https://dbi.r-dbi.org/reference/dbGetQuery.html) and
  [`xr_raster()`](https://mdsumner.github.io/xrdbi/reference/xr_raster.md)
  take `params`, a named list whose elements become Python variables in
  the statement’s scope beside `ds` and `xr`:
  `dbGetQuery(con, "ds.sst.sel(lat=lat0, method='nearest')", params = list(lat0 = -60))`.
  Length-1 vectors become numpy scalars
  ([`I()`](https://rdrr.io/r/base/AsIs.html) keeps an array), longer
  ones numpy arrays, `Date` and `POSIXct` become `datetime64` (UTC, `NA`
  as `NaT`), data frames pandas, and geometry (sf, sfc, wk vectors)
  shapely, or a geopandas `GeoSeries` when it has a CRS, so xvec’s
  `extract_points()` and `zonal_stats()` can be driven from R.

- [`dbBind()`](https://dbi.r-dbi.org/reference/dbBind.html) evaluates a
  result’s statement again with new `params` and restarts its fetch.

- An unbound name in a statement now says how to pass it.

### CRAN preparation

- A draft conda-forge recipe lives in `tools/conda/` (not part of the R
  package), validated with rattler-build in a clean sandbox. Its
  activation script points reticulate at the environment’s Python, which
  reticulate otherwise ignores in favour of provisioning from PyPI
  (where gdalxarray cannot work); it also needs `libpython`, which
  conda-forge ships separately, and `micromamba`, without which
  reticulate cannot use a conda-layout environment where no conda binary
  is found (pixi, build sandboxes).

- Loading xrdbi now declares only its core Python requirements, xarray
  and netCDF4 (local netCDF-3 and netCDF-4). It declared gdalxarray too,
  which pip can install but not make work (it needs the GDAL Python
  bindings), so a provisioned environment carried it, its dependencies
  and an xarray warning for nothing. Other engines are declared where
  used, e.g. `reticulate::py_require(c("zarr", "gcsfs"))`, before or
  after connecting;
  [`?xrdbi`](https://mdsumner.github.io/xrdbi/reference/xrdbi-package.md)
  lists the common ones, and each README example declares what it needs.
  A new user, with no Python configured, can run the README’s OISST and
  ERA5 examples as written.

- Tests that need Python skip on CRAN. Checking for the Python modules
  is itself what starts reticulate, which with no Python configured
  provisions an environment from PyPI into the user cache. The tests
  that need no Python (statement compilation, row windows, head blocks)
  still run there.

- Every DBI method is documented: connection methods on
  `?XarrayConnection-class`, result methods (with
  [`dbSendQuery()`](https://dbi.r-dbi.org/reference/dbSendQuery.html))
  on `?XarrayResult-class`, driver methods on
  [`?xarray`](https://mdsumner.github.io/xrdbi/reference/xarray.md).
  Every exported function documents its return value and has examples;
  those needing Python are in `\dontrun{}`.

- DESCRIPTION declares the Python requirement in `SystemRequirements`,
  links xarray, credits the GDAL/OGR contributors for the vendored test
  fixtures (see `inst/COPYRIGHTS`), and requires reticulate \>= 1.41.0,
  the first release with `py_require()` (which `.onLoad()` calls).

### README

- The README’s “Verbs and semantics” section showed only errors (the
  chunk-map section had reused and closed its connection, and a
  chunk-wide `error = TRUE` let the build pass). Each example now has
  its own connection and only the intended guard error is allowed. Also
  corrected: a filter example used the R object’s name for the variable,
  `NA` vs `NaN`, 0-d results, the laziness claims, and the `chunks` note
  now follows the ERA5 example it is about.

- The README gains a live chunk-map section: the 1024 x 1024 block grid
  of a Sentinel-2 Cloud-Optimized GeoTIFF, and a window’s touched blocks
  shaded by how much of each it reads (figure in `man/figures/`).

- The README is now `README.Rmd`, built live with
  `devtools::build_readme()` against the remote examples (OISST over
  HTTPS, ARCO ERA5 on GCS, the OISST multidim VRT via gdalxarray), and
  it gains a dplyr section.

### Fixes

- Rows render from GDAL rasters opened with gdalxarray’s classic mode
  (`multidim = FALSE`). Their x and y carry rasterix’s `RasterIndex`,
  which `to_dataframe()` cannot cast to pandas, so every row query
  failed; a scalar `y` selection, which leaves `x` with no index at all,
  failed differently. Rendering now gives such coordinates plain pandas
  indexes first.
  [`xr_raster()`](https://mdsumner.github.io/xrdbi/reference/xr_raster.md)
  and
  [`xr_chunks()`](https://mdsumner.github.io/xrdbi/reference/xr_chunks.md)
  still read the original indexes.

- [`tbl()`](https://dplyr.tidyverse.org/reference/tbl.html) filters on a
  GDAL raster’s `y`, which runs north to south, select the right side.
  The direction check read `ds.indexes`, failed on the `RasterIndex` and
  assumed ascending, so `filter(y > ...)` returned nothing. The
  direction check, the strict-bound trim and the empty-result hint now
  use the coordinate’s `to_index()`, which works for any index.

- Numbers in compiled statements are written to round-trip exactly. At
  15 significant digits a value fetched from the data, such as a
  coordinate (-22.941163999999997), became -22.941164, and a strict
  bound at it kept its own cell. Values as typed (18, -44.83) are
  written as before.

- A vector cube’s geometry keeps its CRS when the geometry coordinate
  has geopandas’ `geometry` extension dtype, as the result of xvec’s
  `zonal_stats()` does. Only object-dtype coordinates were looked at, so
  the values arrived as
  [`wk::wkb()`](https://paleolimbot.github.io/wk/reference/wkb.html) but
  without the CRS.

- [`collect()`](https://dplyr.tidyverse.org/reference/compute.html) on a
  [`tbl()`](https://dplyr.tidyverse.org/reference/tbl.html) takes
  `max_cells`, like the other guarded functions. It went into `...` and
  was ignored, so `collect(x, max_cells = 10)` read everything.
  [`as.data.frame()`](https://rdrr.io/r/base/as.data.frame.html) takes
  the same arguments and now gives a plain data frame (it was defined
  twice, the second definition returning a tibble).

- A POSIXct in a
  [`tbl()`](https://dplyr.tidyverse.org/reference/tbl.html) filter or
  [`xr_query()`](https://mdsumner.github.io/xrdbi/reference/xr_query.md)
  is compiled as its instant in UTC, as xarray stores times. It was
  written as wall-clock time in the object’s own zone, so a bound in
  e.g. Australia/Hobart selected 11 hours off. (`params` already
  converted to UTC.)

- [`xr_raster()`](https://mdsumner.github.io/xrdbi/reference/xr_raster.md)
  and
  [`xr_chunks()`](https://mdsumner.github.io/xrdbi/reference/xr_chunks.md)
  find a CRS from a CF `grid_mapping` variable’s parameters
  (`grid_mapping_name` and the rest), through pyproj when installed, as
  a last resort: authored WKT (`crs_wkt`, `spatial_ref`) anywhere still
  comes first.

- [`xr_raster()`](https://mdsumner.github.io/xrdbi/reference/xr_raster.md)
  finds the CRS that gdalxarray records in an xproj `CRSIndex` (its
  `crs` coordinate has no attributes), or that a rasterix `RasterIndex`
  carries; `srs` was empty for gdalxarray rasters.

- A 0-d data variable renders with its scalar coordinates ahead of its
  value, as `to_dataframe()` would: a single cell, or a nearest-point
  lookup, keeps where it is (`time`, `lat`, `lon`, …) instead of only
  the value. A 0-d coordinate still renders just itself.

- [`xr_raster()`](https://mdsumner.github.io/xrdbi/reference/xr_raster.md)
  accepts regular grids stored as float32. Their rounding (about 1.2e-7
  of each value) made the steps of e.g. a 0.44 degree rotated-pole grid
  vary by 1e-5 of the step, failing a fixed 1e-6 tolerance; the
  tolerance now scales with the coordinate’s precision, and the step is
  the mean over the axis.

- The cell guard never fired above 2^31 cells, so it missed exactly the
  reads it exists to stop. reticulate converts a Python int that large
  into a wrapped R integer (2^31 became `NA`, 17 billion became
  -179,869,184), so `dbReadTable(con, "sst")` on the full OISST record
  started rendering 17 billion cells instead of erroring. Sizes now
  cross as doubles, in
  [`dbFetch()`](https://dbi.r-dbi.org/reference/dbFetch.html),
  [`dbReadTable()`](https://dbi.r-dbi.org/reference/dbReadTable.html)
  and [`collect()`](https://dplyr.tidyverse.org/reference/compute.html),
  and guard messages print counts in full.

- Printing a connection cuts the variable list to the console width,
  with a total (ERA5 has 273 data variables).

- [`show_query()`](https://dplyr.tidyverse.org/reference/explain.html)
  backticks non-syntactic names in the R steps line, so it is valid R.

### Faster, type-faithful conversion to R

- [`dbFetch()`](https://dbi.r-dbi.org/reference/dbFetch.html),
  [`dbGetQuery()`](https://dbi.r-dbi.org/reference/dbGetQuery.html),
  [`dbReadTable()`](https://dbi.r-dbi.org/reference/dbReadTable.html)
  and [`collect()`](https://dplyr.tidyverse.org/reference/compute.html)
  now convert the rendered pandas frame column by column from numpy
  buffers instead of with reticulate’s whole-DataFrame conversion. A
  10M-row fetch with a time dimension drops from ~22 s to ~1.2 s; nearly
  all the old cost was reticulate’s handling of a datetime column.

- Types that were wrong before now convert properly: NaT is `NA` (it was
  1677-09-21 in a numpy route), timedeltas are `difftime` seconds (they
  were `NA` dates), pandas string columns such as string coordinates are
  character (they were left as Python objects), categoricals are factors
  (they made the fetch error), cftime values from non-standard calendars
  are ISO strings (they were a list of Python objects), bytes are
  decoded, and nullable integers and booleans keep `NA`.

- For a plain DataArray (the usual `ds.var.sel(...)` statement, and
  [`tbl()`](https://dplyr.tidyverse.org/reference/tbl.html) pipelines
  whose filters all push down to `.sel()`), the long form is now built
  in R: only the values, flattened in C order, cross from Python, and
  the coordinate columns are repeated with
  [`rep()`](https://rdrr.io/r/base/rep.html). The 10M-row fetch drops
  again to ~0.55 s, and `dbFetch(n = )` builds only the rows asked for
  (10 chunks of 1M rows: ~0.4 s in total). The output is identical to
  the pandas render. Datasets, 0-d and empty results, MultiIndex
  coordinates and pandas-stage statements still go through the pandas
  render.

- [`head()`](https://rdrr.io/r/utils/head.html) and
  [`select()`](https://dplyr.tidyverse.org/reference/select.html) in
  [`tbl()`](https://dplyr.tidyverse.org/reference/tbl.html) pipelines no
  longer force a pandas stage unless a filter on data values needs one.
  They apply in R to the fetched rows, and `head(n)` first narrows the
  selection to the leading block holding its first `n` rows. `head(10)`
  on a lazy 207M-cell variable collects in 0.07 s and reads one chunk;
  before, it tripped the cell guard, and with `force` it rendered the
  whole selection in pandas.
  [`show_query()`](https://dplyr.tidyverse.org/reference/explain.html)
  and the printed tbl list the R steps.

- `collect(force = TRUE)` works again for pipelines that compile to a
  plain xarray selection.
  [`collect()`](https://dplyr.tidyverse.org/reference/compute.html)
  honoured `force`, but
  [`dbFetch()`](https://dbi.r-dbi.org/reference/dbFetch.html) checked
  the guard again without it. The collect guard now counts the cells
  actually read (strict trims and the
  [`head()`](https://rdrr.io/r/utils/head.html) block included).

- Datasets now take the R-built path too, mirroring xarray’s
  `to_dataframe()`: rows are every combination of the Dataset’s dims,
  and each non-index variable is broadcast across them, whether or not
  the variables share dims. 10M rows x 2 variables: 0.78 s instead of
  1.71 s, identical output. Stacked (MultiIndex) dims, other non-dim
  indexes and pandas extension arrays still use the pandas render.

- The cell guard now applies to Datasets. A Dataset has no `.size`, so
  the guard silently never fired: `dbGetQuery(con, "ds")` on a large
  store would try to load all of it. It now counts rows x data
  variables.

- A 0-d Dataset (every dim selected to one value) renders as one row; it
  errored in `to_dataframe()`.

- [`tbl()`](https://dplyr.tidyverse.org/reference/tbl.html) filters on
  non-dimension coordinates (2-D `lat`/`lon` of a curvilinear grid, a
  1-D coordinate along `time`) narrow the read to the index block
  holding every cell that passes, computed from the coordinates at
  collect time; the pandas query still applies them exactly inside the
  block. On a 40 x 60 grid a lat/lon box reads 507 of 7,200 cells. The
  collect guard counts the narrowed read, and the preview’s note no
  longer blames value filters for coordinate filters.

- Strict bounds on a dimension in
  [`tbl()`](https://dplyr.tidyverse.org/reference/tbl.html) filters
  (`lat > 18`, `time < as.Date(...)`) no longer drop to a pandas
  `.query()`. The inclusive `.sel()` hull is trimmed with a boolean
  `.isel()` on the dimension’s index, which uses the same pandas
  comparison as the query, so date strings keep their meaning. The
  statement stays a DataArray and takes the R-built path: 4.8M rows
  collect in 0.43 s instead of 1.16 s, with identical output. Filters on
  data variables,
  [`select()`](https://dplyr.tidyverse.org/reference/select.html) and
  [`head()`](https://rdrr.io/r/utils/head.html) still use the pandas
  stage.

- Datetimes without a zone now carry `tzone = "UTC"`, so they display as
  the instant the source means regardless of the session zone.
  Timezone-aware datetimes keep their zone.

- The GDAL autotest fixture tests had been skipping because of a stale
  helper call; they run again.

### xr_raster(): raster rendering of a result

- Printing a `tbl` now renders a lazy preview - sizes from metadata, the
  first cells clamped to at most one chunk read, tibble-formatted, with
  `options(xrdbi.print_preview = FALSE)` to opt out; and the compiled
  pandas stage routes through the connection’s renderer
  (`.pipe(_xrdbi_render`), visible in
  [`show_query()`](https://dplyr.tidyverse.org/reference/explain.html)),
  so coordinate tables, 0-d results, and empty selections behave
  identically in tbl pipelines and raw statements.

- New
  [`xr_raster()`](https://mdsumner.github.io/xrdbi/reference/xr_raster.md)
  renders a slab in gdalraster’s in-memory raster format: a plain vector
  of pixel values (left-to-right, top-to-bottom, band-sequential;
  `as_list = TRUE` for a list of band vectors) with a `gis` attribute
  carrying `type`, `bbox`, `dim`, `srs`, and `datatype` –
  interchangeable with the output of
  [`gdalraster::read_ds()`](https://firelab.github.io/gdalraster/reference/read_ds.html),
  and compatible with `ximage::ximage()`.

- Where [`dbFetch()`](https://dbi.r-dbi.org/reference/dbFetch.html)
  renders the tidy long-form data frame, this is a sibling rendering on
  the same lazy result: `xr_raster(res)` on an XarrayResult, or
  `xr_raster(con, statement)`. The DBI contract is untouched. The array
  is a rendering format; so is the data frame; so is this.

- Shapes: 2-D (y, x) single band, or 3-D (band, y, x) band-sequential
  stack (a time series of slabs; dim order preserved, so band b is
  unambiguously e.g. time\[b\]). 4-D and higher refuse with an error
  carrying the explicit flatten recipe (e.g.
  `.stack(band=('zlev','time')).transpose('band','lat','lon')`), because
  the gis format has no band-names field and silent flattening would
  invent an ordering the object cannot record. y and x are positionally
  the last two dims (CF/xarray convention). Dimension coordinates must
  be regular (“warp first” otherwise); the half-cell bbox expansion
  assumes cell centres; ascending or descending order on either axis is
  handled. The `xrdbi.max_cells` guard applies.

### CRS: lifted

- `gis$srs` is populated by a verbatim lift, in order of specificity: a
  `spatial_ref`/`crs` coordinate on the object ; the variable’s CF
  `grid_mapping` pointer followed into the parent dataset (grid-mapping
  variables are 0-d data variables and do not propagate through
  selection); or conventional names at the dataset level (catching
  statements that strip attrs, e.g. arithmetic). Only an authored
  `crs_wkt`/`spatial_ref` WKT string is ever read; CF
  projection-parameter interpretation is deliberately out of scope.

### Self-contained test fixtures

- A curated set of GDAL autotest files (four netCDFs exercising CF
  packing, descending latitude, and grid mappings, plus the canonical
  byte.tif and 3-band rgbsmall.tif) is vendored flat into
  `inst/extdata/autotest/` (~100 KB) with a PROVENANCE file recording
  source paths, commit, and the MIT/X license. `tools/update-fixtures.R`
  re-vendors from a checkout; the GDAL_AUTOTEST environment variable is
  now only needed when updating fixtures, never for testing.

- The `rotated_pole.nc` tests name their engine. Without one, a Python
  missing netCDF4 opened the file with gdalxarray, and the grid-mapping
  test skipped as an engine difference instead of saying netCDF4 was
  missing. netcdf4 keeps `projection` as a 0-d variable; a new test
  checks that gdalxarray’s classic mode puts the rotated-pole CRS in
  [`xr_raster()`](https://mdsumner.github.io/xrdbi/reference/xr_raster.md)’s
  `srs`.

## xrdbi 0.0.1.9000 (development)

Initial DBI backend for xarray: the “database” is a live Python session
(reticulate) holding an xarray object.

### Features

- `dplyr` verbs over any xarray-openable source; dimension filters push
  down to oriented label slices, value filters apply before conversion;
  one inspectable python statement. `tbl(con, var)` returns a lazy spec;
  filter/select/head accumulate;
  [`collect()`](https://dplyr.tidyverse.org/reference/compute.html)
  compiles ONE python statement and runs it through `dbGetQuery`.
  Dimension predicates push down to an inclusive `.sel` hull (fewer
  chunks touched); strict bounds and data-variable predicates remain as
  a pandas `.query` applied before conversion to R (pushdown with
  residuals). At collect, each hull dimension is probed for direction
  and the slice oriented to match, so range filters work identically on
  ascending and descending coordinates.
  [`show_query()`](https://dplyr.tidyverse.org/reference/explain.html)
  prints the compiled python.

- Three connect forms via `dbConnect(xarray(), ...)`: a `dsn` string
  that xarray can open (open function selectable via `open =`, keyword
  arguments passed through), a `builder` function receiving the xarray
  module (for icechunk sessions, virtualizarr, multi-step opens), or an
  existing Python `object` adopted from the session.

- Statements are Python expressions evaluated with `ds` and `xr` in
  scope.
  [`dbSendQuery()`](https://dbi.r-dbi.org/reference/dbSendQuery.html) is
  lazy (builds the selection graph, moves no bytes); rendering to the
  tidy long-form data frame happens at
  [`dbFetch()`](https://dbi.r-dbi.org/reference/dbFetch.html), paginated
  Python-side.

- [`xr_query()`](https://mdsumner.github.io/xrdbi/reference/xr_query.md)
  compiles a structured spec (vars, sel, isel, method, tail) to an
  inspectable Python expression string. `isel` is zero-based,
  faithfully: values are interpolated, not translated.

- Coordinates are tables too:
  [`dbListTables()`](https://dbi.r-dbi.org/reference/dbListTables.html)
  lists `ds.variables` (data variables and coordinates); the data/coords
  split remains available via
  [`dbGetInfo()`](https://dbi.r-dbi.org/reference/dbGetInfo.html).
  Dimension coordinates render as a single column of their values;
  scalar coordinates and scalar results as a one-row frame; a
  non-dimension coordinate’s self-reference is deduplicated.

- All results funnel through a single Python-side renderer installed at
  connect, covering Dataset, DataArray (including 0-d), and plain Python
  values.

- Kind messages on empty results: when a selection collapses a dimension
  to zero, the parent coordinate is inspected and the message reports a
  DESCENDING coordinate (label slices follow coordinate order; try
  slice(hi, lo)) or the coordinate span (catches out-of-range values and
  -180..180 vs 0..360 longitude conventions).

- Whole-variable reads are guarded against accidental terabyte
  renderings (`options(xrdbi.max_cells = )`, or `force = TRUE`).

- Escape hatches: `xr_dataset(con)` and `xr_module(con)` return the live
  Python handles.

- Transactions (`dbBegin`/`dbCommit`/`dbRollback`) error with a pointer
  to the intended mapping onto icechunk sessions and commits.

### Fixes

- Statement scope is built with `py_dict()` and explicit character keys;
  [`reticulate::dict()`](https://rstudio.github.io/reticulate/reference/dict.html)
  resolves argument names against calling frame variables, which made
  the local `ds` Dataset a dict key (unhashable) (#nn).

- Removed use of a nonexistent `reticulate::py_slice()`; pagination uses
  builtins `slice`.

- 0-d renderings use `values[()]` rather than `.item()`, which returns
  raw integer nanoseconds for ns-precision datetimes.

### Documentation

- Worked examples against real sources: OISST NetCDF over HTTPS
  (h5netcdf), ARCO ERA5 zarr v3 on anonymous GCS (including the
  descending-latitude gotcha, kept in as a lesson), and an OISST daily
  multidim VRT mosaic via the gdalxarray engine (deferred credential
  errors, connection-as-snapshot semantics).

- Guidance on `chunks`: omit for lazy zarr-backed arrays and fast
  connects; `chunks = dict()` wraps variables in dask at native storage
  chunking, which for finely-chunked stores can cost minutes of task
  graph construction (observed: 96s vs 7s on a 1-timestep-per-chunk
  store). Note the differing defaults of `open_dataset` (None) and
  `open_zarr` (“auto”).

### Planned

- dbplyr-style laziness via
  [`tbl()`](https://dplyr.tidyverse.org/reference/tbl.html) in the
  dtplyr/duckplyr mould: capture dplyr verbs, compile to
  [`xr_query()`](https://mdsumner.github.io/xrdbi/reference/xr_query.md)
  specs (filter on dim coords to sel/isel, value predicates to where,
  summarise to reductions).

- Alternate renderings as sibling verbs on a result, leaving the
  [`dbFetch()`](https://dbi.r-dbi.org/reference/dbFetch.html) data frame
  contract intact: `xr_array()` (values plus dims and coords, skipping
  the pandas hop) and
  [`xr_raster()`](https://mdsumner.github.io/xrdbi/reference/xr_raster.md)
  (SpatRaster from a regular-grid slab).

- DataTree groups as schemas, write support (to_zarr / icechunk commit),
  registry integration (`dbConnect(xarray(), dsn(...))`).
