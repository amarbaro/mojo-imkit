#!/usr/bin/env bash
# Lane B gate for src/imkit/av1recon.mojo: hand-computed exact cases + float oracle over all sizes and tx types.
set -euo pipefail
cd "$(dirname "$0")/.."
M=${MOJO:-.venv/bin/mojo}; W=.work/av1recon
mkdir -p $W; rm -f $W/recon_test
systemd-run --user --scope -q -p MemoryMax=8G -p MemorySwapMax=0 -- timeout 300 "$M" build -I src tests/av1recon_test.mojo -o $W/recon_test 2> $W/recon_test.log \
  || { grep -A6 -m3 error $W/recon_test.log | cut -c1-240; echo "FAIL build: av1recon_test"; exit 1; }
systemd-run --user --scope -q -p MemoryMax=8G -p MemorySwapMax=0 -- timeout 120 $W/recon_test || { echo "FAIL av1recon: see above"; exit 1; }
[ "${MUTANTS:-1}" = 0 ] && { echo "PASS av1recon"; exit 0; }
# each line: description | sed expression applied to av1recon.mojo. Every mutant must make the test FAIL.
mutants=(
  "DCT step 12 flip 1-i -> i|s/butterfly(t, 2 \* i, 2 \* i + 1, 32 + 16 \* i, 1 - i, r, tables)/butterfly(t, 2 * i, 2 * i + 1, 32 + 16 * i, i, r, tables)/"
  "column shift 4 -> 3|s/var col_shift = 0 if lossless else 4/var col_shift = 0 if lossless else 3/"
  "2:1 rect scaling only one way|s/if diff == 1 or diff == -1:/if diff == 1:/"
  "ADST output sign flipped|s/t\[i\] = -copy\[idx\] if (i \& 1) != 0 else copy\[idx\]/t[i] = -copy[idx] if (i \& 1) == 0 else copy[idx]/"
  "FLIPADST_FLIPADST not flipped LR|s/or tx_type == H_FLIPADST or tx_type == FLIPADST_FLIPADST/or tx_type == H_FLIPADST/"
  "dqDenom 4 -> 2|s/dq_denom = 4/dq_denom = 2/"
  "mask 0xFFFFFF -> 0xFFFFFFF|s/\& 0xFFFFFF$/\& 0xFFFFFFF/"
  "ADST4 s3 = s1|s/    s\[3\] = s\[2\]$/    s[3] = s[1]/"
  "ADST8/16 last butterfly angle 32 -> 33|s/butterfly(t, 2 + 4 \* i, 3 + 4 \* i, 32, 1, r, tables)/butterfly(t, 2 + 4 * i, 3 + 4 * i, 33, 1, r, tables)/"
  "DCT64 step 25 angle|s/var ang = 48 if i < 4 else 112/var ang = 48 if i < 4 else 48/"
  "identity16 11586 -> 11585|s/11586/11585/"
  "quantizer matrix Round2 5 -> 4|s/tw + j\]), 5)/tw + j]), 4)/"
  "WHT row shift 2 -> 1|s/inverse_wht(t, 2)/inverse_wht(t, 1)/"
  "plane type of quantizer matrix|s/(1 if plane > 0 else 0)/0/"
  "Transform_Row_Shift ignored|s/else Int(tables.transform_row_shift\[tx_size\])/else 1/"
  "DCT8 step 8 angle|s/butterfly(t, 4 + i, 7 - i, 56 - 32 \* i, 0, r, tables)/butterfly(t, 4 + i, 7 - i, 56 - 31 * i, 0, r, tables)/"
  "row clamp between stages dropped|s/clip3_64(col_lo, col_hi, round2(t\[j\], row_shift))/round2(t[j], row_shift)/"
)
fails=0
for m in "${mutants[@]}"; do
  d=${m%%|*}; e=${m#*|}
  rm -rf $W/mut; cp -r src $W/mut
  sed -i "$e" $W/mut/imkit/av1recon.mojo
  if cmp -s src/imkit/av1recon.mojo $W/mut/imkit/av1recon.mojo; then echo "FAIL mutant did not apply: $d"; fails=$((fails + 1)); continue; fi
  rm -f $W/mtest
  timeout 300 "$M" build -I $W/mut -I src tests/av1recon_test.mojo -o $W/mtest 2> $W/mtest.log || { echo "FAIL mutant build: $d"; grep -m2 error $W/mtest.log | cut -c1-200; fails=$((fails + 1)); continue; }
  if timeout 120 $W/mtest > $W/mtest.out 2>&1; then echo "FAIL mutant survived: $d"; fails=$((fails + 1)); else echo "killed  $d ($(grep -m1 '^FAIL' $W/mtest.out | cut -c1-80))"; fi
done
[ $fails = 0 ] && echo "PASS av1recon + mutants ${#mutants[@]}/${#mutants[@]}" || { echo "FAIL av1recon mutants: $fails"; exit 1; }
