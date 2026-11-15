#' List the grids of a Dataset
#'
#' A grid is the set of variables that share one set of dimensions, as
#' tidync's grids are: ERA5's 273 variables are two grids, a surface grid
#' over `(time, latitude, longitude)` and a pressure-level grid over
#' `(time, level, latitude, longitude)`. Each grid can be read as one
#' table, with a column per member: give [tbl()][tbl_xarray] its name, or
#' several of its variables. xarray has no grid object; this listing
#' groups the variables by their dimensions. Only metadata is read.
#'
#' Two views:
#' * `"meaning"` (the default) groups data variables by their dimensions
#'   as xarray decodes them, taken as a set (`(lat, lon)` and `(lon, lat)`
#'   are one grid), and lists the coordinates that belong to each grid.
#'   These are the grids a table can be built over.
#' * `"storage"` groups every stored array, coordinates included, by its
#'   dimensions as stored, in order. A character array that xarray
#'   decodes to strings keeps its character dimension
#'   (`encoding["char_dim_name"]`), so a netCDF file lists the grids
#'   tidync (through ncmeta) finds: 16 in an Argo profile file where the
#'   meaning view has 5.
#'
#' @param con an XarrayConnection
#' @param view `"meaning"` or `"storage"`, see Details
#' @return a tibble, one row per grid, most dimensions first, then most
#'   variables: `grid`, its dimensions joined by commas (the name
#'   [tbl()][tbl_xarray] takes); `ndims`; `cells`, the product of the
#'   dimension sizes (`NA` in the storage view for a grid whose arrays
#'   store a character dimension); `n`, the number of variables; the
#'   list column `variables`; and `chunkings`, the number of distinct
#'   storage chunk shapes among them (a grid whose members share a key
#'   space has 1). The meaning view adds the list column `coords`, the
#'   coordinates whose dimensions lie within the grid; the storage view
#'   adds `roles`, how many of the arrays are data variables,
#'   coordinates and dimension coordinates.
#' @seealso [tbl()][tbl_xarray] to read a grid as a table;
#'   [xr_chunks()] for its chunk map; [xrdbi-package] for an overview.
#' @examples
#' \dontrun{
#' ## needs a Python environment with xarray (see ?xrdbi)
#' f <- system.file("extdata/autotest/two_vars_scale_offset.nc",
#'                  package = "xrdbi")
#' con <- dbConnect(xarray(), f)
#' xr_grids(con)
#' xr_grids(con, "storage")
#' dbDisconnect(con)
#' }
#' @export
xr_grids <- function(con, view = c("meaning", "storage")) {
  view <- match.arg(view)
  m <- grid_members(con)
  if (view == "meaning") {
    aux <- m[m$role == "coordinate", ]
    m <- m[m$role == "data", ]
  }
  key <- if (view == "meaning") m$meaning_grid else m$storage_grid
  parts <- split(seq_len(nrow(m)), factor(key, unique(key)))
  out <- lapply(names(parts), function(g) {
    i <- parts[[g]]
    dims <- if (view == "meaning") m$dims[[i[1L]]] else m$stored_dims[[i[1L]]]
    shape <- m$shape[[i[1L]]]
    row <- dplyr::tibble(
      grid = g,
      ndims = length(dims),
      cells = if (view == "meaning" || length(dims) == length(shape))
        prod(shape) else NA_real_,
      n = length(i),
      variables = list(m$variable[i]),
      chunkings = length(unique(vapply(m$chunks[i], paste, "",
                                       collapse = ","))))
    if (view == "meaning") {
      ## the coordinates that belong to this grid: their dims lie within it
      row$coords <- list(aux$variable[vapply(aux$dims, function(d) {
        length(d) > 0L && all(d %in% dims)
      }, logical(1))])
    } else {
      tab <- table(factor(m$role[i], c("data", "coordinate", "dimension")))
      tab <- tab[tab > 0L]
      row$roles <- paste(names(tab), tab, sep = ":", collapse = " ")
    }
    row
  })
  if (!length(out)) {
    return(dplyr::tibble(grid = character(), ndims = integer(),
                         cells = numeric(), n = integer(),
                         variables = list(), chunkings = integer()))
  }
  out <- do.call(rbind, out)
  out[order(-out$ndims, -out$n), ]
}

