#!/usr/bin/env bash
# Build examples/gallery.mojo, render one frame per preset on the GPU (gpu-wait), convert the PPMs to PNG.
# usage: scripts/gallery.sh [DIR]   (default .work/gallery-shots) ; prints the PNG paths
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-.work/gallery-shots}"
mkdir -p "$out" .work
.venv/bin/mojo build --target-accelerator amdgpu:gfx1100 -I src examples/gallery.mojo -o .work/gallery > .work/gallery.build.log 2>&1 || { echo "FAIL build gallery: .work/gallery.build.log"; exit 1; }
gpu-wait run --shared --vram 2 --timeout 600 -- .work/gallery --shots "$out" || { echo "FAIL run gallery"; exit 1; }
for p in glass neon flat; do
  magick "$out/gallery-$p.ppm" "$out/gallery-$p.png" || { echo "FAIL convert $p"; exit 1; }
  rm "$out/gallery-$p.ppm"
  echo "$PWD/$out/gallery-$p.png"
done
