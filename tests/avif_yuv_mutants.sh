#!/usr/bin/env bash
# Proves the pixel gate sees what the tile gate cannot: bugs that never change a symbol (intrabc MV stack and magnitudes,
# loop restoration coefficients, dequantisation, glue) must make tests/avif_yuv_test.mojo FAIL on some fixture.
# REF_CAT_LEVEL is not a mutant: it shifts the nearest block of the stack as a whole and the two blocks sort apart, so no
# intrabc result changes (it only feeds the DRL contexts of inter frames). A line starting with ? is a mutant no fixture
# reaches yet (UNTESTED, listed, not a failure; a kill is reported as killed).
# line: file|description|sed expression. Parallel (MUT_JOBS, default 6), each mutant in its own dir.
set -euo pipefail
cd "$(dirname "$0")/.."
F=.work/avif; M=${MOJO:-.venv/bin/mojo}; W=.work/avifyuvmut; mkdir -p $W
FILES=${FILES:-"superres_big.obu superres16.obu superres11.obu y422.avif dlf.obu screen.avif big.avif odd.avif y420.avif y420_lr.avif y420_10.avif seg.obu grain.obu lossless.avif alpha.avif"}
mutants=(
  "av1intrabc|intrabc candidate weight 2 -> 1|s/add_ref_mv_candidate(ts, s, mv_row, mv_col, ln \\* 2)/add_ref_mv_candidate(ts, s, mv_row, mv_col, ln)/"
  "?av1intrabc|MV clamp border dropped|s/var border_r = MV_BORDER + bh \\* 8/var border_r = bh * 8/"
  "av1tile|mv class0 magnitude +1 dropped|s/mag = ((bit << 3) | (3 << 1) | 1) + 1/mag = ((bit << 3) | (3 << 1) | 1)/"
  "av1tile|inverse_recenter odd branch|s/return r - ((v + 1) >> 1)/return r - (v >> 1)/"
  "?av1tile|sgr xqd clip bound|s/v = clip3(mn, mx, (1 << SGRPROJ_PRJ_BITS) - ts.ref_sgr_xqd\\[plane \\* 2\\])/v = clip3(mn, mx + 1, (1 << SGRPROJ_PRJ_BITS) - ts.ref_sgr_xqd[plane * 2])/"
  "av1coef|golomb base 14 -> 13|s/ts.quant\\[pos\\] = x + 14/ts.quant[pos] = x + 13/"
  "av1state|intra set1 ADST_DCT / DCT_ADST swapped|s/TX_TYPE_INTRA_INV_SET1 = \\[9, 0, 10, 11, 3, 1, 2\\]/TX_TYPE_INTRA_INV_SET1 = [9, 0, 10, 11, 3, 2, 1]/"
  "av1state|MODE_TO_TXFM D45 and D135 swapped|s/MODE_TO_TXFM = \\[0, 1, 2, 0, 3,/MODE_TO_TXFM = [0, 1, 2, 3, 0,/"
  "?av1dec|CFL MaxLumaW ignored|s/b.cfl_alpha_u if plane == 1 else b.cfl_alpha_v, max_luma_w, max_luma_h)/b.cfl_alpha_u if plane == 1 else b.cfl_alpha_v)/"
  "av1dec|loop filter chroma levels swapped|s/f.loop_filter_level\\[2\\] = ts.frame.loop_filter_level2/f.loop_filter_level[2] = ts.frame.loop_filter_level3/"
  "av1dec|cdef uv secondary strength dropped|s/d.cdef_uv_sec_strength = ts.frame.cdef_uv_sec_strength.copy()//"
  "av1dec|lr wiener pass order|s/l.lr_wiener\\[p\\]\\[u \\* 6 + k\\] = ts.lr_wiener\\[s \\* 6 + k\\]/l.lr_wiener[p][u * 6 + k] = ts.lr_wiener[s * 6 + (k + 3) % 6]/"
  "av1dec|palette V uses U colours|s/Span(pal_u) if plane == 1 else Span(pal_v)/Span(pal_u)/"
  "av1dec|segment qm level ignored|s/lvl = ts.frame.qm_y if plane == 0/lvl = 15 if plane == 0/"
  "av1dec|superres: floor instead of truncating division|s/    return q if (a >= 0) == (b > 0) else -q/    return a \/\/ b/"
  "av1dec|superres filter offset 3 -> 2|s/var sxk = min(max(px_x + k - 3, 0), max_x)/var sxk = min(max(px_x + k - 2, 0), max_x)/"
  "av1tile|superres LR columns ignore SuperresDenom|s/var numerator = (MI_SIZE >> sx) \* ts.frame.superres_denom/var numerator = (MI_SIZE >> sx) * SUPERRES_NUM/"
  "av1dec|superres: LR source frame not upscaled|s/        pre = upscale(pre, tables, st.frame.width/        _ = upscale(pre, tables, st.frame.width/"
)
mut_one() {
  local i=$1 f=${2%%|*} rest=${2#*|}; local d=${rest%%|*} e=${rest#*|} md=$W/mut$i opt=0
  case $f in \?*) opt=1; f=${f#?};; esac
  rm -rf $md; mkdir -p $md; cp -r src $md/src
  sed -i "$e" $md/src/imkit/$f.mojo
  if cmp -s src/imkit/$f.mojo $md/src/imkit/$f.mojo; then echo "FAIL mutant did not apply: $d" > $md/result; return; fi
  if ! timeout 400 "$M" build -I $md/src tests/avif_yuv_test.mojo -o $md/test 2> $md/build.log; then echo "killed  $d (build error)" > $md/result; return; fi
  local why=""
  for f2 in $FILES; do
    local ref=$W/../avifyuv/$f2.y4m
    [ -f "$ref" ] || { echo "FAIL mutant run: no reference $ref (run tests/avif_yuv_test.sh first)" > $md/result; return; }
    if ! timeout 60 $md/test $F/$f2 $ref > $md/out 2>&1; then why=$f2; break; fi
  done
  if [ -z "$why" ] && [ $opt = 1 ]; then echo "UNTESTED no fixture reaches: $d" > $md/result; elif [ -z "$why" ]; then echo "FAIL mutant survived: $d" > $md/result; else echo "killed  $d ($why)" > $md/result; fi
}
[ -f .work/avifyuv/y420.avif.y4m ] || bash tests/avif_yuv_test.sh > /dev/null
i=0; for m in "${mutants[@]}"; do
  mut_one $i "$m" & i=$((i + 1))
  while [ "$(jobs -rp | wc -l)" -ge "${MUT_JOBS:-6}" ]; do wait -n || true; done
done; wait
mf=0; for ((k = 0; k < i; k++)); do cat $W/mut$k/result; grep -q '^FAIL' $W/mut$k/result && mf=$((mf + 1)); done
nu=$(cat $W/mut*/result | grep -c "^UNTESTED" || true)
[ $mf = 0 ] && echo "PASS avif_yuv mutants: $((i - nu)) killed, $nu untested of $i" || { echo "FAIL avif_yuv mutants: $mf of $i"; exit 1; }
