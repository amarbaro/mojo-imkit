#!/usr/bin/env bash
# Extra fixtures for the tile-parse gates, each made for one bitstream property, which the script then checks in ffmpeg's
# trace_headers (a fixture is checked for the property it exists for): tiles.avif = 2x2 tiles, big.avif = full-size screenshot
# with default tools, seg.obu = raw key frame OBUs from aomenc with segmentation (aq-mode 1; avifenc's all-intra mode never
# enables it). delta_lf_present = 1 was not reachable from avifenc or aomenc, so that path has no fixture.
# The older six (a10 a420 a444 alpha lossless mono .avif) are kept as they are.
set -euo pipefail
cd "$(dirname "$0")/.."
F=.work/avif; mkdir -p $F
src=docs/img/gallery-glass.png
small=$F/src-320.png
[ -f $small ] || timeout 30 magick $src -resize 320x180! $small
timeout 120 avifenc -q 60 -s 6 --tilecolslog2 1 --tilerowslog2 1 $src -o $F/tiles.avif > /dev/null || { echo "FAIL avifenc: tiles"; exit 1; }
timeout 120 avifenc -q 60 -s 6 $src -o $F/big.avif > /dev/null || { echo "FAIL avifenc: big"; exit 1; }
timeout 30 ffmpeg -v error -y -i $small -pix_fmt yuv420p $F/src-320.y4m
timeout 120 aomenc --limit=1 --kf-max-dist=0 --end-usage=q --cq-level=30 --cpu-used=6 --aq-mode=1 --deltaq-mode=0 \
  -o $F/seg.ivf $F/src-320.y4m > /dev/null 2>&1 || { echo "FAIL aomenc: seg"; exit 1; }
timeout 30 ffmpeg -v error -y -i $F/seg.ivf -c copy -f obu $F/seg.obu
timeout 120 aomenc --limit=1 --kf-max-dist=0 --end-usage=q --cq-level=32 --deltaq-mode=2 --delta-lf-mode=1 --cpu-used=6 \
  -o $F/dlf.ivf $F/src-320.y4m > /dev/null 2>&1 || { echo "FAIL aomenc: dlf"; exit 1; }
timeout 30 ffmpeg -v error -y -i $F/dlf.ivf -c copy -f obu $F/dlf.obu
sr() {  # superres key frame with loop restoration: name, source y4m, denominator (9..16)
  timeout 300 aomenc --limit=1 --kf-max-dist=0 --end-usage=q --cq-level=30 --cpu-used=6 --superres-mode=1 \
    --superres-kf-denominator=$3 --superres-denominator=$3 --enable-restoration=1 -o $F/$1.ivf $2 > /dev/null 2>&1 || { echo "FAIL aomenc: $1"; exit 1; }
  timeout 30 ffmpeg -v error -y -i $F/$1.ivf -c copy -f obu $F/$1.obu
}
sr superres16 $F/src-320.y4m 16
sr superres11 $F/src-320.y4m 11
timeout 30 ffmpeg -v error -y -i $src -pix_fmt yuv420p $F/src-big.y4m
sr superres_big $F/src-big.y4m 16
has() { timeout 30 ffmpeg -v trace -i "$F/$1" -c copy -bsf:v trace_headers -f null - 2>&1 | grep -qE "$2" || { echo "FAIL fixture $1: no '$2' in trace_headers"; exit 1; }; }
has tiles.avif 'tile_cols_log2 +[01]+ = 1$'
has tiles.avif 'tile_rows_log2 +[01]+ = 1$'
has seg.obu 'segmentation_enabled +1 = 1$'
has dlf.obu 'delta_lf_present +1 = 1$'
for n in superres16 superres11 superres_big; do has $n.obu 'use_superres +1 = 1$'; done
# Pixel-gate fixtures (lane A): real 4:2:0 (the older a420.avif is 4:4:4), 10 and 12 bit, 128x128 superblocks, loop restoration,
# an odd size, reduced_tx_set, and a 2-frame sequence (stage 8). Each is checked for the property it exists for.
timeout 60 avifenc -y 420 -q 50 -s 6 $small -o $F/y420.avif > /dev/null
timeout 60 avifenc -y 420 -d 10 -q 50 -s 6 $small -o $F/y420_10.avif > /dev/null
timeout 60 avifenc -y 420 -d 12 -q 50 -s 6 $small -o $F/y420_12.avif > /dev/null
timeout 120 avifenc -y 444 -q 50 -s 6 -a sb-size=128 $src -o $F/sb128.avif > /dev/null
timeout 60 avifenc -y 420 -q 30 -s 4 -a enable-restoration=1 -a enable-cdef=1 $small -o $F/y420_lr.avif > /dev/null
timeout 30 magick $src -resize 321x179! $F/src-odd.png
timeout 60 avifenc -y 420 -q 50 -s 6 $F/src-odd.png -o $F/odd.avif > /dev/null
timeout 60 avifenc -y 420 -q 50 -s 6 -a reduced-tx-type-set=1 $small -o $F/redtx.avif > /dev/null
timeout 60 avifenc -y 422 -q 60 -s 6 $small -o $F/y422.avif > /dev/null
timeout 60 avifenc -y 422 -d 10 -q 60 -s 6 $small -o $F/y422_10.avif > /dev/null
timeout 30 magick $small -rotate 90 -resize 320x180! $F/src-b.png
timeout 60 avifenc -y 420 -q 50 -s 6 --timescale 30 --duration 4 $small --duration 7 $F/src-b.png -o $F/anim.avif > /dev/null
# screen.avif: synthetic text screenshot, 2005 intrabc blocks (the gallery screenshot has 120 per tile): MV stack weights and clamps
python3 -c "
import random
random.seed(3)
w='the quick brown fox jumps over lazy dog pixel block copy stream frame luma chroma tile'.split()
open('$F/text.txt','w').write('\\n'.join(' '.join(random.choice(w) for _ in range(9)) for _ in range(40)))"
timeout 30 magick -size 800x640 xc:white -font DejaVu-Sans-Mono -pointsize 13 -fill black -annotate +8+16 "@$F/text.txt" -fill '#2060c0' -draw "rectangle 600,40 780,200" $F/screen.png
timeout 120 avifenc -y 444 -q 60 -s 6 $F/screen.png -o $F/screen.avif > /dev/null
has screen.avif 'allow_intrabc +[01]+ = 1$'
info() { avifdec --info "$F/$1" 2>&1 | grep -qE "$2" || { echo "FAIL fixture $1: avifdec --info has no '$2'"; exit 1; }; }
info y420.avif 'Format +: YUV420'; info y422.avif 'Format +: YUV422'; info y422_10.avif 'Bit Depth +: 10'; info y420_10.avif 'Bit Depth +: 10'; info y420_12.avif 'Bit Depth +: 12'
info odd.avif 'Resolution +: 321x179'; info anim.avif '2 frames'
has sb128.avif 'use_128x128_superblock +[01]+ = 1$'
has y420_lr.avif 'enable_restoration +[01]+ = 1$'
has redtx.avif 'reduced_tx_set +[01]+ = 1$'
echo "PASS avif_fixtures"
