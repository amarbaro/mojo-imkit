#!/usr/bin/env bash
# Stage 4 gate (AV1 intra tile parse): tests/av1tile_info.mojo parses every tile of every fixture (primary and alpha items).
# Each tile must end its symbol decoder exactly at the tile end (exit_process, spec 8.2.4) with blocks covering every 4x4 unit.
# The feature totals show which syntax paths the fixtures reached; a path at 0 is printed as UNTESTED, never counted as passed.
# Fixtures: the six stage 1 files plus tests/avif_fixtures.sh (tiles, big, seg.obu). MUTANTS=0 skips the mutants.
set -euo pipefail
cd "$(dirname "$0")/.."
F=.work/avif; M=${MOJO:-.venv/bin/mojo}; W=.work/av1tile; mkdir -p $W
build() { timeout 300 "$M" build -I "$1" tests/av1tile_info.mojo -o "$2" 2> "$2.log" || { grep -A6 -m3 error "$2.log" | cut -c1-240; echo "FAIL build: $2"; exit 1; }; }
run_all() {  # $1 binary; prints per-tile lines to $2, returns the number of failing files; $3 = scratch file
  local fails=0 one=${3:-$W/one.out}; : > "$2"
  for f in $F/*.avif $F/*.obu; do
    if timeout 30 "$1" "$f" > $one 2>&1; then sed "s|^|$(basename $f) |" $one >> "$2"
    else echo "FAIL $(basename $f): $(grep -m1 -iE 'error|exception' $one | cut -c1-200)" >> "$2"; fails=$((fails + 1)); fi
  done
  return $fails
}
build src $W/info
if run_all $W/info $W/tiles.txt; then rc=0; else rc=$?; fi
cat $W/tiles.txt
for k in nonzero skip intrabc palette cfl filter_intra golomb vartx_split wiener sgrproj segmented; do
  n=$(awk -v k=$k '{for (i = 1; i < NF; i++) if ($i == k) s += $(i + 1)} END{print s + 0}' $W/tiles.txt)
  [ "$n" -gt 0 ] && echo "covered $k $n" || echo "UNTESTED $k: no fixture block reached it"
done
[ $rc = 0 ] || { echo "FAIL av1tile: $rc files"; exit 1; }
echo "PASS av1tile $(grep -c ' ok ' $W/tiles.txt) tiles"
[ "${MUTANTS:-1}" = 0 ] && exit 0
# each mutant of the parser must make some fixture FAIL (a symbol decoder that ends elsewhere, or a block cover gap).
# line: file|description|sed expression. Mutants build and run in parallel (MUT_JOBS, default 6), each in its own dir.
mutants=(
  "av1coef|all_zero ctx 1 -> 2|/top == 0 and left == 0/{n;s/return 1/return 2/}"
  "av1coef|coeff_br ctx col == 0 offset 7 -> 8|s/return mag + 7 if col == 0 else mag + 14/return mag + 8 if col == 0 else mag + 14/"
  "av1coef|dc_sign ctx 1 and 2 swapped|s/return 1 if dc_sign < 0 else (2 if dc_sign > 0 else 0)/return 2 if dc_sign < 0 else (1 if dc_sign > 0 else 0)/"
  "av1coef|golomb data bit count off by one|s/for _ in range(length - 1):/for _ in range(length - 2):/"
  "av1coef|eob extra bit shift off by one|s/eob_shift = max(0, eob_pt - 2) - 1 - i/eob_shift = max(0, eob_pt - 2) - 2 - i/"
  "av1coef|coeff_base pos offset 26 -> 25|s/return ctx + 26 + 5 \\* min(idx2, 2)/return ctx + 25 + 5 * min(idx2, 2)/"
  "av1state|CDF table swapped: skip reads skip_mode|s/self.skip = add_cdf(p, c.skip)/self.skip = add_cdf(p, c.skip_mode)/"
  "av1state|CDF table swapped: use_wiener reads use_sgrproj|s/self.use_wiener = add_cdf(p, c.use_wiener)/self.use_wiener = add_cdf(p, c.use_sgrproj)/"
  "av1state|intra tx set1 inverse table V_DCT/H_DCT swapped|s/TX_TYPE_INTRA_INV_SET1 = \\[9, 0, 10, 11, 3, 1, 2\\]/TX_TYPE_INTRA_INV_SET1 = [9, 0, 11, 10, 3, 1, 2]/"
  "av1state|palette color context table shifted|s/PALETTE_COLOR_CONTEXT = \\[-1, -1, 0, -1, -1, 4, 3, 2, 1\\]/PALETTE_COLOR_CONTEXT = [-1, -1, 0, -1, -1, 4, 3, 1, 2]/"
  "av1tile|partition ctx left/above weights swapped|s/var ctx = (2 if left else 0) + (1 if above else 0)/var ctx = (1 if left else 0) + (2 if above else 0)/"
  "av1tile|intra_frame_y_mode ctx order swapped|s/(above_mode \\* 5 + left_mode)/(left_mode * 5 + above_mode)/"
  "av1tile|palette cache above limit 64 -> 128|s/% 64) != 0/% 128) != 0/"
  "av1tile|txfm_split ctx drops left|s/+ above + left$/+ above/"
  "av1tile|mv component CDFs merge the two components|s/var cc = ctx \\* 2 + comp/var cc = ctx * 2/"
  "av1tile|mv_bit CDF ignores the bit index|s/(cc \\* 10 + i) \\* 3/(cc * 10) * 3/"
  "av1tile|cdef_idx bits +1|s/var v = ts.lit(ts.frame.cdef_bits)/var v = ts.lit(ts.frame.cdef_bits + 1)/"
  "av1tile|subexp bits k + i - 1 -> k + i|s/var b2 = k + i - 1 if i > 0 else k/var b2 = k + i if i > 0 else k/"
)
mut_one() {  # $1 index, $2 spec
  local i=$1 f=${2%%|*} rest=${2#*|}; local d=${rest%%|*} e=${rest#*|} md=$W/mut$i
  rm -rf $md; mkdir -p $md; cp -r src $md/src
  sed -i "$e" $md/src/imkit/$f.mojo
  if cmp -s src/imkit/$f.mojo $md/src/imkit/$f.mojo; then echo "FAIL mutant did not apply: $d" > $md/result; return; fi
  if ! timeout 300 "$M" build -I $md/src tests/av1tile_info.mojo -o $md/info 2> $md/build.log; then echo "killed  $d (build error)" > $md/result; return; fi
  if run_all $md/info $md/tiles.txt $md/one.out; then echo "FAIL mutant survived: $d" > $md/result; else echo "killed  $d ($(grep -m1 '^FAIL' $md/tiles.txt | cut -c1-80))" > $md/result; fi
}
i=0; for m in "${mutants[@]}"; do
  mut_one $i "$m" & i=$((i + 1))
  while [ "$(jobs -rp | wc -l)" -ge "${MUT_JOBS:-6}" ]; do wait -n || true; done
done; wait
mf=0; for ((k = 0; k < i; k++)); do cat $W/mut$k/result; grep -q '^FAIL' $W/mut$k/result && mf=$((mf + 1)); done
[ $mf = 0 ] && echo "PASS av1tile mutants $i/$i" || { echo "FAIL av1tile mutants: $mf of $i"; exit 1; }
