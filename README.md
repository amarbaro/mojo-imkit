# mojo-imkit

<!-- badges -->
[![ci](https://github.com/amarbaro/mojo-imkit/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/amarbaro/mojo-imkit/actions/workflows/ci.yml) [![latest release](https://img.shields.io/github/v/release/amarbaro/mojo-imkit)](https://github.com/amarbaro/mojo-imkit/releases/latest) [![license](https://img.shields.io/github/license/amarbaro/mojo-imkit)](https://github.com/amarbaro/mojo-imkit/blob/main/LICENSE)
<!-- /badges -->

An immediate-mode GUI for Mojo apps, drawn by the GPU. It takes the idea behind Dear ImGui and imgui-bundle (widgets
are function calls made every frame, no retained widget tree) and builds it in Mojo around a GPU app's own frame:
widgets append to one flat draw list, one `compose` kernel turns that list into an RGBA layer, and the window blends
the layer over the app's picture. No Python UI process, no C++ library, no bundled windowing: the system's SDL3 and
FreeType are called through Mojo's FFI.

Install: `pixi workspace channel add https://conda.modular.com/max https://prefix.dev/amarbaro/amarbaro`, then `pixi add mojo-imkit` (import `imkit`). From source: `git clone https://github.com/amarbaro/mojo-imkit`, then `mojo run -I mojo-imkit/src app.mojo`.
Toolchains: Mojo 1.2 stable, and the nightly 1.3.0.dev2026110805 in the weekly [mojo-libs](https://github.com/amarbaro/mojo-libs) matrix (36 libraries on stable, 35 on nightly).


## Modules

| module | what it does |
|---|---|
| `imkit.window` | SDL3 window, vsync, letterboxed streaming texture; `poll() -> Input` (mouse, wheel, buttons, keys, typed text, quit), `text_input(on)`, `present(frame, ui)`, `push()` synthetic mouse, key and text events for scripted checks |
| `imkit.layer` | `Layer(ctx, ui)`: the GPU side on your DeviceContext (buffers, atlas from `ui`, image sources `src`); `render(ui)` after `Ui.finish()` uploads only what the frame used and fills the pinned `pixels`; `set_image(px, w, h)` copies one picture to the image pool (`-DUI_IMG=` sizes it) |
| `imkit.font` | glyph atlas from a TrueType font (ASCII 32-126, a few pixel sizes, alpha8), built once at start |
| `imkit.ui` | `Ui`: `begin(input)`, `panel`, `button`, `icon`, `bar`, `spark`, `text`, `field` (single-line text box), `rect`, `line`, `tri`, `image`, `finish()`; the `compose` kernel; a dark theme |

## Use

```mojo
"""A headless frame: widgets with a scripted click, no window and no GPU. Prints what the frame produced.

usage: IMKIT_FONT=/path/font.ttf mojo run -I src examples/quickstart.mojo  (default font: Roboto Medium)
"""
from std.os import getenv
from imkit.font import Font
from imkit.ui import TX, TY, Ui
from imkit.window import Input


def frame(mut ui: Ui, inp: Input) -> Bool:
    ui.begin(inp)
    ui.panel(20, 16, 300, 100, "Run")
    var clicked = ui.icon(1, 1)  # 0 play, 1 pause, 2 step, 3 stop
    ui.finish()  # bins the commands into 16 x 16 tiles for the compose kernel
    return clicked


def main() raises:
    var ui = Ui(Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22]))
    var keys = SIMD[DType.uint64, 2](0)
    # the pause icon sits at (36, 56) to (72, 92): press and release on it
    var press = Input(50, 70, 0, 0, 0, 1, 1, 0, keys, False)
    var release = Input(50, 70, 0, 0, 0, 0, 0, 1, keys, False)
    var before = frame(ui, press)
    var clicked = frame(ui, release)
    print("click after press:", before, "after release:", clicked)
    print("commands:", ui.n, "tile entries:", Int(ui.off[TX * TY]), "dropped:", ui.dropped)
    if before or not clicked or ui.dropped != 0 or ui.n == 0:
        raise Error("quickstart: the click or the draw list is wrong")
```

## Install

Mojo 1.2 and MAX 26.7 from `uv sync`; system `libSDL3.so.0` (3.4) and `libfreetype.so.6` (2.14); a TrueType font
(Roboto Medium by default, `IMKIT_FONT` overrides). Use it with `mojo build -I path/to/mojo-imkit/src app.mojo` or
`mojo precompile src/imkit -o imkit.mojoc`. A headless example: `examples/quickstart.mojo`.

## Verified

`scripts/ci.sh` (no GPU, no display): precompile, build of every test, `font_test` (glyph atlas), `ui_cpu_test` (click =
press then release, tile bins, overflow drops counted, text fields, image fit; a mutant of the click rule fails it) and the quickstart.
`scripts/mutants.sh` breaks the field maximum and the text join of `Input.merge` in a copy of `src`; each must fail its test.
`scripts/local_gate.sh` (run locally, GitHub runners have no GPU or display): `ui_test` composes on the GPU and checks
pixels, `window_test` opens a real SDL3 window. Last local run on an RX 7900 XTX (gfx1100), KDE Wayland: `PASS ui_test`.

## Performance

RX 7900 XTX, 1280 x 720, 150 commands, one run of `ui_test`: compose 25.8 us per launch, render 194 us per frame
including the 3.7 MB layer copy back. Buffers (allocated once): draw list 128 KB, tile bins 64 KB, atlas 128 KB on the
card. An earlier run measured compose at 17.7 us; the number moves with GPU clocks and load. Design and budgets:
[docs/design.md](docs/design.md), API: [docs/api.md](docs/api.md).

## Limits

- ASCII text only, no shaping; no docking, axes plots, sliders, menus or DPI scaling. `Ui.field` is one ASCII line (append, Backspace; no cursor movement, selection, paste or key repeat).
- Needs a GPU MAX supports for `Layer`; only gfx1100 was tested. Struct offsets are those of SDL 3.4 and FreeType 2.14.
- Key scancodes below 128 only. `Audio` (mono float playback) has no automated check.
- CI covers the CPU side only; the compose kernel and the window are checked locally.
