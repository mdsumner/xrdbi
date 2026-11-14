# Compile a structured selection to a Python expression

A thin, inspectable alternative to writing the Python yourself. The
return value is a plain string, so `dbGetQuery(con, xr_query(...))` and
`dbGetQuery(con, "ds.sst.isel(time=0)")` are the same thing. Print it,
log it, put it in a registry row.

## Usage

``` r
xr_query(vars = NULL, sel = NULL, isel = NULL, method = NULL, tail = NULL)
```

## Arguments

- vars:

  character vector of data variable names, NULL for all

- sel:

  named list of label-based selections

- isel:

  named list of integer (zero-based) selections

- method:

  optional method for inexact `sel` matches, e.g. "nearest"

- tail:

  extra Python method chain appended verbatim, e.g. `".mean('time')"`

## Value

character, a Python expression over `ds`

## Details

Rules for `sel` and `isel` values:

- a length-2 numeric, `Date` or `POSIXct` vector becomes a Python
  `slice(a, b)` (a range on that dimension; for `sel` this is
  label-based and inclusive per xarray)

- a length-1 value is a scalar selection (drops the dimension)

- character vectors, even of length 2, and longer vectors become Python
  lists: exact labels (`sel = list(station = c("A01", "B02"))`) or
  positions. For a time range give `Date` or `POSIXct`, not strings

- a `POSIXct` is written as its instant in UTC, as xarray stores times

NOTE `isel` uses zero-based Python indices, faithfully: this function
interpolates values into Python source and does not translate them. The
compiled expression is the contract; inspect it.

## See also

[XarrayResult](https://mdsumner.github.io/xrdbi/reference/XarrayResult-class.md)
to run the statement;
[tbl()](https://mdsumner.github.io/xrdbi/reference/tbl_xarray.md) to
compile statements from dplyr verbs instead.

## Examples

``` r
xr_query(vars = "sst", sel = list(lat = c(-80, -60)), isel = list(time = 0))
#> [1] "ds['sst'].sel(lat=slice(-80, -60)).isel(time=0)"
```
