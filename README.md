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
| `imkit.layer` | `Layer(ctx, ui)`: the GPU side on your DeviceContext; `render_into(ui, dev_buf)` composes into your own device buffer (no readback), `render(ui)` also fills the pinned `pixels`; `set_image`, `set_assets`, `set_scene`/`blur_from` (glass backdrop). Scene and pinned buffers are allocated on first use |
| `imkit.font` | UTF-8 text from a TrueType font plus an optional fallback (CJK); glyphs rasterized on demand into a skyline atlas, only the rows in use held on the host |
| `imkit.draw` | `Draw` (`ui.d`): the command list, tile binning, the `compose` kernel; counters `ui.d.n`, `ui.d.dropped` |
| `imkit.ui` | `Ui`: `begin(input, dt)`, `panel`, `glass`, `button`, `icon`, `icon_img`, `bar`, `spark`, `text`, `field`, `slider`, `menu_*`, `scroll_*`, `table_*`, `plot`, `rect`, `rrect`, `srect`, `line`, `tri`, `image`, `clip`/`unclip`, `animate`, `set_theme`, `set_scale`, `finish()` |
| `imkit.atlas`, `imkit.assets` | skyline packer for the glyph atlas; PNG asset atlas (`pack`, `Assets`, `png_decode`) |
| `imkit.theme` | `Theme` roles and the presets `glass()`, `neon()`, `flat()`; the module constants are the glass values |

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
`scripts/mutants.sh` plants known bugs in a copy of `src` (field maximum, text join, `push` NaN guard, image/asset overwrite, ...); each must fail its test, and `ci.sh` dry-runs them so a stale mutant fails CI.
`scripts/local_gate.sh` (run locally, GitHub runners have no GPU or display): `ui_test` composes on the GPU and checks
pixels, `window_test` opens a real SDL3 window. Last local run (v0.8.1) on an RX 7900 XTX (gfx1100), KDE Wayland: `PASS local_gate` (ui_test, window_test, audio_test).

## Performance

RX 7900 XTX, 1280 x 720, 150 commands (v0.8.1): compose about 17 us per launch; `render_into` 62 to 80 us per frame
(no readback), `render` about 210 us including the 3.7 MB copy back. Memory at `Layer` creation for a `render_into` app:
5.6 MB (was 13.5 MB in v0.8.0); through SDL `render()`, 9.3 MB. Numbers move with GPU clocks and load; `tools/membench`
and `tools/uibench` print them. Design and budgets:
[docs/design.md](docs/design.md), API: [docs/api.md](docs/api.md).

## Limits

- No text shaping (Arabic, Indic), bidi or emoji color; the glyph atlas does not evict (a full atlas draws `?`, counted in `font.full`).
- `Ui.field` is one line: append and Backspace on UTF-8 code points; no cursor movement, selection, paste or key repeat. No docking.
- Glass blur needs the app's scene (`set_scene` or `blur_from`). PNG loader: 8-bit RGB/RGBA, not interlaced, CRC not checked.
- Needs a GPU MAX supports for `Layer`; only gfx1100 was tested. Struct offsets are those of SDL 3.4 and FreeType 2.14.
- Key scancodes below 128 only. CI covers the CPU side; the compose kernel, window and audio are checked locally.
