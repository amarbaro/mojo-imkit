#!/usr/bin/env bash
# Pixel facts of the gallery frames (scripts/gallery.sh DIR first): the scroll list is clipped to its viewport (y 82..282, x 460..828)
# and its selected row 2, scrolled half out at the top, shows as a strip of the preset's accent colour at (600, 88);
# just outside the viewport (y 76 and 80 above, 284 and 289 below) the panel shows: neighbours differ by at most 6 per channel
# (the glass panel is translucent over a gradient), a leaked row would differ by far more.
set -euo pipefail
cd "$(dirname "$0")/.."
d="${1:-.work/gallery-shots}"
px() { magick "$d/gallery-$1.png" -format "%[hex:p{$2,$3}]" info:; }
rgb() { magick "$d/gallery-$1.png" -format "%[fx:int(255*p{$2,$3}.r)] %[fx:int(255*p{$2,$3}.g)] %[fx:int(255*p{$2,$3}.b)]" info:; }
near() {  # near PRESET Y1 Y2: max channel difference of (600, Y1) and (600, Y2) is at most 6
  local a b i; read -ra a <<< "$(rgb "$1" 600 "$2")"; read -ra b <<< "$(rgb "$1" 600 "$3")"
  for i in 0 1 2; do [ $(( a[i] > b[i] ? a[i] - b[i] : b[i] - a[i] )) -le 6 ] || return 1; done
}
for spec in glass:5F62F0 neon:00F0FF flat:2563EB; do
  p=${spec%%:*}; want=${spec##*:}
  [ "$(px $p 600 88)" = "$want" ] || { echo "FAIL gallery_check $p: selected row strip at (600,88) is $(px $p 600 88), want $want"; exit 1; }
  [ "$(px $p 600 80)" != "$want" ] || { echo "FAIL gallery_check $p: the selected row shows above the viewport at (600,80): not clipped"; exit 1; }
  near $p 76 80 && near $p 284 289 || { echo "FAIL gallery_check $p: a row leaked out of the clip (y 76 vs 80 or 284 vs 289 differ)"; exit 1; }
done
[ "$(px glass 600 76)" != "$(px neon 600 76)" ] && [ "$(px neon 600 76)" != "$(px flat 600 76)" ] || { echo "FAIL gallery_check: presets share a panel colour"; exit 1; }
echo "PASS gallery_check: clip edges and accent strip in glass, neon, flat"
