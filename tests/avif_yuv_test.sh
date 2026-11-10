#!/usr/bin/env bash
# Stage 5 to 7 gate: every fixture decodes to planes equal to avifdec's y4m output, sample for sample (raw .obu fixtures are
# compared with dav1d's y4m). Exact by design: the decoder repeats the spec's integer processes.
set -euo pipefail
cd "$(dirname "$0")/.."
F=.work/avif; M=${MOJO:-.venv/bin/mojo}; W=.work/avifyuv; mkdir -p $W
timeout 600 "$M" build -I src tests/avif_yuv_test.mojo -o $W/test 2> $W/build.log || { grep -A6 -m3 error $W/build.log | cut -c1-240; echo "FAIL build: tests/avif_yuv_test.mojo"; exit 1; }
fails=0
for f in $F/*.avif $F/*.obu; do
  b=$(basename "$f"); ref=$W/$b.y4m
  if [ ! -f "$ref" ]; then
    case $f in *.obu) timeout 60 dav1d -q -i "$f" -o "$ref" ;; *) timeout 60 avifdec "$f" "$ref" > /dev/null ;; esac || { echo "FAIL reference: $b"; fails=$((fails + 1)); continue; }
  fi
  if timeout 60 $W/test "$f" "$ref" > $W/$b.out 2>&1; then echo "ok   $b"; else echo "FAIL $b: $(grep -E 'plane|FAIL|rror' $W/$b.out | tr '\n' ' ' | cut -c1-200)"; fails=$((fails + 1)); fi
done
[ $fails = 0 ] && echo "PASS avif_yuv" || { echo "FAIL avif_yuv: $fails files"; exit 1; }
