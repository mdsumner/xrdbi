# conda-forge recipe for r-xrdbi (draft)

`recipe.yaml` (rattler-build v1 format) is ready for
conda-forge/staged-recipes once xrdbi is on CRAN: set `version` and the
`sha256` of the CRAN tarball. The activation scripts and `run_test.R`
travel with it. This folder is excluded from the R package build.

## Why it looks like this

Each of these was found by testing, not assumed.

1. **Activation sets `RETICULATE_PYTHON`.** reticulate does not look at an
   activated conda environment (its discovery honours `VIRTUAL_ENV`, not
   `CONDA_PREFIX`), and with requirements declared by `py_require()` it
   provisions its own environment from PyPI instead, where gdalxarray
   cannot work. `activate.sh`/`.bat` point `RETICULATE_PYTHON` at the
   environment's Python unless the user already set one, and the
   deactivate scripts undo only what they set.
2. **`libpython` is a run requirement.** reticulate embeds Python through
   the shared libpython, which conda-forge ships as its own package; a
   solve to Python 3.15 without it left reticulate with "Python shared
   library not found".
3. **`micromamba` is a run requirement.** For a Python in a conda-layout
   environment (a `conda-meta` folder), reticulate runs `conda run` once
   to learn the activated `PATH`, and fails with "Unable to find conda
   binary" when no conda, mamba or micromamba is on `PATH` or in its
   usual places. That is the case in pixi environments and build
   sandboxes; with it, reticulate falls back to provisioning from PyPI.
   micromamba in the environment gives it one. (This is upstream
   reticulate behaviour, worth raising there: an already-activated
   environment needs no `conda run`.)

## Validate locally

Build from the working tree instead of the CRAN tarball, in a scratch
directory:

```sh
mkdir -p /tmp/rb/recipe && cp tools/conda/* /tmp/rb/recipe/
# in /tmp/rb/recipe/recipe.yaml replace the source block with
#   source:
#     path: /path/to/xrdbi
# and set version to the DESCRIPTION version, then
cd /tmp/rb && pixi exec rattler-build build --recipe recipe/recipe.yaml \
  --output-dir out -c conda-forge
```

`run_test.R` checks that reticulate uses the environment's Python, that
the netcdf4 and gdalxarray engines are there, and that a query runs.
