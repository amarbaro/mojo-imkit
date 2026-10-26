---
name: mojo-imkit
description: "Immediate-mode GUI for Mojo apps drawn by one GPU compose kernel: panels, buttons, bars, text, images over an app's own frame, SDL3 window, FreeType text. Use when a Mojo GPU app needs run controls or telemetry overlays."
---

# mojo-imkit

## Install
`uv sync`; needs system SDL3 and FreeType. `mojo build -I <repo>/src app.mojo`.

## Use
Per frame: `inp = win.poll()`, `ui.begin(inp)`, widgets (`ui.panel`, `ui.icon`, `ui.button`, `ui.bar`, `ui.text`),
`ui.finish()`, `layer.render(ui)`, `win.present(frame_ptr, Int(layer.pixels.unsafe_ptr()))`. See `examples/quickstart.mojo`.

## Rules
- Immediate mode: a widget is a call that returns its interaction; give each a stable Int id.
- Always call `finish()` before `render`; `render` raises otherwise.
- Capacities overflow by dropping whole commands, counted in `ui.dropped`; assert it is 0.
- No allocation between `begin` and `finish`. One kernel, one 8-word command layout.
- ASCII only; scancodes below 128.
