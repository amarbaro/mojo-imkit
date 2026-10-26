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
mkdir -p .work
M=.venv/bin/mojo
$M precompile src/imkit -o .work/imkit.mojoc 2>.work/build.err || { echo "FAIL precompile: src/imkit"; grep error .work/build.err | head -20; exit 1; }
# every test and the example build, including the three that need a GPU, a display or libSDL3 to run
for t in tests/font_test tests/ui_cpu_test tests/ui_test tests/window_test tests/audio_test examples/quickstart; do
  $M build -I src "$t.mojo" -o ".work/$(basename "$t")" 2>.work/build.err || { echo "FAIL build: $t.mojo"; grep error .work/build.err | head -20; exit 1; }
done
.work/font_test || { echo "FAIL font: tests/font_test.mojo"; exit 1; }
.work/ui_cpu_test || { echo "FAIL ui: tests/ui_cpu_test.mojo"; exit 1; }
.work/quickstart > /dev/null || { echo "FAIL example: examples/quickstart.mojo"; exit 1; }
echo "PASS ci"
