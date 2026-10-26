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
- **One draw list.** Every command is 8 u32 words: kind, x0, y0, x1, y1, r, rgba, aux. Kinds: rounded rect (r =
  radius, aux = soft-shadow blur), glyph (aux = atlas x | y << 16), capsule line (r = half width), triangle (either
  winding), image (r = offset into the source pixels, rgba = alpha in the top byte, aux = source width | height << 16;
  nearest sampling over the rect). At most NCMD = 4096 commands.
- **Images.** The app owns what an image shows: it writes RGBA (straight alpha) into the source buffer (`Layer.src`,
  ISRC = `-DUI_IMG` pixels, default 65,536) and calls `Ui.image(rect, off, sw, sh)` each frame; a source past ISRC is
  dropped and counted. A live view (a GPU-rendered picture) is copied device to device into it, never via the host.
- **Tiles.** The host bins commands into 16 x 16 pixel tiles as one compact list: count per tile, prefix sum into
  `off` (tile t's commands are `bins[off[t]:off[t + 1]]`), fill in draw order. At most NBIN = `-DUI_BINS` entries
  (default 32,768; a command counts once per tile it touches); past it the remaining commands drop whole and are
  counted, so no tile is ever drawn with part of its list. `compose` runs one thread per UI pixel and walks only its
  tile's commands, in order: SDF anti-aliasing, alpha over.
- **Text.** FreeType renders ASCII 32-126 at each size once into a 512-wide alpha atlas (60,928 B for 13/16/22 px);
  no shaping, Latin only.
- **Window.** SDL3 letterboxes both textures to the window and maps the mouse back to UI pixels. `Input.merge` folds
  frames polled between two UI frames, so no click is lost when the UI is drawn every few app iterations. With
  `scripted` set, real mouse events are ignored and only `push()`ed events count (checks that drive the window).

## Layer ownership

`Layer(ctx, ui)` lives on the app's own DeviceContext (an engine passes its context; the UI shares its stream) and
owns the draw-list, bins, offsets, atlas, image-source and RGBA device buffers and a pinned host RGBA buffer. The
atlas comes from `ui`, so layer and UI cannot disagree on the font; an atlas over `AW * AH` is refused. After
`Ui.finish()`, `layer.render(ui)` uploads only what the frame used (n commands, its tile entries, the offsets),
launches compose, copies the layer into `pixels` and synchronizes. It refuses a frame that was not finished (stale
bins would draw the last frame's tiles). `pixels` is reused each frame (`Window.present(frame,
Int(layer.pixels.unsafe_ptr()))`). The kernel is asked from `ctx.compile_function` per launch: the runtime caches it
(measured 7.6 to 7.9 us per launch vs 8.3 to 9.8 held in a field), so no type tricks hold a function in the struct.

## Budgets

| buffer | bytes |
|---|---|
| draw list 4096 x 8 x u32 | 128 KB |
| tile bins NBIN x u16 (default 32,768) | 64 KB |
| tile offsets (80 x 45 + 1) x u32 | 14 KB |
| atlas 512 x 256 x u8 (device) | 128 KB |
| image sources ISRC x u32 (device, default 65,536) | 256 KB |
| layer 1280 x 720 x u32 (device) | 3.7 MB |
| Layer pinned host RGBA 1280 x 720 x u32 | 3.7 MB |

All allocated once. Per frame: the used commands + tile entries + offsets up (150 commands, 2,197 entries: 23 KB,
was a fixed 602 KB), one compose launch, one layer copy back (3.7 MB, most of render's ~207 us), one texture upload.

## Not yet

Docking (drag, resize, snap, collapse, saved layout), plots with axes, slider and text input, menus, DPI scaling.
