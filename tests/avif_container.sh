#!/usr/bin/env bash
# Stage 1 gate (AVIF container): tests/avif_info.mojo prints, per file, the facts below from imkit.avif's HEIF parser; they must equal avifdec --info.
# Line format (one file per block, blank line between): resolution WxH / depth N / format YUV420|YUV422|YUV444|YUV400 / alpha yes|no /
# range full|limited / primaries N / transfer N / matrix N / obu0 HEX (first byte of the primary item's AV1 data: 0x0A or 0x12 = sequence header / temporal delimiter OBU).
# Mutant: a truncated file must raise (exit non-zero, no hang).
set -euo pipefail
cd "$(dirname "$0")/.."
F=.work/avif; M=${MOJO:-.venv/bin/mojo}
timeout 300 "$M" build -I src tests/avif_info.mojo -o .work/avif_info 2> .work/avif_info.log || { grep -A6 -m3 error .work/avif_info.log | cut -c1-240; echo "FAIL build: tests/avif_info.mojo"; exit 1; }
exp() { avifdec --info "$1" 2>/dev/null | awk -F': *' '
  /Resolution/{print "resolution " $2} /Bit Depth/{print "depth " $2}
  /Format/{print "format " $2} /Alpha/{print "alpha " ($2 ~ /Absent/ ? "no" : "yes")}
  /Range/{print "range " tolower($2)} /Color Primaries/{print "primaries " $2}
  /Transfer Char/{print "transfer " $2} /Matrix Coeffs/{print "matrix " $2}'; }
fails=0
for f in $F/*.avif; do
  e=$(exp "$f"); g=$(timeout 10 .work/avif_info "$f" 2>&1 | grep -v '^obu0' || true)
  o=$(timeout 10 .work/avif_info "$f" 2>/dev/null | awk '/^obu0/{print $2}' || true)
  if [ "$e" != "$g" ]; then echo "FAIL $f:"; diff <(echo "$e") <(echo "$g") | head -12 || true; fails=$((fails + 1)); continue; fi
  case "$o" in 0x0A|0x0a|0x12) echo "ok   $f";; *) echo "FAIL $f: obu0 '$o', want 0x0A or 0x12"; fails=$((fails + 1));; esac
done
head -c 300 $F/alpha.avif > .work/avif_trunc.avif
if timeout 10 .work/avif_info .work/avif_trunc.avif >/dev/null 2>&1; then echo "FAIL mutant: truncated file decoded"; fails=$((fails + 1)); else echo "ok   truncated file raised"; fi
[ $fails = 0 ] && echo "PASS avif_container" || { echo "FAIL avif_container: $fails"; exit 1; }
