#!/usr/bin/env bash
# Lane C gate: hand-computed checks of the loop filter, CDEF and loop restoration (tests/av1filter_test.mojo).
set -euo pipefail
cd "$(dirname "$0")/.."
M=${MOJO:-.venv/bin/mojo}; W=.work/av1f; mkdir -p $W; rm -f $W/test
systemd-run --user --scope -q -p MemoryMax=8G -p MemorySwapMax=0 -- timeout 300 "$M" build -I src tests/av1filter_test.mojo -o $W/test 2> $W/build.log || { grep -A6 -m3 error $W/build.log | cut -c1-240; echo "FAIL build: tests/av1filter_test.mojo"; exit 1; }
out=$(timeout 60 $W/test) || { echo "$out"; echo "FAIL run: tests/av1filter_test"; exit 1; }
echo "$out"
echo "$out" | grep -q '^PASS av1filter' || { echo "FAIL av1filter: no PASS line"; exit 1; }