## one row per array of the Dataset, coordinates included: its role, its
## dims as decoded and as stored, data types, chunk shape, and the names
## of its storage and meaning grids
grid_members <- function(con) {
  m <- py_to_r(con@ptr$members(conn_ds(con)))
  chr <- function(f) lapply(m, function(r) as.character(unlist(r[[f]])))
  dims <- chr("dims")
  stored <- chr("stored_dims")
  gname <- function(d) if (length(d)) paste(d, collapse = ",") else "()"
  ## a meaning grid is a set of axes: group on the set, and name it in the
  ## order of its first variable, (time, level, ...) rather than sorted
  set_key <- vapply(dims, function(d) gname(sort(d)), "")
  first <- match(set_key, set_key)
  dplyr::tibble(
    variable = vapply(m, `[[`, "", "variable"),
    role = vapply(m, `[[`, "", "role"),
    dims = dims,
    stored_dims = stored,
    shape = lapply(m, function(r) as.numeric(unlist(r$shape))),
    dtype = vapply(m, `[[`, "", "dtype"),
    stored_dtype = vapply(m, `[[`, "", "stored_dtype"),
    chunks = lapply(m, function(r) as.numeric(unlist(r$chunks))),
    storage_grid = vapply(stored, gname, ""),
    meaning_grid = vapply(dims[first], gname, "")
  )
}

## what tbl() makes of a `from` that is not one variable: several data
## variables on one grid, or a grid's name from xr_grids() (either view).
## Returns the members, the grid's (meaning) name and the table's fields
resolve_grid <- function(con, from) {
  m <- grid_members(con)
  data <- m[m$role == "data", ]
  if (length(from) > 1L) {
    unknown <- setdiff(from, m$variable)
    if (length(unknown)) {
      stop("no such variable(s): ", paste(unknown, collapse = ", "),
           "; see dbListTables()", call. = FALSE)
    }
    coord <- setdiff(from, data$variable)
    if (length(coord)) {
      stop("a grid table's members are data variables; ",
           paste(coord, collapse = ", "), " is a coordinate", call. = FALSE)
    }
    if (anyDuplicated(from)) {
      stop("a variable is named twice: ",
           paste(unique(from[duplicated(from)]), collapse = ", "), call. = FALSE)
    }
    members <- from
  } else if (from %in% data$meaning_grid) {
    members <- data$variable[data$meaning_grid == from]
  } else if (from %in% data$storage_grid) {
    members <- data$variable[data$storage_grid == from]
  } else {
    stop("no such variable or grid: ", from,
         "; see dbListTables() and xr_grids()", call. = FALSE)
  }
  g <- unique(data$meaning_grid[match(members, data$variable)])
  if (length(g) > 1L) {
    stop("these variables are on different grids (", paste(g, collapse = "; "),
         "); one table over both would repeat each value along the ",
         "dimensions its variable lacks", call. = FALSE)
  }
  ## fields: the grid's dims and coordinates, as for one member, then
  ## every member
  fields <- c(setdiff(dbListFields(con, members[[1L]]), members[[1L]]), members)
  ## a grid named in either view keeps that name; members are labelled
  ## with their meaning grid
  list(members = members, grid = if (length(from) == 1L) from else g,
       fields = fields)
}

xrdbi_members_py <- r"---(
def _xrdbi_members(ds):
    out = []
    for k, v in ds.variables.items():
        k = str(k)
        enc = v.encoding
        if k in ds.dims and v.dims == (k,):
            role = 'dimension'
        elif k in ds.coords:
            role = 'coordinate'
        else:
            role = 'data'
        dims = [str(d) for d in v.dims]
        stored = list(dims)
        if enc.get('char_dim_name'):
            # xarray decoded a character array to strings: the stored
            # array has one more dimension, the characters
            stored.append(str(enc['char_dim_name']))
        pc = enc.get('preferred_chunks') or {}
        if pc:
            chunks = [int(pc.get(d, v.sizes[d])) for d in v.dims]
        else:
            cs = enc.get('chunksizes') or enc.get('chunks')
            chunks = [int(c) for c in cs] if cs else []
        out.append({'variable': k, 'role': role, 'dims': dims,
                    'stored_dims': stored,
                    'shape': [float(v.sizes[d]) for d in v.dims],
                    'dtype': str(v.dtype),
                    'stored_dtype': str(enc.get('dtype', v.dtype)),
                    'chunks': chunks})
    return out
)---"
