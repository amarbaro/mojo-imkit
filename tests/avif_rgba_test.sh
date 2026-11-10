#!/usr/bin/env bash
# avif_decode (YUV -> 8-bit RGBA) against avifdec's PNG on every AVIF fixture. avifdec converts through libyuv's fixed-point
# matrices and filters, ours is float, so the bar is a tolerance (8-bit files max 2 / mean 0.2, 10 and 12 bit max 3 / mean 0.65; measured: 4:4:4 / mono / lossless /
# identity exact, 8-bit 4:2:0 max 2, 10 / 12 bit max 3). The tolerance is proven by the mutants below: each one must break it.
# MUTANTS=0 skips them.
set -euo pipefail
cd "$(dirname "$0")/.."
F=.work/avif; M=${MOJO:-.venv/bin/mojo}; W=.work/avifrgba; mkdir -p $W
MAXD=${AVIF_RGBA_MAX:-3}; MEAN=${AVIF_RGBA_MEAN:-0.65}
refs() { for f in $F/*.avif; do b=$(basename $f); [ -f $W/$b.rgba ] && continue
  timeout 60 avifdec -d 8 $f $W/$b.png > /dev/null 2>&1 || { echo "FAIL reference: avifdec $b"; exit 1; }
  timeout 30 magick $W/$b.png -depth 8 RGBA:$W/$b.rgba || { echo "FAIL reference: magick $b"; exit 1; }
  avifdec --info $f 2>/dev/null | awk -F': ' '/Bit Depth/{print $2; exit}' > $W/$b.depth; done; }
run_all() {  # $1 binary; prints the first failing file, nothing when all pass
  for f in $F/*.avif; do b=$(basename $f)
    local mx=2 mn=0.2; [ "$(cat $W/$b.depth)" = 8 ] || { mx=$MAXD; mn=$MEAN; }
    timeout 60 $1 $f $W/$b.rgba $mx $mn > $W/one.out 2>&1 || { echo "$b: $(grep -m1 -E 'size|FAIL|rror' $W/one.out | cut -c1-120)"; return; }
  done; }
refs
timeout 600 "$M" build -I src tests/avif_rgba_test.mojo -o $W/test 2> $W/build.log || { grep -A6 -m3 error $W/build.log | cut -c1-240; echo "FAIL build: tests/avif_rgba_test.mojo"; exit 1; }
bad=$(run_all $W/test)
[ -z "$bad" ] || { echo "FAIL avif_rgba: $bad"; exit 1; }
echo "PASS avif_rgba $(ls $F/*.avif | wc -l) files (8-bit max 2 mean 0.2, high bit max $MAXD mean $MEAN)"
[ "${MUTANTS:-1}" = 0 ] && exit 0
mutants=(
  "U and V swapped|s/var u = chroma_at(f.planes\[1\]/var u = chroma_at(f.planes[2]/"
  "BT.601 decoded as BT.709|s/    if matrix == 2 or matrix == 5 or matrix == 6:\n        return (0.299, 0.114)//; s/    if matrix == 1:/    if matrix == 1 or matrix == 2 or matrix == 5 or matrix == 6:/"
  "limited range read as full|s/    var full = st.seq.color_range/    var full = True/"
  "alpha dropped|s/var a = alpha\[y \* w + x\] if len(alpha) > 0 else UInt32(255)/var a = UInt32(255)/"
  "chroma nearest instead of bilinear|s/    if sx == 0 and sy == 0:/    if True:\n        return Float64(p.get(min(x >> sx, cw - 1), min(y >> sy, ch - 1)))\n    if sx == 0 and sy == 0:/"
  "chroma siting not centred|s/var fx = (Float64(x) + 0.5) \/ Float64(1 << sx) - 0.5 if sx else Float64(x)/var fx = Float64(x) \/ Float64(1 << sx) if sx else Float64(x)/"
  "high bit depth not scaled|s/    var maxv = Float64((1 << f.bit_depth) - 1)/    var maxv = 255.0/"
  "identity matrix treated as YUV|s/    var identity = st.seq.matrix_coefficients == 0/    var identity = False/"
)
fails=0; i=0
for m in "${mutants[@]}"; do
  d=${m%%|*}; e=${m#*|}; md=$W/mut$i; i=$((i + 1))
  rm -rf $md; mkdir -p $md; cp -r src $md/src
  case $e in *'\n'*) sed -i -z "$e" $md/src/imkit/avifrgb.mojo;; *) sed -i "$e" $md/src/imkit/avifrgb.mojo;; esac
  if cmp -s src/imkit/avifrgb.mojo $md/src/imkit/avifrgb.mojo; then echo "FAIL mutant did not apply: $d"; fails=$((fails + 1)); continue; fi
  if ! timeout 600 "$M" build -I $md/src tests/avif_rgba_test.mojo -o $md/test 2> $md/build.log; then echo "killed  $d (build error)"; continue; fi
  why=$(run_all $md/test)
  [ -n "$why" ] && echo "killed  $d ($why)" || { echo "FAIL mutant survived: $d"; fails=$((fails + 1)); }
done
[ $fails = 0 ] && echo "PASS avif_rgba mutants ${#mutants[@]}/${#mutants[@]}" || { echo "FAIL avif_rgba mutants: $fails"; exit 1; }
