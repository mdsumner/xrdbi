# Read a variable as a tidy data frame

The rendering is the tidy long form of `ds[name]`, exactly as
`to_dataframe().reset_index()` gives it: one row per cell, every
coordinate as a column. This materializes the variable, so it is
guarded: reads above `max_cells` cells error unless `force = TRUE`. Set
`options(xrdbi.max_cells = )` to taste.

## Usage

``` r
# S4 method for class 'XarrayConnection,character'
dbReadTable(
  conn,
  name,
  ...,
  max_cells = getOption("xrdbi.max_cells", 1e+07),
  force = FALSE
)
```

## Arguments

- conn:

  an XarrayConnection

- name:

  a variable name

- ...:

  unused

- max_cells:

  guard threshold, default `getOption("xrdbi.max_cells", 1e7)`

- force:

  bypass the guard

## Value

a data frame, one row per cell of the variable

## See also

[tbl()](https://mdsumner.github.io/xrdbi/reference/tbl_xarray.md) or a
statement
([XarrayResult](https://mdsumner.github.io/xrdbi/reference/XarrayResult-class.md))
to read part of a variable; the guard's option in
[xrdbi-package](https://mdsumner.github.io/xrdbi/reference/xrdbi-package.md).

## Examples

``` r
if (FALSE) { # \dontrun{
## needs a Python environment with xarray (see ?xrdbi)
f <- system.file("extdata/autotest/trmm.nc", package = "xrdbi")
con <- dbConnect(xarray(), f)
dbReadTable(con, "latitude")
head(dbReadTable(con, "pcp"))
## the guard: 1600 cells is over a limit of 100
try(dbReadTable(con, "pcp", max_cells = 100))
} # }
```
