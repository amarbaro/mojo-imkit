# imkit design

## Frame

```
app frame (GPU) ─────────────────────────────────────────────┐
window.poll ─► Input ─► Ui.begin ─► widgets ─► draw list ──┐ │
                                    (host, every frame)    │ │
Ui.finish: bin commands into 16 x 16 tiles ◄───────────────┘ │
copy cmd + bins + counts ─► compose kernel ─► UW x UH RGBA   │
window.present: scene texture (blend NONE) + UI layer (BLEND)◄┘
```

- **Immediate mode.** A widget is a call that draws and returns its interaction (`button(...) -> Bool`). Identity is
  an Int id the caller gives; hot (under the mouse) and active (pressed, waiting for the release) are the only state.
  A click is press then release on the same widget.
- **One draw list.** Every command is 8 u32 words: kind, x0, y0, x1, y1, r, rgba, aux (`Draw` in draw.mojo; `Ui` in ui.mojo
  holds it as `ui.d` and keeps the widgets). Kinds: rounded rect (r = radius, aux = soft-shadow blur), glyph (aux = atlas
  x | y << 16), capsule line (r = half width), triangle (either winding), image (r = offset into the source pixels, rgba =
  alpha in the top byte, aux = source width | height << 16; nearest sampling over the rect), RRECT (kind word = kind |
  border px * 4 << 8 | glow px << 16 | gradient i8 << 24; aux = border and glow rgba), SRECT (kind word | style id << 16: a
  per-frame `Style` of 8 words gives a linear or radial gradient and a shadow of the shape moved by an offset), GLASS (the
  blurred scene under a tint), CLIP (a state command: later commands are cut to its rect until the matching end
  command). Effects that are functions of distance (border, glow, gradient, shadow) live in the one compose pass; the
  pure per-pixel functions (`rrect`, `srect`, `glass`, `clipped`) are shared with the CPU tests. At most NCMD = 4096 commands.
- **Backdrop.** `Layer.set_scene(px)` / `blur_from(buf)` average the app's frame to 1/4 size and run two separable triangle
  passes (BR = 6 taps at 1/4 resolution, 18 us on the 7900 XTX); GLASS samples the result bilinearly. It is the only extra pass.
- **Clip.** `clip(rect)` ... `unclip()`: compose keeps one clip rect per thread (hard edge at pixel centers); `finish` cuts a
  clipped command's tiles to the clip's tiles. One level: a new clip replaces the old.
- **Images.** The app owns what an image shows: it writes RGBA (straight alpha) into the source buffer (`Layer.src`,
  ISRC = `-DUI_IMG` pixels, default 65,536) and calls `Ui.image(rect, off, sw, sh)` each frame; a source past ISRC is
  dropped and counted. A live view (a GPU-rendered picture) is copied device to device into it, never via the host.
