# xarray DBI driver

Use with
[`DBI::dbConnect()`](https://dbi.r-dbi.org/reference/dbConnect.html) to
open a connection to an xarray object in a live Python session managed
by reticulate (see
[dbConnect()](https://mdsumner.github.io/xrdbi/reference/dbConnect-XarrayDriver-method.md)).

## Usage

``` r
xarray()

# S4 method for class 'XarrayDriver'
show(object)

# S4 method for class 'XarrayDriver'
dbUnloadDriver(drv, ...)

# S4 method for class 'XarrayDriver'
dbDataType(dbObj, obj, ...)
```

## Arguments

- object, drv, dbObj:

  an XarrayDriver

- ...:

  unused

- obj:

  an R object, for
  [`dbDataType()`](https://dbi.r-dbi.org/reference/dbDataType.html)

## Value

`xarray()`: an XarrayDriver.
[`dbDataType()`](https://dbi.r-dbi.org/reference/dbDataType.html):
character, the numpy dtype an R vector maps to.
[`dbUnloadDriver()`](https://dbi.r-dbi.org/reference/dbDriver.html):
`TRUE`, invisibly. [`show()`](https://rdrr.io/r/methods/show.html):
called for its output.

## See also

[dbConnect()](https://mdsumner.github.io/xrdbi/reference/dbConnect-XarrayDriver-method.md)
to open a connection;
[xrdbi-package](https://mdsumner.github.io/xrdbi/reference/xrdbi-package.md)
for an overview.

## Examples

``` r
drv <- xarray()
drv
#> <XarrayDriver>
dbDataType(drv, Sys.Date())
#> [1] "datetime64[D]"
if (FALSE) { # \dontrun{
## needs a Python environment with xarray (see ?xrdbi)
f <- system.file("extdata/autotest/trmm.nc", package = "xrdbi")
con <- dbConnect(drv, f)

## open_zarr defaults to dask; chunks = None keeps the fast lazy path
reticulate::py_require("zarr")
con <- dbConnect(drv, "path/or/url.zarr", open = "open_zarr",
                 chunks = reticulate::py_none())
} # }
```
