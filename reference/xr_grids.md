# List the grids of a Dataset

A grid is the set of variables that share one set of dimensions, as
tidync's grids are: ERA5's 273 variables are two grids, a surface grid
over `(time, latitude, longitude)` and a pressure-level grid over
`(time, level, latitude, longitude)`. Each grid can be read as one
table, with a column per member: give
[tbl()](https://mdsumner.github.io/xrdbi/reference/tbl_xarray.md) its
name, or several of its variables. xarray has no grid object; this
listing groups the variables by their dimensions. Only metadata is read.

## Usage

``` r
xr_grids(con, view = c("meaning", "storage"))
```

## Arguments

- con:

  an XarrayConnection

- view:

  `"meaning"` or `"storage"`, see Details

## Value

a tibble, one row per grid, most dimensions first, then most variables:
`grid`, its dimensions joined by commas (the name
[tbl()](https://mdsumner.github.io/xrdbi/reference/tbl_xarray.md)
takes); `ndims`; `cells`, the product of the dimension sizes (`NA` in
the storage view for a grid whose arrays store a character dimension);
`n`, the number of variables; the list column `variables`; and
`chunkings`, the number of distinct storage chunk shapes among them (a
grid whose members share a key space has 1). The meaning view adds the
list column `coords`, the coordinates whose dimensions lie within the
grid; the storage view adds `roles`, how many of the arrays are data
variables, coordinates and dimension coordinates.

## Details

Two views:

- `"meaning"` (the default) groups data variables by their dimensions as
  xarray decodes them, taken as a set (`(lat, lon)` and `(lon, lat)` are
  one grid), and lists the coordinates that belong to each grid. These
  are the grids a table can be built over.

- `"storage"` groups every stored array, coordinates included, by its
  dimensions as stored, in order. A character array that xarray decodes
  to strings keeps its character dimension
  (`encoding["char_dim_name"]`), so a netCDF file lists the grids tidync
  (through ncmeta) finds: 16 in an Argo profile file where the meaning
  view has 5.

## See also

[tbl()](https://mdsumner.github.io/xrdbi/reference/tbl_xarray.md) to
read a grid as a table;
[`xr_chunks()`](https://mdsumner.github.io/xrdbi/reference/xr_chunks.md)
for its chunk map;
[xrdbi-package](https://mdsumner.github.io/xrdbi/reference/xrdbi-package.md)
for an overview.

## Examples

``` r
if (FALSE) { # \dontrun{
## needs a Python environment with xarray (see ?xrdbi)
f <- system.file("extdata/autotest/two_vars_scale_offset.nc",
                 package = "xrdbi")
con <- dbConnect(xarray(), f)
xr_grids(con)
xr_grids(con, "storage")
dbDisconnect(con)
} # }
```
