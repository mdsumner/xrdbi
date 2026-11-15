# A lazy dplyr table over an xarray variable or grid

`tbl(con, from)` returns a lazy table over one variable, or over a grid
of variables: dplyr verbs accumulate, and no data are read until
[`dplyr::collect()`](https://dplyr.tidyverse.org/reference/compute.html)
(or a print, which shows a small preview). The verbs compile to a single
Python statement, shown by
[`dplyr::show_query()`](https://dplyr.tidyverse.org/reference/explain.html)
and run through
[`DBI::dbGetQuery()`](https://dbi.r-dbi.org/reference/dbGetQuery.html)
like any other statement. Building it checks field names and probes
coordinates, which needs Python, but reads no data.

## Usage

``` r
# S3 method for class 'XarrayConnection'
tbl(src, from, ...)
```

## Arguments

- src:

  an XarrayConnection

- from:

  a variable name (a data variable, or a coordinate); several data
  variables on one grid; or the name of a grid, as
  [`xr_grids()`](https://mdsumner.github.io/xrdbi/reference/xr_grids.md)
  lists it (either view)

- ...:

  unused

## Value

a lazy `tbl_xarray`;
[`dplyr::collect()`](https://dplyr.tidyverse.org/reference/compute.html)
returns a tibble

## Details

A grid is the set of variables on one set of dimensions (see
[`xr_grids()`](https://mdsumner.github.io/xrdbi/reference/xr_grids.md)),
and a grid table has a column per member, as tidync's `hyper_tibble()`
does: `tbl(con, c("sst", "ice"))` for some members, or
`tbl(con, "time,zlev,lat,lon")` for a grid by its name. It compiles to a
Dataset statement, `ds[['sst', 'ice']]`, and the verbs apply as they do
to one variable, with these differences:

- [`select()`](https://dplyr.tidyverse.org/reference/select.html)
  decides which members are read: the statement names the selected
  members, plus any a filter needs (which are dropped after it). It must
  name at least one member.

- the guard counts values, cells times members.

- printing previews at most `getOption("xrdbi.preview_members", 4)`
  members, since each is at least a chunk read.

- variables on different grids are refused, because a statement over
  both would repeat each value along the dimensions its variable lacks
  (a surface field across 37 pressure levels).

[`xr_chunks()`](https://mdsumner.github.io/xrdbi/reference/xr_chunks.md)
takes a lazy table too, and maps what collecting it would read: for a
grid table, a row per member read and chunk.

Supported verbs:
[`filter()`](https://dplyr.tidyverse.org/reference/filter.html),
[`select()`](https://dplyr.tidyverse.org/reference/select.html) (plain
column names), [`head()`](https://rdrr.io/r/utils/head.html),
[`collect()`](https://dplyr.tidyverse.org/reference/compute.html),
[`show_query()`](https://dplyr.tidyverse.org/reference/explain.html),
and [`as.data.frame()`](https://rdrr.io/r/base/as.data.frame.html).
[`filter()`](https://dplyr.tidyverse.org/reference/filter.html) takes
`==`, `%in%`, `<`, `<=`, `>`, `>=`,
[`between()`](https://dplyr.tidyverse.org/reference/between.html) and
`&` (or several arguments), each comparing a field with a value; there
is no `|`, `!` or `!=`.
[`collect()`](https://dplyr.tidyverse.org/reference/compute.html) is
guarded like
[`DBI::dbFetch()`](https://dbi.r-dbi.org/reference/dbFetch.html): above
`max_cells` cells read (default `getOption("xrdbi.max_cells", 1e7)`) it
errors unless `collect(force = TRUE)`;
[`as.data.frame()`](https://rdrr.io/r/base/as.data.frame.html) takes the
same arguments and gives a plain data frame. Printing shows the first
`getOption("xrdbi.print_n", 6)` rows, reading at most one chunk;
`options(xrdbi.print_preview = FALSE)` turns the preview off.

Filters are pushed into xarray where they can be, and the rest applied
after (the "residual"):

- a filter on a dimension (`==`, `%in%`, or a range) compiles to an
  inclusive `.sel()`, so only the part of the array it selects (its
  "hull") is read; `%in%` is an exact `.sel([...])`

- strict inequalities on a dimension use the inclusive hull, then a
  boolean `.isel()` on that dimension's index trims the boundary, so the
  result is still an xarray object

- predicates on data variables, and mixed forms on one dimension, are
  kept as a pandas `.query()` applied Python-side, before conversion to
  R

- predicates on non-dimension coordinates (2-D `lat`/`lon` of a
  curvilinear grid, a 1-D coordinate along `time`) stay in that query
  for exactness, but are checked against the coordinates at collect time
  and the read narrowed to the index block holding every passing cell
  (`.isel()` with literal slices, visible in
  [`show_query()`](https://dplyr.tidyverse.org/reference/explain.html)).
  Dimensions without coordinates are pinned to their positions first
  (`.assign_coords(y=range(n))`), so they render as they would
  unfiltered

- without such a query, [`head()`](https://rdrr.io/r/utils/head.html)
  and [`select()`](https://dplyr.tidyverse.org/reference/select.html)
  apply in R to the fetched rows, and `head(n)` first narrows the
  selection to the leading block that holds its `n` rows, so a peek at a
  huge variable reads one corner;
  [`dplyr::show_query()`](https://dplyr.tidyverse.org/reference/explain.html)
  lists these R steps

- at collect time each hull dimension is asked for its direction, and
  the slice is oriented to match: `filter(latitude > 18, latitude < 19)`
  works identically on ascending and DESCENDING coordinates

## See also

[XarrayResult](https://mdsumner.github.io/xrdbi/reference/XarrayResult-class.md)
for statements written in Python (and values passed with `params`);
[`xr_query()`](https://mdsumner.github.io/xrdbi/reference/xr_query.md);
[`xr_grids()`](https://mdsumner.github.io/xrdbi/reference/xr_grids.md)
for the grids; the guard and preview options in
[xrdbi-package](https://mdsumner.github.io/xrdbi/reference/xrdbi-package.md).

## Examples

``` r
if (FALSE) { # \dontrun{
## needs a Python environment with xarray (and here zarr, gcsfs)
library(dplyr)
con <- dbConnect(xarray(),
  "gs://gcp-public-data-arco-era5/ar/full_37-1h-0p25deg-chunk-1.zarr-v3",
  engine = "zarr", storage_options = reticulate::dict(token = "anon"))
u <- tbl(con, "100m_u_component_of_wind") |>
  filter(latitude > 18, latitude < 19, longitude >= 73, longitude <= 74,
         time >= as.POSIXct("1980-01-01", tz = "UTC"),
         time < as.POSIXct("1980-01-02", tz = "UTC"))
show_query(u)
collect(u)
## the store's time axis starts in 1900, its data in 1940
tbl(con, "2m_temperature") |>
  filter(time >= as.POSIXct("1980-01-01", tz = "UTC")) |>
  head(3) |> collect()

## the surface grid: 262 members, of which select() reads three
xr_grids(con)
wind <- tbl(con, "time,latitude,longitude") |>
  filter(time >= as.POSIXct("2020-01-01 00:00", tz = "UTC"),
         time <= as.POSIXct("2020-01-01 05:00", tz = "UTC"),
         latitude >= -43, latitude <= -42,
         longitude >= 147, longitude <= 148) |>
  select(time, latitude, longitude, `2m_temperature`,
         `10m_u_component_of_wind`, `10m_v_component_of_wind`)
show_query(wind)
collect(wind)
xr_chunks(wind)   # 18 chunks: 6 hours, 3 members
} # }
```
