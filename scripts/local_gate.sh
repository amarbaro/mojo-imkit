#!/usr/bin/env bash
# The GPU, display and SDL3 gates, run locally (verified on gfx1100, KDE Wayland): compose on the GPU (ui_test), a real SDL3
# window (window_test, opens a window for about 2 s) and the audio stream on SDL's dummy driver (audio_test, needs
# libSDL3 only). GitHub runners have none of these, so scripts/ci.sh does not run them.
# GPU_WRAP prefixes the GPU run, for example GPU_WRAP="gpu-wait run --timeout 300 --". IMKIT_FONT picks the font
# (default Roboto Medium, which ui_test's pixel positions were written for).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .work
for t in ui_test window_test audio_test; do
  .venv/bin/mojo build -I src "tests/$t.mojo" -o ".work/$t" > ".work/$t.build.log" 2>&1 || { echo "FAIL build $t: .work/$t.build.log"; exit 1; }
done
# shellcheck disable=SC2086
${GPU_WRAP:-} .work/ui_test || { echo "FAIL ui_test: compose on the GPU"; exit 1; }
.work/window_test || { echo "FAIL window_test: SDL3 window"; exit 1; }
SDL_AUDIODRIVER=dummy .work/audio_test || { echo "FAIL audio_test: SDL3 audio stream"; exit 1; }
echo "PASS local_gate: ui_test, window_test, audio_test"
