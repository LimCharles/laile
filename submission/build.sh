#!/bin/sh
# Builds the submission PDFs (needs Tectonic: brew install tectonic). macOS fonts are used.
set -e
cd "$(dirname "$0")"
(cd diagram && tectonic architecture.tex)
(cd writeup && tectonic laile-description.tex)
(cd slides && tectonic laile-deck.tex)
