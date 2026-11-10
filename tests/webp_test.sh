#!/usr/bin/env bash
# WebP decoder gate: fixtures (ImageMagick/libwebp as oracle), golden compare, mutants under a 10 s timeout, bench.
# usage: tests/webp_test.sh [golden|mutants|bench|all]    receipt: .work/webp_test.txt   (WEBP_REGEN=1 rebuilds the fixtures)
set -euo pipefail
cd "$(dirname "$0")/.."
mode=${1:-all}
M=.venv/bin/mojo
mkdir -p .work
if [ ! -d .work/webp ] || [ "${WEBP_REGEN:-0}" != 0 ]; then tests/webp_fixtures.sh; fi
rm -f .work/webp_test
$M build -I src tests/webp_test.mojo -o .work/webp_test 2>.work/build.err || { echo "FAIL build: tests/webp_test.mojo"; grep -A4 error .work/build.err | head -30; exit 1; }
run() { timeout "$1" .work/webp_test "$2" || { echo "FAIL webp_test $2: exit $? (124 is the timeout)"; return 1; }; }
{
  if [ "$mode" = golden ] || [ "$mode" = all ]; then run 120 golden; fi
  if [ "$mode" = mutants ] || [ "$mode" = all ]; then run 10 mutants; fi
  if [ "$mode" = bench ] || [ "$mode" = all ]; then run 60 bench; fi
} 2>&1 | tee .work/webp_test.txt
rc=${PIPESTATUS[0]}
echo "exit $rc  tree $(git rev-parse --short HEAD)+$(git diff HEAD -- src tests | sha1sum | cut -c1-8)" >> .work/webp_test.txt
exit "$rc"
