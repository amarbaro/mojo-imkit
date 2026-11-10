#!/usr/bin/env bash
# CPU cost of the demo UI frame (build + finish), tools/uibench.mojo, 3 runs. No reference library: absolute numbers.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .work
.venv/bin/mojo build -O3 -I src tools/uibench.mojo -o .work/uibench 2>.work/uibench-build.err || { echo "FAIL build: tools/uibench.mojo"; cat .work/uibench-build.err; exit 1; }
for i in 1 2 3; do o=$(.work/uibench) || { echo "FAIL run: $i"; exit 1; }; echo "run $i: $o"; done
