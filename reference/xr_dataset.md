# Drop to the underlying Python objects

`xr_dataset()` returns the xarray Dataset handle (not converted),
`xr_module()` the xarray module. Everything the veneer cannot express is
one step away.

## Usage

``` r
xr_dataset(conn)

xr_module(conn)
```

## Arguments

- conn:

  an XarrayConnection

## Value

a reticulate Python object, not converted to R

## See also

[dbConnect()](https://mdsumner.github.io/xrdbi/reference/dbConnect-XarrayDriver-method.md)
with `object = ` to connect to a Dataset built or changed in Python;
[xrdbi-package](https://mdsumner.github.io/xrdbi/reference/xrdbi-package.md)
for an overview.

## Examples

``` r
if (FALSE) { # \dontrun{
## needs a Python environment with xarray (see ?xrdbi)
f <- system.file("extdata/autotest/trmm.nc", package = "xrdbi")
con <- dbConnect(xarray(), f)
ds <- xr_dataset(con)
ds$pcp$encoding
xr_module(con)$`__version__`
} # }
```
