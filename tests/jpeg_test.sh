#!/usr/bin/env bash
# JPEG decoder gate (CPU only): ImageMagick writes the fixtures and the golden RGBA files (the test oracle, never run time),
# tests/jpeg_test.mojo decodes them with src/imkit/jpeg.mojo and compares. A skip is not a pass.
# usage: tests/jpeg_test.sh [--no-build]   fixtures: .work/jpeg/*.jpg + *.jpg.rgba
set -euo pipefail
cd "$(dirname "$0")/.."
D=.work/jpeg
S=assets/styles
command -v magick >/dev/null || { echo "FAIL setup: magick (the oracle) not installed"; exit 1; }
rm -rf "$D" && mkdir -p "$D"
gen() {  # gen NAME SOURCE magick-options...: encode, then write the golden from the JPEG itself
  local n=$1 src=$2; shift 2
  magick "$src" "$@" "$D/$n.jpg" || { echo "FAIL fixtures: $n"; exit 1; }
  magick "$D/$n.jpg" -depth 8 "rgba:$D/$n.jpg.rgba" || { echo "FAIL golden: $n"; exit 1; }
}
BG=$S/aerial-drone/bg.jpg
for q in 50 90; do
  gen "bg_q${q}_444" $BG -quality $q -sampling-factor 1x1
  gen "bg_q${q}_420" $BG -quality $q -sampling-factor 2x2
done
gen bg_q75_422 $BG -quality 75 -sampling-factor 2x1
gen bg_q75_440 $BG -quality 75 -sampling-factor 1x2
gen bg_prog_420 $BG -quality 75 -sampling-factor 2x2 -interlace JPEG
gen bg_prog_444 $BG -quality 75 -sampling-factor 1x1 -interlace JPEG
gen bg_restart $BG -quality 85 -sampling-factor 2x2 -define jpeg:restart-interval=7
gen bg_restart_prog $BG -quality 85 -sampling-factor 1x1 -interlace JPEG -define jpeg:restart-interval=5
gen bg_grey $BG -quality 80 -colorspace Gray
gen bg_grey_prog $BG -quality 80 -colorspace Gray -interlace JPEG
gen bg_odd_420 $BG -crop 1277x717+3+2 +repage -quality 80 -sampling-factor 2x2
gen bg_odd_prog $BG -crop 1277x717+3+2 +repage -quality 80 -sampling-factor 2x2 -interlace JPEG
gen bg_tiny_420 $BG -crop 3x5+10+10 +repage -quality 90 -sampling-factor 2x2
gen small_prog_420 $BG -crop 200x120+40+30 +repage -quality 75 -sampling-factor 2x2 -interlace JPEG -define jpeg:restart-interval=3
gen small_base_422 $BG -crop 203x117+40+30 +repage -quality 75 -sampling-factor 2x1
gen small_grey $BG -crop 100x90+40+30 +repage -quality 75 -colorspace Gray
gen bg_one_px $BG -crop 1x1+10+10 +repage -quality 90
# icons: small, odd sizes, flattened on white (a JPEG has no alpha)
for f in $(ls $S/*/icons/*.png | awk 'NR % 29 == 1'); do
  n=icon_$(basename "$(dirname "$(dirname "$f")")")_$(basename "$f" .png)
  gen "$n" "$f" -background white -alpha remove -alpha off -resize 37x41! -quality 70 -sampling-factor 2x2
done
echo "fixtures: $(ls $D/*.jpg | wc -l) files"
mkdir -p .work
M=.venv/bin/mojo
if [ "${1:-}" != "--no-build" ]; then
  rm -f .work/jpeg_test
  $M build -I src tests/jpeg_test.mojo -o .work/jpeg_test 2>.work/build.err || { echo "FAIL build: tests/jpeg_test.mojo"; grep -A3 error .work/build.err | head -40; exit 1; }
fi
# accuracy against the golden: max channel diff <= 2, mean <= 0.5
.work/jpeg_test check "$D" || { echo "FAIL jpeg: accuracy"; exit 1; }
# mutants: every one must raise, never crash or hang (10 s for the whole run)
timeout 10 .work/jpeg_test mutants "$D/bg_q75_422.jpg" "$D/bg_prog_420.jpg" "$D/bg_restart.jpg" || { echo "FAIL jpeg: mutants (exit $?)"; exit 1; }
# fuzz: random corruptions and every sampling-factor byte, in-process, 60 s for the whole run
timeout 60 .work/jpeg_test fuzz "$D/small_prog_420.jpg" 400 | tail -1 || { echo "FAIL jpeg: fuzz progressive (exit $?)"; exit 1; }
timeout 60 .work/jpeg_test fuzz "$D/small_base_422.jpg" 400 | tail -1 || { echo "FAIL jpeg: fuzz baseline (exit $?)"; exit 1; }
timeout 60 .work/jpeg_test fuzz "$D/small_grey.jpg" 400 | tail -1 || { echo "FAIL jpeg: fuzz grey (exit $?)"; exit 1; }
# speed: median of 5 decodes in one process
.work/jpeg_test bench "$BG" || { echo "FAIL jpeg: bench"; exit 1; }
echo "PASS jpeg"
