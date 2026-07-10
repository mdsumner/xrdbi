#' @keywords internal
"_PACKAGE"

## usethis namespace: start
## usethis namespace: end
NULL

## Package-level imports: roxygen builds NAMESPACE from these tags, so
## every generic we register an S3 method on (tbl, filter, select,
## collect, show_query, head) must be imported here or roxygen emits a
## plain export() instead of S3method() and dispatch silently breaks.
#' @import DBI
#' @import methods
#' @importFrom reticulate import import_builtins py_to_r r_to_py
#' @importFrom reticulate py_get_item py_dict py_run_string py_eval
#' @importFrom reticulate py_call py_module_available py_is_null_xptr
#' @importFrom dplyr tbl filter select collect show_query
#' @importFrom utils head
NULL
