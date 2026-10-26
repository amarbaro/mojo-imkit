# API

`from imkit.ui import ...` with `-I src`. Checked by `tests/ui_cpu_test.mojo` (CPU) and `tests/ui_test.mojo`, `tests/window_test.mojo` (local).

| Call | Behaviour |
|---|---|
| `Window(title, w, h, uw=0, uh=0)` | SDL3 window, vsync; `uw x uh` is the UI layer size |
| `win.poll() -> Input` | mouse, wheel, buttons, keys (scancodes < 128), quit |
| `win.present(frame_ptr, ui_ptr=0)` | frame and layer RGBA in host memory |
| `win.key_down(scancode)`, `push(...)` | key held now; synthetic events for scripted checks |
| `Font(path, sizes)` | glyph atlas from a TrueType font, ASCII 32-126 |
| `Ui(font)`; `begin(input)`, `finish()` | one frame; `finish` bins commands into 16 x 16 tiles |
| `panel`, `button`, `icon`, `bar`, `spark`, `text`, `rect`, `line`, `tri`, `image` | widgets and primitives; interaction widgets return clicked |
| `Layer(ctx, ui)`; `render(ui)`, `pixels` | GPU compose on your DeviceContext; refuses an unfinished frame |
| `Audio(rate)`; `put`, `queued` | SDL3 mono float32 playback stream |

Capacities: 4096 commands, `UI_BINS` tile entries (32,768), `UI_IMG` image pixels (65,536). Past a capacity whole commands
drop and `ui.dropped` counts them.
