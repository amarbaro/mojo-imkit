#!/usr/bin/env bash
# Lane C gate for film grain: (1) RNG, scaling and synthesis checks of tests/av1grain_test.mojo, (2) film_grain_params() parsed from
# an aomenc --film-grain-test=1 stream equals what ffmpeg -bsf:v trace_headers reads, field for field.
set -euo pipefail
cd "$(dirname "$0")/.."
M=${MOJO:-.venv/bin/mojo}; W=.work/av1f; F=.work/avif/grain.obu; mkdir -p $W; rm -f $W/gtest
systemd-run --user --scope -q -p MemoryMax=8G -p MemorySwapMax=0 -- timeout 300 "$M" build -I src tests/av1grain_test.mojo -o $W/gtest 2> $W/gbuild.log || { grep -A6 -m3 error $W/gbuild.log | cut -c1-240; echo "FAIL build: tests/av1grain_test.mojo"; exit 1; }
out=$(timeout 60 $W/gtest) || { echo "$out"; echo "FAIL run: av1grain_test"; exit 1; }
echo "$out"; echo "$out" | grep -q '^PASS av1grain' || { echo "FAIL av1grain: synthesis checks"; exit 1; }
if [ ! -f $F ]; then timeout 120 aomenc --limit=1 --cpu-used=8 --film-grain-test=1 --obu -o $F .work/avif/src-320.y4m > /dev/null 2>&1 || { echo "FAIL fixture: aomenc"; exit 1; }; fi
timeout 60 ffmpeg -v debug -i $F -c copy -bsf:v trace_headers -f null - 2>&1 | grep trace_headers | sed 's/^\[trace_headers @ [0-9a-fx]*\] //' > $W/grain.trace
off=$(awk '/obu_size/ {split($0, a, " "); bits=length(a[3]); last=bits} /apply_grain/ {print $1 - 8 - last; exit}' $W/grain.trace)
[ -n "$off" ] || { echo "FAIL trace: no apply_grain in $F"; exit 1; }
awk '/apply_grain/ {on=1} on {i = index($0, " = "); v = (i ? substr($0, i + 3) : $NF); print $2 "=" v} /clip_to_restricted_range/ {exit}' $W/grain.trace > $W/grain.want
timeout 30 $W/gtest $F "$off" > $W/grain.got
if diff -q $W/grain.want $W/grain.got > /dev/null; then echo "PASS av1grain parse: $(wc -l < $W/grain.got) fields equal ffmpeg trace_headers"; else diff $W/grain.want $W/grain.got | head -10; echo "FAIL av1grain parse: fields differ from trace_headers"; exit 1; fi
