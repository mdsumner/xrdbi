#!/bin/sh
# Knit README.Rmd live in the gdal-r-python image, the reference
# environment, so the outputs come from the remote data. Run from the
# package root. The tracked files (with any uncommitted edits) are copied
# to a temporary directory and knitted there; README.md and
# man/figures/README-* are copied back.
set -e
img=${XRDBI_IMAGE:-ghcr.io/hypertidy/gdal-r-python:latest}
work=$(mktemp -d)
git ls-files | tar -cf - -T - | tar -xf - -C "$work"
rm -f "$work"/man/figures/README-*   # figures come only from this knit

docker run --rm -e DASK_ARRAY__QUERY_PLANNING=False \
  -v "$work":/work -w /work "$img" sh -c '
    set -e
    uv pip install -q --python "$RETICULATE_PYTHON" gcsfs
    PKG_SYSREQS=false Rscript -e "pak::local_install_deps(upgrade = FALSE, ask = FALSE)"
    R CMD INSTALL --no-test-load . > /dev/null
    Rscript -e "rmarkdown::render(\"README.Rmd\",
      output_format = rmarkdown::github_document(html_preview = FALSE),
      envir = new.env())"
    chown -R '"$(id -u):$(id -g)"' /work'

rm -f man/figures/README-*
cp "$work"/README.md .
cp "$work"/man/figures/README-* man/figures/
rm -rf "$work"
