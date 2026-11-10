#!/usr/bin/env bash
# Lane B gate for src/imkit/av1ipred.mojo: hand-computed blocks + oracle vectors from tools/av1ipred_oracle.py.
set -euo pipefail
cd "$(dirname "$0")/.."
M=${MOJO:-.venv/bin/mojo}; W=.work/av1ipred
mkdir -p $W; rm -f $W/ipred_test
systemd-run --user --scope -q -p MemoryMax=8G -p MemorySwapMax=0 -- timeout 300 "$M" build -I src tests/av1ipred_test.mojo -o $W/ipred_test 2> $W/ipred_test.log \
  || { grep -A6 -m3 error $W/ipred_test.log | cut -c1-240; echo "FAIL build: av1ipred_test"; exit 1; }
systemd-run --user --scope -q -p MemoryMax=8G -p MemorySwapMax=0 -- timeout 120 $W/ipred_test || { echo "FAIL av1ipred: see above"; exit 1; }
[ "${MUTANTS:-1}" = 0 ] && { echo "PASS av1ipred"; exit 0; }
# each line: description | sed expression applied to av1ipred.mojo. Every mutant must make the test FAIL.
mutants=(
  "smooth Round2 9 -> 8|s/pred\[i \* w + j\] = Int(round2(s, 9))/pred[i * w + j] = Int(round2(s, 8))/"
  "paeth tie top <= corner -> <|s/elif p_top <= p_tl:/elif p_top < p_tl:/"
  "corner filter weight 6 -> 5|s/above\[OFF - 1\] \* 6/above[OFF - 1] * 5/"
  "edge filter rounding (s + 8) >> 4 -> s >> 4|s/buf\[OFF + i - 1\] = (s + 8) >> 4/buf[OFF + i - 1] = s >> 4/"
  "upsample tap 9 -> 8|s/-dup\[i\] + 9 \* dup\[i + 1\]/-dup[i] + 8 * dup[i + 1]/"
  "shift ignores upsample|s/var shift = ((idx << up_above) >> 1) \& 0x1F/var shift = (idx >> 1) \& 0x1F/"
  "maxBaseX (w + h - 1) -> (w + h)|s/var max_base_x = (w + h - 1) << up_above/var max_base_x = (w + h) << up_above/"
  "above-right limit ignored|s/x + (2 \* w if have_above_rt else w) - 1/x + w - 1/"
  "below-left limit ignored|s/y + (2 \* h if have_below_lft else h) - 1/y + h - 1/"
  "above edge numPx without the +1|s/(h if p_angle < 90 else 0) + 1$/(h if p_angle < 90 else 0)/"
  "strength threshold 56 -> 54|s/if d >= 56:/if d >= 54:/"
  "filter intra scale bits 4 -> 3|s/^comptime INTRA_FILTER_SCALE_BITS = 4/comptime INTRA_FILTER_SCALE_BITS = 3/"
  "DC rounding term dropped|s/            sum += (w + h) >> 1/            sum += 0/"
  "no-left LeftCol base +1 -> -1|s/left\[OFF + i\] = (1 << (bd - 1)) + 1/left[OFF + i] = (1 << (bd - 1)) - 1/"
  "cfl luma scale 3 -> 2|s/var v = t << (3 - sx - sy)/var v = t << (2 - sx - sy)/"
  "cfl luma clamp dropped|s/var lx = min((start_x + j) << sx, mw - (1 << sx))/var lx = (start_x + j) << sx/"
  "cfl Round2Signed 6 -> 5|s/var scaled = Int(round2(m, 6)) if m >= 0/var scaled = Int(round2(m, 5)) if m >= 0/"
  "zone 2 left branch uses j not j + 1|s/idx = (i << 6) - (j + 1) \* dy/idx = (i << 6) - j * dy/"
  "upsample ignores filter type|s/if use_upsample(w, h, ft, p_angle - 90):/if use_upsample(w, h, 0, p_angle - 90):/"
  "upsample sample not clipped|s/clip3(0, maxv, Int(round2(s, 4)))/Int(round2(s, 4))/"
  "corner filter at w + h > 24|s/and w + h >= 24:/and w + h > 24:/"
)
fails=0
for m in "${mutants[@]}"; do
  d=${m%%|*}; e=${m#*|}
  rm -rf $W/mut; cp -r src $W/mut
  sed -i "$e" $W/mut/imkit/av1ipred.mojo
  if cmp -s src/imkit/av1ipred.mojo $W/mut/imkit/av1ipred.mojo; then echo "FAIL mutant did not apply: $d"; fails=$((fails + 1)); continue; fi
  rm -f $W/mtest
  timeout 300 "$M" build -I $W/mut -I src tests/av1ipred_test.mojo -o $W/mtest 2> $W/mtest.log || { echo "FAIL mutant build: $d"; grep -m2 error $W/mtest.log | cut -c1-200; fails=$((fails + 1)); continue; }
  if timeout 120 $W/mtest > $W/mtest.out 2>&1; then echo "FAIL mutant survived: $d"; fails=$((fails + 1)); else echo "killed  $d ($(grep -m1 '^FAIL' $W/mtest.out | cut -c1-80))"; fi
done
[ $fails = 0 ] && echo "PASS av1ipred + mutants ${#mutants[@]}/${#mutants[@]}" || { echo "FAIL av1ipred mutants: $fails"; exit 1; }
