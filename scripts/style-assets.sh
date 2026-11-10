#!/usr/bin/env bash
# Turn ComfyUI style renders into shipped assets: per style assets/styles/<name>/bg.jpg (1280x720, q85) and
# assets/styles/<name>/icons/<icon>.png (8 icons, 128x128 RGBA from the BiRefNet cutouts); the raw atlas
# (.work/atlas/<name>.{bin,txt}, 512 KB each) is built here, never committed. Fails when an icon has no
# transparent pixels (the cutout did nothing) or the total size passes 20 MB.
# usage: scripts/style-assets.sh RENDERS CUTS   (comfy-run out dirs: bg-<name>.png, cut-<name>-<icon>.png)
set -euo pipefail
cd "$(dirname "$0")/.."
r=${1:?usage: style-assets.sh RENDERS CUTS}; c=${2:?}
icons="home search settings user play folder bell close"
mkdir -p .work/atlas
.venv/bin/mojo build -I src tools/pack_atlas.mojo -o .work/pack_atlas > .work/pack.build.log 2>&1 || { echo "FAIL build pack_atlas: .work/pack.build.log"; exit 1; }
n=0
for f in "$r"/bg-*.png; do
  s=$(basename "$f" .png); s=${s#bg-}; d=assets/styles/$s; mkdir -p "$d"
  rm -f "$d/icons.bin" "$d/icons.txt"
  magick "$f" -strip -quality 85 "$d/bg.jpg" || { echo "FAIL bg $s"; exit 1; }
  list=()
  for i in $icons; do
    src="$c/cut-$s-$i.png"; [ -f "$src" ] || { echo "FAIL icon missing: $src"; exit 1; }
    mkdir -p "$d/icons"; o=$d/icons/$i.png
    magick "$src" -trim +repage -resize 116x116 -background none -gravity center -extent 128x128 -strip -depth 8 -define png:color-type=6 "$o"
    [ "$(magick "$o" -format '%[fx:minima.a<0.01?1:0]' info:)" = 1 ] || { echo "FAIL icon has no transparency: $src"; exit 1; }
    list+=("$o")
  done
  .work/pack_atlas ".work/atlas/$s" "${list[@]}" > /dev/null || { echo "FAIL pack $s"; exit 1; }
  n=$((n + 1))
done
mb=$(du -sm assets/styles | cut -f1)
(( mb <= 20 )) || { echo "FAIL size: assets/styles is $mb MB > 20"; exit 1; }
echo "PASS style-assets: $n styles, 8 icons each, $mb MB"
