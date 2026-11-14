# Xarray connection

Tables are variables (data variables and coordinates alike). Fields are
dimensions, then non-dimension coordinates, then the variable itself.
The Python object is reachable at any time via
[`xr_dataset()`](https://mdsumner.github.io/xrdbi/reference/xr_dataset.md);
this connection is a veneer, not a jail. Create one with
[dbConnect()](https://mdsumner.github.io/xrdbi/reference/dbConnect-XarrayDriver-method.md);
queries are documented with
[XarrayResult](https://mdsumner.github.io/xrdbi/reference/XarrayResult-class.md),
whole variables with
[dbReadTable()](https://mdsumner.github.io/xrdbi/reference/dbReadTable-XarrayConnection-character-method.md).

## Usage

``` r
# S4 method for class 'XarrayConnection'
show(object)

# S4 method for class 'XarrayConnection'
dbIsValid(dbObj, ...)

# S4 method for class 'XarrayConnection'
dbDisconnect(conn, ...)

# S4 method for class 'XarrayConnection'
dbGetInfo(dbObj, ...)

# S4 method for class 'XarrayConnection'
dbListTables(conn, ...)

# S4 method for class 'XarrayConnection,character'
dbExistsTable(conn, name, ...)

# S4 method for class 'XarrayConnection,character'
dbListFields(conn, name, ...)

# S4 method for class 'XarrayConnection'
dbBegin(conn, ...)

# S4 method for class 'XarrayConnection'
dbCommit(conn, ...)

# S4 method for class 'XarrayConnection'
dbRollback(conn, ...)

# S4 method for class 'XarrayConnection'
dbDataType(dbObj, obj, ...)

# S4 method for class 'XarrayConnection,character'
dbQuoteIdentifier(conn, x, ...)

# S4 method for class 'XarrayConnection,character'
dbQuoteString(conn, x, ...)
```

## Arguments

- object, dbObj, conn:

  an XarrayConnection

- ...:

  unused

- name:

  a variable name

- obj:

  an R object, for
  [`dbDataType()`](https://dbi.r-dbi.org/reference/dbDataType.html)

- x:

  character vector to quote

## Value

- [`show()`](https://rdrr.io/r/methods/show.html): called for its output
  (source, dims, data variables)

- [`dbIsValid()`](https://dbi.r-dbi.org/reference/dbIsValid.html):
  `TRUE` while the connection is open

- [`dbDisconnect()`](https://dbi.r-dbi.org/reference/dbDisconnect.html):
  `TRUE`, invisibly

- [`dbGetInfo()`](https://dbi.r-dbi.org/reference/dbGetInfo.html): a
  list with `dbname`, `db.version` (the xarray version), `tables` (data
  variables) and `sizes` (dims)

- [`dbListTables()`](https://dbi.r-dbi.org/reference/dbListTables.html):
  character, every variable (coordinates included)

- [`dbExistsTable()`](https://dbi.r-dbi.org/reference/dbExistsTable.html):
  logical

- [`dbListFields()`](https://dbi.r-dbi.org/reference/dbListFields.html):
  character, dims, then non-dimension coordinates, then the variable

- [`dbDataType()`](https://dbi.r-dbi.org/reference/dbDataType.html):
  character, the numpy dtype an R vector maps to

- [`dbQuoteIdentifier()`](https://dbi.r-dbi.org/reference/dbQuoteIdentifier.html),
  [`dbQuoteString()`](https://dbi.r-dbi.org/reference/dbQuoteString.html):
  [`DBI::SQL()`](https://dbi.r-dbi.org/reference/SQL.html) holding
  Python source (`ds['name']`, `'text'`)

- [`dbBegin()`](https://dbi.r-dbi.org/reference/transactions.html),
  [`dbCommit()`](https://dbi.r-dbi.org/reference/transactions.html),
  [`dbRollback()`](https://dbi.r-dbi.org/reference/transactions.html):
  no return, they error

## Details

Transactions
([`dbBegin()`](https://dbi.r-dbi.org/reference/transactions.html),
[`dbCommit()`](https://dbi.r-dbi.org/reference/transactions.html),
[`dbRollback()`](https://dbi.r-dbi.org/reference/transactions.html)) are
not implemented and error; the intended mapping is icechunk sessions and
commits.

## Slots

- `ptr`:

  environment holding the Python handles (xr module, ds object)

- `dsn`:

  the source string if the connection was opened from one

## See also

[dbConnect()](https://mdsumner.github.io/xrdbi/reference/dbConnect-XarrayDriver-method.md)
to open one;
[XarrayResult](https://mdsumner.github.io/xrdbi/reference/XarrayResult-class.md)
for queries;
[`xr_dataset()`](https://mdsumner.github.io/xrdbi/reference/xr_dataset.md)
for the Python object;
[xrdbi-package](https://mdsumner.github.io/xrdbi/reference/xrdbi-package.md)
for an overview.

## Examples

``` r
if (FALSE) { # \dontrun{
## needs a Python environment with xarray (see ?xrdbi)
f <- system.file("extdata/autotest/trmm.nc", package = "xrdbi")
con <- dbConnect(xarray(), f)
con
dbListTables(con)       # every variable, coordinates included
dbGetInfo(con)$tables   # the data variables
dbListFields(con, "pcp")
dbGetInfo(con)$sizes
dbDisconnect(con)
} # }
```
