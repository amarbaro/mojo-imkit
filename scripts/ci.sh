#!/usr/bin/env bash
# CI entry point, same on a GitHub runner and a local Ubuntu VM: install, build everything, then every CPU gate.
# GPU, display and SDL3 gates (ui_test, window_test, audio_test) are not here: GitHub runners have no GPU, display or
# libSDL3. Run scripts/local_gate.sh on a
# machine that has them.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v uv >/dev/null || { echo "FAIL setup: uv not installed"; exit 1; }
uv sync || { echo "FAIL setup: uv sync"; exit 1; }
# a TrueType font for the font and Ui checks: IMKIT_FONT, else the first of a few common locations
if [ -z "${IMKIT_FONT:-}" ]; then
  for f in /usr/share/fonts/TTF/Roboto-Medium.ttf /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf /usr/share/fonts/TTF/DejaVuSans.ttf \
           /usr/share/fonts/dejavu/DejaVuSans.ttf; do
    [ -f "$f" ] && { IMKIT_FONT=$f; break; }
  done
fi
[ -n "${IMKIT_FONT:-}" ] || { echo "FAIL setup: no TrueType font found, set IMKIT_FONT"; exit 1; }
export IMKIT_FONT
echo "font $IMKIT_FONT"
# a CJK fallback font for the glyph-fallback checks: IMKIT_CJK, else Arch or Debian/Ubuntu location
if [ -z "${IMKIT_CJK:-}" ]; then
  for f in /usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc /usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc; do
    [ -f "$f" ] && { IMKIT_CJK=$f; break; }
  done
fi
[ -n "${IMKIT_CJK:-}" ] || { echo "FAIL setup: no Noto CJK font found, set IMKIT_CJK"; exit 1; }
export IMKIT_CJK
echo "cjk $IMKIT_CJK"
mkdir -p .work
M=.venv/bin/mojo
$M precompile src/imkit -o .work/imkit.mojoc 2>.work/build.err || { echo "FAIL precompile: src/imkit"; grep error .work/build.err | head -20; exit 1; }
# every test and the example build, including the three that need a GPU, a display or libSDL3 to run
for t in tests/font_test tests/assets_test tests/anim_test tests/ui_cpu_test tests/ui_test tests/window_test tests/audio_test examples/quickstart examples/gallery; do
  $M build --target-accelerator amdgpu:gfx1100 -I src "$t.mojo" -o ".work/$(basename "$t")" 2>.work/build.err || { echo "FAIL build: $t.mojo"; grep error .work/build.err | head -20; exit 1; }
done
.work/font_test || { echo "FAIL font: tests/font_test.mojo"; exit 1; }
.work/assets_test || { echo "FAIL assets: tests/assets_test.mojo"; exit 1; }
.work/anim_test || { echo "FAIL anim: tests/anim_test.mojo"; exit 1; }
.work/ui_cpu_test || { echo "FAIL ui: tests/ui_cpu_test.mojo"; exit 1; }
.work/quickstart > /dev/null || { echo "FAIL example: examples/quickstart.mojo"; exit 1; }
$M run -I src tests/style_test.mojo > .work/style_test.log 2>&1 || { echo "FAIL style: tests/style_test.mojo"; tail -5 .work/style_test.log; exit 1; }
bash tests/jpeg_test.sh > .work/jpeg_test.log 2>&1 || { echo "FAIL jpeg: tests/jpeg_test.sh"; tail -8 .work/jpeg_test.log; exit 1; }
bash tests/webp_test.sh > .work/webp_test.log 2>&1 || { echo "FAIL webp: tests/webp_test.sh"; tail -8 .work/webp_test.log; exit 1; }
# AVIF: committed fixtures (our own encodes, 220 KB); references come from this machine's avifdec / dav1d. No mutants in CI.
mkdir -p .work/avif && cp tests/fixtures/avif/* .work/avif/
for g in avif_container avif_obu av1sym_test av1tile_test avif_yuv_test avif_seq_test avif_rgba_test; do
  MUTANTS=0 bash tests/$g.sh > .work/$g.log 2>&1 || { echo "FAIL avif: tests/$g.sh"; tail -8 .work/$g.log; exit 1; }
done
echo "ok   avif: $(grep -h '^PASS' .work/avif_*.log .work/av1*_test.log | tr '\n' ' ' | cut -c1-160)"
echo "ok   style, jpeg, webp: $(tail -1 .work/style_test.log | cut -c1-60); $(tail -1 .work/jpeg_test.log); $(grep -c '^PASS' .work/webp_test.log) webp PASS lines"
MUTANT_DRY=1 scripts/mutants.sh > .work/mutants_dry.txt 2>&1 || { echo "FAIL mutants: a sed no longer matches its line, see .work/mutants_dry.txt"; grep FAIL .work/mutants_dry.txt | head -3; exit 1; }
echo "PASS ci"
