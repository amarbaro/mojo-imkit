#!/usr/bin/env bash
# Mutants of the v0.7.0 additions: each breaks one rule in a copy of src and the matching test must fail. A mutant that
# survives, or a sed that changes nothing, fails this script. Needs a display for the window mutant (window_test, ~2 s).
set -euo pipefail
cd "$(dirname "$0")/.."
M=.venv/bin/mojo
export IMKIT_FONT="${IMKIT_FONT:-/usr/share/fonts/TTF/Roboto-Medium.ttf}"
mutant() {  # name file sed-expression test [gpu]: a GPU test runs under GPU_WRAP
  local name=$1 file=$2 expr=$3 test=$4 d=.work/mutant
  rm -rf "$d"; mkdir -p "$d"; cp -r src "$d/src"
  sed -i "$expr" "$d/src/imkit/$file"
  cmp -s "src/imkit/$file" "$d/src/imkit/$file" && { echo "FAIL $name: sed changed nothing"; exit 1; }
  [ -z "${MUTANT_DRY:-}" ] || { echo "OK $name"; return 0; }  # MUTANT_DRY=1: only check that every sed still matches (seconds)
  # shellcheck disable=SC2086
  if ${5:+${GPU_WRAP:-}} timeout 300 $M run -I "$d/src" "tests/$test.mojo" > "$d/out.txt" 2>&1; then
    echo "FAIL $name: $test still passes"; exit 1
  fi
  grep -m1 '^FAIL' "$d/out.txt" || { echo "FAIL $name: $test failed without a FAIL line, see $d/out.txt"; exit 1; }
  echo "KILLED $name"
}
mutant "field ignores max" ui.mojo 's/ and buf.byte_length() + len(add) < max//' ui_cpu_test
mutant "merge drops text" window.mojo '/self.text += o.text/d' window_test
mutant "push text dies before poll" window.mojo 's/            self.keep.append(buf^)/            self.keep.clear()\n            self.keep.append(buf^)/' window_test
mutant "rrect glow ignored" draw.mojo 's/if gl > 0 and d > 0:/if gl > 1000 and d > 0:/' ui_cpu_test
mutant "rrect border ignored" draw.mojo 's/    if bw > 0:/    if bw > 1000:/' ui_cpu_test
mutant "rrect gradient reversed" draw.mojo 's/\* 2 \* gr/* 2 * (-gr)/' ui_cpu_test
mutant "rrect span ignores glow" draw.mojo 's/ if kind == RRECT else (self/ if kind == 99 else (self/' ui_cpu_test
mutant "srect linear ignored" draw.mojo 's/if st\[0\] & 3 == 1:/if st[0] \& 3 == 9:/' ui_cpu_test
mutant "srect radial ignored" draw.mojo 's/elif st\[0\] & 3 == 2:/elif st[0] \& 3 == 9:/' ui_cpu_test
mutant "srect shadow offset ignored" draw.mojo 's/rsd(px - flt(st\[4\]), py - flt(st\[5\])/rsd(px, py/' ui_cpu_test
mutant "srect span ignores shadow" draw.mojo 's/if kind == SRECT else 0/if kind == 99 else 0/' ui_cpu_test
mutant "clip edge not half open" draw.mojo 's/return px < c\[0\] or px >= c\[2\]/return px < c[0] or px > c[2]/' ui_cpu_test
mutant "clip never ends in the bins" draw.mojo 's/return FULL if self.cmd\[o + 7\] != 0 else/return FULL if self.cmd[o + 7] == 99 else/' ui_cpu_test
mutant "span ignores the clip" draw.mojo 's/if kind != CLIP and clip\[0\] > -1e8:/if kind != CLIP and clip[0] > 1e8:/' ui_cpu_test
mutant "glass tint ignored" draw.mojo 's/return over(over(acc, back, fill), unpack(c), fill)/return over(acc, back, fill)/' ui_cpu_test
mutant "glass backdrop ignored" draw.mojo 's/return over(over(acc, back, fill), unpack(c), fill)/return over(acc, unpack(c), fill)/' ui_cpu_test
mutant "blur skips the vertical pass" layer.mojo 's/blur_axis\[0, 1\]/blur_axis[1, 0]/' ui_test gpu
mutant "blur taps unweighted" draw.mojo 's/var wk = Float32(BR + 1 - abs(k))/var wk = Float32(1)/' ui_test gpu
mutant "utf8 three-byte lead" font.mojo 's/(3 if c >> 4 == 14/(3 if c >> 4 == 15/' font_test
mutant "utf8 continuation unchecked" font.mojo 's/if Int(b\[i + k\]) >> 6 != 2:/if False:/' font_test
mutant "skyline ignores taller steps" atlas.mojo 's/y = max(y, self.ys\[j\])/y = self.ys[i]/' font_test
mutant "glyph cache ignores the size" font.mojo 's/var key = c << 8 | s/var key = c << 8/' font_test
mutant "no fallback font" font.mojo 's/(self.fb if self.fb != 0 and/(0 if self.fb != 0 and/' font_test
mutant "dirty rows not tracked" font.mojo 's/self.dirty0, self.dirty1 = min(self.dirty0, y), max(self.dirty1, y + h)/self.dirty0 = self.dirty0/' font_test
mutant "dirty rows not uploaded" layer.mojo 's/if ui.d.font.dirty1 > ui.d.font.dirty0:/if ui.d.font.dirty1 > 99999:/' ui_test gpu
mutant "png paeth wrong" assets.mojo 's/pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)/pred = a if pa <= pb and pa <= pc else (c if pb <= pc else b)/' assets_test
mutant "png average rounds up" assets.mojo 's/pred = (a + b) \/\/ 2/pred = (a + b + 1) \/\/ 2/' assets_test
mutant "png rgb alpha" assets.mojo 's/cur\[x \* bpp + 3\] if bpp == 4 else 255/cur[x * bpp + 3] if bpp == 4 else 0/' assets_test
mutant "png row up filter ignored" assets.mojo 's/                pred = b$/                pred = 0/' assets_test
mutant "atlas offsets restart" assets.mojo 's/String(len(bin) \/\/ 4) + " " + String(pic\[0\])/"0 " + String(pic[0])/' assets_test
mutant "icon_img ignores its size" ui.mojo 's/(Float32(m\[3 \* i + 1\]) if w <= 0 else w \* k)/w * k/' assets_test
mutant "png IHDR length unchecked" assets.mojo 's/if n != 13:/if n != 13 and n == 99:/' assets_test
mutant "png size cap off" assets.mojo 's/if w > MAXPX or h > MAXPX or w \* h > MAXPX:/if w < 0:/' assets_test
mutant "clip replace keeps the old clip" draw.mojo 's/^        self.unclip()$/        pass/' ui_cpu_test
mutant "push keeps NaN commands" draw.mojo 's/ or isnan(v).reduce_or() or r != r//' ui_cpu_test
mutant "push does not clamp infinities" draw.mojo 's/^        v = min(max(v, -BIG), BIG)$/        pass/' ui_cpu_test
mutant "set_image may overwrite the atlas" layer.mojo 's/if off < self.asset_px:/if off < 0:/' ui_test gpu
mutant "set_assets may overwrite a picture" layer.mojo 's/if len(a.px) > self.img_lo:/if len(a.px) > ISRC + 1:/' ui_test gpu
[ -z "${MUTANT_DRY:-}" ] || { echo "PASS mutants (dry: every sed matches)"; exit 0; }
echo "PASS mutants"