- **Tiles.** The host bins commands into 16 x 16 pixel tiles as one compact list: count per tile, prefix sum into
  `off` (tile t's commands are `bins[off[t]:off[t + 1]]`), fill in draw order. At most NBIN = `-DUI_BINS` entries
  (default 32,768; a command counts once per tile it touches); past it the remaining commands drop whole and are
  counted, so no tile is ever drawn with part of its list. `compose` runs one thread per UI pixel and walks only its
  tile's commands, in order: SDF anti-aliasing, alpha over.
- **Text.** UTF-8, one glyph per codepoint, no shaping. FreeType renders ASCII 32-126 at each size at start; any other
  codepoint is rasterized once per size on first use (the font, else the fallback font, else `?`; a full atlas also gives
  `?`), cached, and skyline-packed (atlas.mojo) into a 512 x 1024 alpha atlas (`-DUI_ATLAS_H=`). 13/16/22 px ASCII needs 87
  rows. `Layer` uploads only the rows rasterized since the last frame. No eviction.
- **Assets.** `tools/pack_atlas` packs PNGs offline (Blender icons, ComfyUI textures) into `.bin` + `.txt`; `Assets` loads them,
  `Layer.set_assets` copies them into the image pool, `Ui.icon_img(name, x, y)` draws one.
- **Window.** SDL3 letterboxes both textures to the window and maps the mouse back to UI pixels. `Input.merge` folds
  frames polled between two UI frames, so no click is lost when the UI is drawn every few app iterations. With
  `scripted` set, real mouse events are ignored and only `push()`ed events count (checks that drive the window).

## Layer ownership

`Layer(ctx, ui)` lives on the app's own DeviceContext (an engine passes its context; the UI shares its stream) and
owns the draw-list, bins, offsets, atlas, image-source and RGBA device buffers and a pinned host RGBA buffer. The
atlas comes from `ui`, so layer and UI cannot disagree on the font; an atlas over `AW * AH` is refused. After
`Ui.finish()`, `layer.render_into(ui, buf)` uploads only what the frame used (n commands, its tile entries, the offsets,
styles, new glyph rows), launches compose into a caller's device buffer and synchronizes: 62 us a frame. `layer.render(ui)` is
that into the layer's own buffer plus `readback()`, the 3.7 MB copy into `pixels` (204 us), which only a host consumer needs. It refuses a frame that was not finished (stale
bins would draw the last frame's tiles). `pixels` is reused each frame (`Window.present(frame,
Int(layer.pixels.unsafe_ptr()))`). The kernel is asked from `ctx.compile_function` per launch: the runtime caches it
(measured 7.6 to 7.9 us per launch vs 8.3 to 9.8 held in a field), so no type tricks hold a function in the struct.

## Budgets

| buffer | bytes |
|---|---|
| draw list 4096 x 8 x u32 | 128 KB |
| tile bins NBIN x u16 (default 32,768) | 64 KB |
| tile offsets (80 x 45 + 1) x u32 | 14 KB |
| atlas 512 x 1024 x u8 (device 512 KB; host only the rows in use, in steps of 64: 64 KB for ASCII at three sizes) | 512 KB + 64 KB |
| styles 256 x 8 x u32 | 8 KB |
| backdrop 3 x 320 x 180 x u32 | 0.7 MB |
| scene copy 1280 x 720 x u32, allocated by the first `set_scene` | 0 or 3.7 MB |
| image sources ISRC x u32 (device, default 65,536) | 256 KB |
| layer 1280 x 720 x u32 (device) | 3.7 MB |
| Layer pinned host RGBA 1280 x 720 x u32, allocated by the first `readback()` / `render()` | 0 or 3.7 MB |

Allocated once (the scene copy and the pinned `pixels` on first use). A demo frame allocates nothing on the host heap (0 mallocs for
build + finish); `render_into` makes 12 small ones (3.8 KB) inside the runtime. Per frame: the used commands + tile entries + offsets up (150 commands, 2,197 entries: 23 KB,
was a fixed 602 KB), one compose launch, a layer copy back only when asked (3.7 MB, most of `render`'s ~204 us), one texture upload.

## Not yet

Docking (drag, resize, snap, collapse, saved layout), plots with axes, slider and text input, menus, DPI scaling (lane B), Unicode shaping, atlas eviction.
Docking (drag, resize, snap, collapse, saved layout), plots with axes, slider and text input, menus, DPI scaling.

## Widgets, theme, animation, DPI (lane B)

- **Theme.** `Ui.theme` holds colours by role (panel, surface, hover, accent, on_accent, good, warn, bad, text, muted,
  shadow, border) and shape knobs (panel radius, control roundness, border width, shadow softness). Widgets read roles
  only; a preset is one `set_theme`. Contrast of the text pairs (4.5) and bars (3) is a test.
- **Animation.** `anim.mojo` keeps `id -> (value, velocity)` in one flat table; `animate(id, target)` steps a damped
  spring with the frame's `dt` (clamped to 1/20 s). An id nobody asked for in the last frame is evicted.
- **DPI.** Everything a caller touches is logical. `Ui` multiplies by `scale` where it forwards to `Draw`, and
  `begin` converts the mouse back with `Input.logical`; the compose kernel never sees the scale. Text origins snap to
  whole layer pixels.
- **Interaction state.** `active` (the pressed widget) doubles as the drag capture for `slider`; one open `menu` id;
  scroll offsets belong to the caller. Lists emit only the rows that touch the viewport, between one clip pair.

