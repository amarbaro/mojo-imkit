#!/usr/bin/env bash
# WebP fixtures and goldens for tests/webp_test.mojo. ImageMagick (libwebp) is the oracle: it encodes the .webp files from the
# style assets and decodes them to FILE.rgba (8-bit RGBA, the golden). Nothing here runs at decode time.
# usage: tests/webp_fixtures.sh  -> .work/webp/*.webp + *.rgba
set -euo pipefail
cd "$(dirname "$0")/.."
command -v magick >/dev/null || { echo "FAIL setup: magick not installed"; exit 1; }
magick -list format | grep -q 'WEBP\*' || { echo "FAIL setup: magick has no WebP support"; exit 1; }
D=.work/webp
rm -rf "$D" && mkdir -p "$D"
BG=assets/styles/bauhaus/bg.jpg
IC=assets/styles/bauhaus/icons/bell.png
IC2=assets/styles/neon/icons/home.png
[ -f "$IC2" ] || IC2=assets/styles/bauhaus/icons/home.png
# enc NAME SRC [magick options...]: encode, then decode with libwebp for the golden
enc() {
  local n=$1 src=$2; shift 2
  magick "$src" "$@" "$D/$n.webp" || { echo "FAIL fixture: $n"; exit 1; }
  magick "$D/$n.webp" -depth 8 "rgba:$D/$n.rgba" || { echo "FAIL golden: $n"; exit 1; }
}
SMALL=(-resize 160x90!)
# lossless: whole 1280x720 background, small crops, icons with alpha, a 4-colour palette, a 2-colour palette
enc ll_bg "$BG" -define webp:lossless=true -define webp:method=4
enc ll_bg_small "$BG" "${SMALL[@]}" -define webp:lossless=true -define webp:method=6
enc ll_icon "$IC" -define webp:lossless=true
enc ll_icon2 "$IC2" -define webp:lossless=true -define webp:method=6
enc ll_icon_exact "$IC" -define webp:lossless=true -define webp:exact=true
enc ll_pal4 "$BG" "${SMALL[@]}" -colors 4 -dither None -define webp:lossless=true -define webp:method=6
enc ll_pal2 "$IC" -colors 2 -dither None -define webp:lossless=true -define webp:method=6
enc ll_pal16 "$BG" "${SMALL[@]}" -colors 16 -dither None -define webp:lossless=true -define webp:method=6
enc ll_noise "$BG" -resize 97x53! -attenuate 0.6 +noise Gaussian -define webp:lossless=true -define webp:method=6
enc ll_tiny "$IC" -resize 1x1! -define webp:lossless=true
enc ll_odd "$BG" -resize 37x23! -define webp:lossless=true -define webp:method=6
# lossy VP8, no alpha
enc ly_bg "$BG" -quality 75 -define webp:method=4
enc ly_bg_q30 "$BG" -quality 30 -define webp:method=4
enc ly_bg_small "$BG" "${SMALL[@]}" -quality 75 -define webp:method=6
enc ly_bg_odd "$BG" -resize 37x23! -quality 75
enc ly_bg_sharp "$BG" "${SMALL[@]}" -quality 90 -define webp:sharp-yuv=true -define webp:filter-strength=0
enc ly_bg_seg "$BG" "${SMALL[@]}" -quality 60 -define webp:segments=4 -define webp:partitions=3 -define webp:filter-sharpness=4
enc ly_bg_simple "$BG" "${SMALL[@]}" -quality 75 -define webp:filter-type=0
# lossy with alpha: raw and lossless-compressed alpha, every filter
enc ly_alpha_raw "$IC" -quality 75 -define webp:alpha-compression=0 -define webp:alpha-filtering=0
enc ly_alpha_ll "$IC" -quality 75 -define webp:alpha-compression=1 -define webp:alpha-filtering=0
enc ly_alpha_fast "$IC" -quality 75 -define webp:alpha-compression=1 -define webp:alpha-filtering=1
enc ly_alpha_best "$IC2" -quality 75 -define webp:alpha-compression=1 -define webp:alpha-filtering=2
enc ly_alpha_bg "$BG" "${SMALL[@]}" -alpha set -channel A -evaluate set 60% +channel -quality 75
# libwebp through ctypes (tests/webp_oracle_enc.py) for what ImageMagick cannot set: token partitions (only honoured with
# low_memory), skip probability, one segment, the strongest filters, huge coefficients, tiny sizes
enc2() {
  local n=$1 src=$2 size=$3; shift 3
  magick "$src" -resize "$size!" -depth 8 "rgba:$D/$n.in" || { echo "FAIL fixture: $n"; exit 1; }
  python3 tests/webp_oracle_enc.py "$D/$n.in" "${size%x*}" "${size#*x}" "$D/$n.webp" "$@" || { echo "FAIL fixture: $n (oracle encoder)"; exit 1; }
  rm "$D/$n.in"
  magick "$D/$n.webp" -depth 8 "rgba:$D/$n.rgba" || { echo "FAIL golden: $n"; exit 1; }
}
magick -size 96x64 xc:'#3a6' -fill white -draw 'circle 48,32 48,10' -fill '#c33' -draw 'rectangle 4,4,20,12' "$D/flat.png"
enc2 ly_part2 "$BG" 160x90 partitions=1 low_memory=1
enc2 ly_part8 "$BG" 160x90 partitions=3 low_memory=1 segments=4
enc2 ly_flat "$D/flat.png" 96x64 low_memory=1 partitions=2
enc2 ly_flat_alpha "$IC" 128x128 low_memory=1 partitions=1 alpha_compression=1
enc2 ly_seg1 "$BG" 160x90 segments=1 sns_strength=0
enc2 ly_strong "$BG" 160x90 filter_strength=100 filter_sharpness=0 segments=3
enc2 ly_simple_strong "$BG" 160x90 filter_strength=90 filter_type=0 filter_sharpness=7
enc2 ly_q100 "$D/flat.png" 97x53 quality=100 method=6
enc2 ly_q100_noise "$BG" 97x53 quality=100 method=6 sns_strength=0 filter_strength=0
enc2 ly_q2 "$BG" 160x90 quality=2 method=6
enc2 ly_1x1 "$BG" 1x1
enc2 ly_17x1 "$BG" 17x1
enc2 ly_1x17 "$BG" 1x17
enc2 ly_16x16 "$BG" 16x16 low_memory=1
enc2 ly_33x31 "$BG" 33x31 partitions=1 low_memory=1
rm "$D/flat.png"
# alpha pre-filters: which filter libwebp picks depends on its version (Arch and Ubuntu 26.04 differ for the same input), so the two
# filtered-alpha fixtures are committed files (tests/fixtures/webp/, made here and checked below); only their goldens are decoded here
for k in h v; do
  cp "tests/fixtures/webp/ly_alpha_$k.webp" "$D/" || { echo "FAIL fixture: tests/fixtures/webp/ly_alpha_$k.webp missing"; exit 1; }
  magick "$D/ly_alpha_$k.webp" -depth 8 "rgba:$D/ly_alpha_$k.rgba" || { echo "FAIL golden: ly_alpha_$k"; exit 1; }
done
# prove the fixtures reach every un-filter: the filter bits (2-3) of the ALPH header byte
alph_filter() { local off; off=$(grep -obUa ALPH "$1" | head -1 | cut -d: -f1); echo $(( ($(od -An -tu1 -j$((off + 8)) -N1 "$1") >> 2) & 3 )); }
[ "$(alph_filter "$D/ly_alpha_h.webp")" = 1 ] || { echo "FAIL fixture: ly_alpha_h does not use the horizontal alpha filter"; exit 1; }
[ "$(alph_filter "$D/ly_alpha_v.webp")" = 2 ] || { echo "FAIL fixture: ly_alpha_v does not use the vertical alpha filter"; exit 1; }
[ "$(alph_filter "$D/ly_alpha_fast.webp")" = 3 ] || { echo "FAIL fixture: ly_alpha_fast does not use the gradient alpha filter"; exit 1; }
ls "$D"/*.webp | wc -l | xargs echo "PASS webp_fixtures files:"
