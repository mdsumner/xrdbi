# Package index

## Overview

- [`xrdbi`](https://mdsumner.github.io/xrdbi/reference/xrdbi-package.md)
  [`xrdbi-package`](https://mdsumner.github.io/xrdbi/reference/xrdbi-package.md)
  : xrdbi: 'DBI' Backend for 'xarray' via a Live 'reticulate' Session

## Connect

Open a connection to an xarray Dataset and look around it, its variables
and grids.

- [`xarray()`](https://mdsumner.github.io/xrdbi/reference/xarray.md)
  [`show(`*`<XarrayDriver>`*`)`](https://mdsumner.github.io/xrdbi/reference/xarray.md)
  [`dbUnloadDriver(`*`<XarrayDriver>`*`)`](https://mdsumner.github.io/xrdbi/reference/xarray.md)
  [`dbDataType(`*`<XarrayDriver>`*`)`](https://mdsumner.github.io/xrdbi/reference/xarray.md)
  : xarray DBI driver
- [`dbConnect(`*`<XarrayDriver>`*`)`](https://mdsumner.github.io/xrdbi/reference/dbConnect-XarrayDriver-method.md)
  : Connect to an xarray object
- [`show(`*`<XarrayConnection>`*`)`](https://mdsumner.github.io/xrdbi/reference/XarrayConnection-class.md)
  [`dbIsValid(`*`<XarrayConnection>`*`)`](https://mdsumner.github.io/xrdbi/reference/XarrayConnection-class.md)
  [`dbDisconnect(`*`<XarrayConnection>`*`)`](https://mdsumner.github.io/xrdbi/reference/XarrayConnection-class.md)
  [`dbGetInfo(`*`<XarrayConnection>`*`)`](https://mdsumner.github.io/xrdbi/reference/XarrayConnection-class.md)
  [`dbListTables(`*`<XarrayConnection>`*`)`](https://mdsumner.github.io/xrdbi/reference/XarrayConnection-class.md)
  [`dbExistsTable(`*`<XarrayConnection>`*`,`*`<character>`*`)`](https://mdsumner.github.io/xrdbi/reference/XarrayConnection-class.md)
  [`dbListFields(`*`<XarrayConnection>`*`,`*`<character>`*`)`](https://mdsumner.github.io/xrdbi/reference/XarrayConnection-class.md)
  [`dbBegin(`*`<XarrayConnection>`*`)`](https://mdsumner.github.io/xrdbi/reference/XarrayConnection-class.md)
  [`dbCommit(`*`<XarrayConnection>`*`)`](https://mdsumner.github.io/xrdbi/reference/XarrayConnection-class.md)
  [`dbRollback(`*`<XarrayConnection>`*`)`](https://mdsumner.github.io/xrdbi/reference/XarrayConnection-class.md)
  [`dbDataType(`*`<XarrayConnection>`*`)`](https://mdsumner.github.io/xrdbi/reference/XarrayConnection-class.md)
  [`dbQuoteIdentifier(`*`<XarrayConnection>`*`,`*`<character>`*`)`](https://mdsumner.github.io/xrdbi/reference/XarrayConnection-class.md)
  [`dbQuoteString(`*`<XarrayConnection>`*`,`*`<character>`*`)`](https://mdsumner.github.io/xrdbi/reference/XarrayConnection-class.md)
  : Xarray connection
- [`xr_grids()`](https://mdsumner.github.io/xrdbi/reference/xr_grids.md)
  : List the grids of a Dataset

## Query

Python statements, compiled selections, dplyr verbs, and whole
variables.

- [`dbSendQuery(`*`<XarrayConnection>`*`,`*`<character>`*`)`](https://mdsumner.github.io/xrdbi/reference/XarrayResult-class.md)
  [`dbBind(`*`<XarrayResult>`*`)`](https://mdsumner.github.io/xrdbi/reference/XarrayResult-class.md)
  [`show(`*`<XarrayResult>`*`)`](https://mdsumner.github.io/xrdbi/reference/XarrayResult-class.md)
  [`dbIsValid(`*`<XarrayResult>`*`)`](https://mdsumner.github.io/xrdbi/reference/XarrayResult-class.md)
  [`dbGetStatement(`*`<XarrayResult>`*`)`](https://mdsumner.github.io/xrdbi/reference/XarrayResult-class.md)
  [`dbFetch(`*`<XarrayResult>`*`)`](https://mdsumner.github.io/xrdbi/reference/XarrayResult-class.md)
  [`dbHasCompleted(`*`<XarrayResult>`*`)`](https://mdsumner.github.io/xrdbi/reference/XarrayResult-class.md)
  [`dbGetRowCount(`*`<XarrayResult>`*`)`](https://mdsumner.github.io/xrdbi/reference/XarrayResult-class.md)
  [`dbClearResult(`*`<XarrayResult>`*`)`](https://mdsumner.github.io/xrdbi/reference/XarrayResult-class.md)
  : Xarray result
- [`xr_query()`](https://mdsumner.github.io/xrdbi/reference/xr_query.md)
  : Compile a structured selection to a Python expression
- [`tbl(`*`<XarrayConnection>`*`)`](https://mdsumner.github.io/xrdbi/reference/tbl_xarray.md)
  : A lazy dplyr table over an xarray variable or grid
- [`dbReadTable(`*`<XarrayConnection>`*`,`*`<character>`*`)`](https://mdsumner.github.io/xrdbi/reference/dbReadTable-XarrayConnection-character-method.md)
  : Read a variable as a tidy data frame

## Render other ways

A slab as an in-memory raster, and the storage chunks under a selection.

- [`xr_raster()`](https://mdsumner.github.io/xrdbi/reference/xr_raster.md)
  : Render a result in gdalraster's in-memory raster format
- [`xr_chunks()`](https://mdsumner.github.io/xrdbi/reference/xr_chunks.md)
  : Map the chunks a selection touches

## Python objects

- [`xr_dataset()`](https://mdsumner.github.io/xrdbi/reference/xr_dataset.md)
  [`xr_module()`](https://mdsumner.github.io/xrdbi/reference/xr_dataset.md)
  : Drop to the underlying Python objects
