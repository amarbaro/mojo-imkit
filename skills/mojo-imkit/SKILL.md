---
name: mojo-imkit
description: "Immediate-mode GUI for Mojo apps drawn by one GPU compose kernel: panels, buttons, bars, text, images over an app's own frame, SDL3 window, FreeType text. Use when a Mojo GPU app needs run controls or telemetry overlays."
---

# mojo-imkit

## Install
`uv sync`; needs system SDL3 and FreeType. `mojo build -I <repo>/src app.mojo`.

## Use
Per frame: `inp = win.poll()`, `ui.begin(inp, dt)`, widgets (`panel`, `glass`, `button`, `slider`, `menu_*`, `scroll_*`,
`table_*`, `plot`, `text`), `ui.finish()`, then either `layer.render_into(ui, my_dev_buf)` (GPU app, no readback) or
`layer.render(ui)` + `win.present(frame_ptr, Int(layer.pixels.unsafe_ptr()))`. See `examples/quickstart.mojo`, `examples/gallery.mojo`.

## Rules
- Immediate mode: a widget is a call that returns its interaction; give each a stable Int id.
- Always call `finish()` before `render`; `render` raises otherwise.
- Capacities overflow by dropping whole commands, counted in `ui.d.dropped`; assert it is 0. NaN commands drop, infinite coordinates clamp.
- No allocation between `begin` and `finish`. One kernel, one 8-word command layout.
- UTF-8 text (CJK via `Font(path, sizes, fallback=...)`), no shaping; scancodes below 128.
- Themes: `ui.set_theme(glass()|neon()|flat())`; widgets read theme roles, `button(color=0)` = accent. DPI: `ui.set_scale(win.scale())`, `inp.logical(scale)`.
- Glass needs the scene: `layer.set_scene(...)` or `blur_from`; without it the backdrop is empty.

## Large image
Build with `-DUI_IMG=<pixels>` (default 65,536; a 2560 x 1440 window view is 3,686,400). Per picture: scale or crop to the view on
the CPU into a `List[UInt32]` (packed `r | g << 8 | b << 16 | a << 24`), `layer.set_image(Span(px), w, h)` (raises if
`w * h > UI_IMG`), then each frame `ui.image(x0, y0, x1, y1, 0, w, h)`. Re-upload only when the picture or the crop changes.

## Typing
`win.text_input(True)` while a field is on screen (off after), `ui.field(id, buf, max)` each frame, and send keys to the field
instead of shortcuts while `ui.field_focused`. Enter and Esc are yours: `field` only edits `buf`. Scripted: `win.push(EV_TEXT, text="ab")`.
