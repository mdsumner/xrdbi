# Connect to an xarray object

Exactly one of `dsn`, `builder`, `object` must be supplied.

## Usage

``` r
# S4 method for class 'XarrayDriver'
dbConnect(
  drv,
  dsn = NULL,
  ...,
  open = "open_dataset",
  builder = NULL,
  object = NULL
)
```

## Arguments

- drv:

  result of
  [`xarray()`](https://mdsumner.github.io/xrdbi/reference/xarray.md)

- dsn:

  character string openable by xarray

- ...:

  keyword arguments passed to the xarray open function

- open:

  name of the xarray open function, default "open_dataset"

- builder:

  function taking the xarray module, returning a Dataset

- object:

  an existing Python xarray object to adopt

## Value

an
[XarrayConnection](https://mdsumner.github.io/xrdbi/reference/XarrayConnection-class.md)

## Details

- `dsn`: a string that xarray can open. Passed to `xr.<open>(dsn, ...)`
  where `open` is `"open_dataset"` by default (also useful:
  `"open_zarr"`, which defaults to dask, so pass
  `chunks = reticulate::py_none()` for the lazy path;
  `"open_mfdataset"`, which needs dask,
  `reticulate::py_require("dask")`; and `"open_datatree"`). Extra named
  arguments in `...` are passed through as Python keyword arguments,
  e.g. `engine = "h5netcdf"`, `decode_times = TRUE`, or
  `chunks = reticulate::dict()` (Python `chunks={}`: dask at the storage
  chunking; an R [`list()`](https://rdrr.io/r/base/list.html) would
  become a Python list). `engine = "gdalxarray"` opens anything GDAL
  reads (it needs the GDAL Python bindings; see
  [xrdbi-package](https://mdsumner.github.io/xrdbi/reference/xrdbi-package.md)).
  It uses GDAL's multidimensional API by default; `multidim = FALSE`
  uses the classic raster API, where a GeoTIFF or COG becomes one
  variable, `band_data`, over (band, y, x).

- `builder`: an R function of one argument (the xarray module, not
  converted) returning a Dataset. Use this when construction needs more
  than a single open call, e.g. virtualizarr or icechunk session setup.

- `object`: an existing reticulate Python object (an xarray Dataset),
  adopted as-is. Handy when the object was built interactively with
  [`reticulate::py_run_string()`](https://rstudio.github.io/reticulate/reference/py_run.html)
  or in a repl.

The connection holds a reference to the Python object. Opening reads
metadata; data are read when a result is fetched (see
[XarrayResult](https://mdsumner.github.io/xrdbi/reference/XarrayResult-class.md)
for statements that compute).

## See also

[XarrayConnection](https://mdsumner.github.io/xrdbi/reference/XarrayConnection-class.md)
for what a connection offers;
[XarrayResult](https://mdsumner.github.io/xrdbi/reference/XarrayResult-class.md)
to query it with Python statements;
[tbl()](https://mdsumner.github.io/xrdbi/reference/tbl_xarray.md) to
query it with dplyr verbs; the Python requirements in
[xrdbi-package](https://mdsumner.github.io/xrdbi/reference/xrdbi-package.md)
for the engines a source needs.

## Examples

``` r
if (FALSE) { # \dontrun{
## needs a Python environment with xarray (see ?xrdbi)
f <- system.file("extdata/autotest/trmm.nc", package = "xrdbi")
con <- dbConnect(xarray(), f)

## anything that takes more than one call
con <- dbConnect(xarray(), builder = function(xr) {
  xr$open_dataset(f)$rename(list(pcp = "precip"))
})
dbListTables(con)

## many files as one dataset (open_mfdataset needs dask)
reticulate::py_require("dask")
files <- c(f, f)  # e.g. a daily series of files on one grid
con <- dbConnect(xarray(), builder = function(xr) {
  xr$open_mfdataset(files, combine = "nested", concat_dim = "run")
})

## an object already built in the session
reticulate::py_run_string("import xarray; myds = xarray.Dataset()")
con <- dbConnect(xarray(), object = reticulate::py_eval("myds", convert = FALSE))
} # }
```
