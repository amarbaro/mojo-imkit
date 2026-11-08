# API

`from imkit.ui import ...` with `-I src`. Checked by `tests/ui_cpu_test.mojo` (CPU) and `tests/ui_test.mojo`, `tests/window_test.mojo` (local).

| Call | Behaviour |
|---|---|
| `Window(title, w, h, uw=0, uh=0)` | SDL3 window, vsync; `uw x uh` is the UI layer size |
| `win.poll() -> Input` | mouse, wheel, buttons, keys (scancodes < 128), quit |
| `win.present(frame_ptr, ui_ptr=0)` | frame and layer RGBA in host memory |
| `win.key_down(scancode)`, `push(...)` | key held now; synthetic mouse, key and text (`EV_TEXT`, `text=`) events for scripted checks |
| `win.text_input(on)`; `Input.text` | SDL text events on or off; the text typed this frame (UTF-8), joined by `Input.merge` |
| `Font(path, sizes)` | glyph atlas from a TrueType font, ASCII 32-126 |
| `Ui(font)`; `begin(input)`, `finish()` | one frame; `finish` bins commands into 16 x 16 tiles |
| `panel`, `button`, `icon`, `bar`, `spark`, `text`, `rect`, `line`, `tri`, `image` | widgets and primitives; interaction widgets return clicked; `button(..., on, color)` fills a toggle with `color` (default accent) |
| `field(id, buf, max) -> Bool`; `field_focused` | 360 x 30 text box at the cursor: ASCII 32-126 from `Input.text`, Backspace, at most `max` bytes; True if `buf` changed. A click or the first field drawn takes focus; `field_focused` is True when a drawn field has it (send keys to typing then) |
| `Layer(ctx, ui)`; `render(ui)`, `pixels` | GPU compose on your DeviceContext; refuses an unfinished frame |
| `layer.set_image(px, w, h)` | copy a packed `r \| g << 8 \| b << 16 \| a << 24` picture to pool offset 0 (draw with `ui.image(.., 0, w, h)`); raises over `UI_IMG` pixels |
| `Audio(rate)`; `put`, `queued` | SDL3 mono float32 playback stream |

Capacities: 4096 commands, `UI_BINS` tile entries (32,768), `UI_IMG` image pixels (65,536). Past a capacity whole commands
drop and `ui.dropped` counts them.
