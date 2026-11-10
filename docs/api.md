# API

`from imkit.ui import ...` with `-I src`. Checked by `tests/ui_cpu_test.mojo` (CPU) and `tests/ui_test.mojo`, `tests/window_test.mojo` (local).

| Call | Behaviour |
|---|---|
| `Window(title, w, h, uw=0, uh=0)` | SDL3 window, vsync; `uw x uh` is the UI layer size |
| `win.poll() -> Input` | mouse, wheel, buttons, keys (scancodes < 128), quit |
| `win.present(frame_ptr, ui_ptr=0)` | frame and layer RGBA in host memory |
| `win.key_down(scancode)`, `push(...)` | key held now; synthetic mouse, key and text (`EV_TEXT`, `text=`) events for scripted checks |
| `win.text_input(on)`; `Input.text` | SDL text events on or off; the text typed this frame (UTF-8), joined by `Input.merge` |
| `Font(path, sizes, fallback="")` | glyph atlas from a TrueType font: ASCII 32-126 at start, any other codepoint (UTF-8 text) rasterized on first use, from `fallback` when `path` lacks it, else drawn as `?`; AW x AH atlas (`-DUI_ATLAS_H=`, default 1024), skyline-packed, no eviction (`font.full` counts glyphs that did not fit); `Layer` uploads only the rows rasterized since the last frame |
| `Ui(font)`; `begin(input)`, `finish()` | one frame; `finish` bins commands into 16 x 16 tiles |
| `Ui(font)`; `begin(input, dt=0)`, `finish()` | one frame, `dt` seconds long (0: springs hold still); `finish` bins commands into 16 x 16 tiles |
| `style(c1, mode, gx, gy, sx, sy, sr, sc) -> id`; `srect(x0, y0, x1, y1, r, c, id, border, bcol)` | per-frame style (256 max): fill gradient from `c` to `c1` (mode 1 linear along (gx, gy), 2 radial) and a shadow moved by (sx, sy), blurred sr, color sc; srect draws a rounded rect with it |
| `clip(x0, y0, x1, y1)`, `unclip()` | everything drawn between is cut to the rect (hard edge at pixel centers, one level: a new clip replaces the old; binned only into the rect's tiles) |
| `glass(x0, y0, x1, y1, r, tint)`; `layer.set_scene(px)`, `layer.blur_from(buf)` | rounded rect showing the blurred scene under `tint`: the scene (UW * UH RGBA, opaque) is averaged to 1/4 size and blurred by two triangle passes (18 us on the 7900 XTX); with no scene set the glass shows its tint alone |
| `rrect(x0, y0, x1, y1, r, c, border, bcol, glow, grad)` | rounded rect: border px (0.25 steps, to 63.75) and outside glow px (to 255) in `bcol`, vertical gradient -127..127 (+: top lighter) |
| `panel`, `button`, `icon`, `bar`, `spark`, `text`, `rect`, `line`, `tri`, `image` | widgets and primitives; interaction widgets return clicked; `button(..., on, color)` fills a toggle with `color` (default accent) |
| `field(id, buf, max) -> Bool`; `field_focused` | 360 x 30 text box at the cursor: ASCII 32-126 from `Input.text`, Backspace, at most `max` bytes; True if `buf` changed. A click or the first field drawn takes focus; `field_focused` is True when a drawn field has it (send keys to typing then) |
| `Layer(ctx, ui)`; `render(ui)`, `pixels` | GPU compose on your DeviceContext; refuses an unfinished frame; `render` = `render_into` + `readback` |
| `layer.render_into(ui, buf)`; `layer.readback()` | compose into a caller DeviceBuffer (UW * UH u32) with no 3.7 MB readback: 62 us per frame against 204 us for `render` (7900 XTX, 1280 x 720, 150 commands); `readback()` copies `layer.img` to `pixels` when a host consumer needs it |
| `animate(id, target) -> Float32` | spring value for widget `id` moving to `target`; first sight starts at the target; ids not asked for last frame are evicted (`anim.mojo`) |
| `set_scale(s)`; `w()`, `h()`, `tw(s, size)`, `asc(size)` | DPI: widgets, cursor, hit tests and input are logical, drawn at `s` layer pixels per unit; sizes of the layer and of text in logical units. Build the `Font` with sizes times `s` for sharp text. `Window.scale()`, `drawable()`, `Input.logical(s)` |
| `set_theme(theme)`; `glass()`, `neon()`, `flat()` | every widget colour and shape (radius, roundness, border, shadow) comes from `ui.theme` roles (`theme.mojo`); `button(color=0)` is the theme accent |
| `heading(s, size, w)`, `caption(s, size=0)`, `separator(w)` | a heading in font slot `size` with an accent rule `w` wide; muted small text; a one-pixel rule; each moves the cursor to the next row |
| `badge(label, c, size=0) -> width`, `kv(key, value, w, size=0)` | a pill on colour `c` whose label is black or white for that fill (cursor moves right); a muted key with its value right-aligned at `x + w` |
| `amarbaro()`, `amarbaro_light()` | themes from amarbaro.com's brand tokens: olive accent, 6 px corners, blood-red danger; dark and light |
| `style(name)`, `STYLE_NAMES` (`imkit.styles`) | 29 themes measured from ComfyUI style swatches by `tools/gen_styles.mojo`; every theme passes `imkit.contrast.theme_faults` (text, labels, controls and status colours) |
| `contrast(a, b)`, `theme_faults(t)` (`imkit.contrast`) | WCAG 2 contrast of two colours; empty string when a theme passes, else the failing pairs |
| `slider(id, v, lo, hi, w) -> Float32` | a press captures the mouse; value follows x until release, also outside the track |
| `menu_begin(id, label, w, n) -> Bool`, `menu_item(label) -> Bool`, `menu_end()` | one popup level of `n` items; closes on outside press, Escape, header click or a pick; draw menus last (draw order is z order) |
| `scroll_begin(id, w, h, rows, rh, off) -> (first, end)`, `scroll_row(id, k, label, on)`, `scroll_y(k)`, `scroll_end()` | virtualized list, caller-owned `off` moved by the wheel; rows are clipped to the viewport; cost does not grow with `rows` |
| `table_begin(id, heads, widths, h, rows, rh, off) -> (first, end)`, `table_row`, `table_cell(k, c, text)`, `table_end()` | header plus scroll list; cells cut to their column; data stays yours |
| `plot(vals, lo, hi, w, h, c)` | axes, gridlines, labels; more samples than pixel columns are decimated to one point per column keeping spikes |
| `Layer(ctx, ui)`; `render(ui)`, `pixels` | GPU compose on your DeviceContext; refuses an unfinished frame |
| `layer.set_image(px, w, h, off=0)` | copy a packed `r \| g << 8 \| b << 16 \| a << 24` picture to pool pixel offset `off` (draw with `ui.image(.., off, w, h)`); raises past `UI_IMG` pixels or when it would overwrite the `set_assets` atlas (use `off >= len(assets.px)`) |
| `Audio(rate)`; `put`, `queued` | SDL3 mono float32 playback stream |

Capacities: 4096 commands, `UI_BINS` tile entries (32,768), `UI_IMG` image pixels (65,536). Past a capacity whole commands
drop and `ui.d.dropped` counts them.

## Asset atlas

Bad input (v0.8.1): a NaN coordinate drops its command (counted in `ui.d.dropped`), infinite and huge ones clamp to +-1e6; a font size index the `Font` lacks draws nothing (counted) and measures 0; `scroll_begin` reads a row height of 0, negative, NaN or inf as 1; axis labels print `nan`, `>1e9`, `<-1e9`; `png_decode` raises `png: IHDR chunk is N bytes` and `png: W x H is too large` (64 M pixels) before allocating; `clip` ends the clip in force before starting a new one (one extra command); `Font` takes up to 256 sizes.

JPEG (`imkit.jpeg`, pure Mojo, no library): `jpeg_decode(bytes) -> (w, h, pixels)` takes baseline, extended-sequential and progressive Huffman files, 8-bit, 1 (grey, expanded to RGB) or 3 (YCbCr, or RGB when the Adobe flag or component ids say so) components, any 1 to 4 sampling factors, restart markers; arithmetic coding, lossless, 12-bit and CMYK raise `jpeg: ...`. Output is bit-identical to libjpeg-turbo 3.2.1 (ISLOW IDCT, fancy upsampling) on the 27 gate fixtures. `image_decode(bytes)` picks the decoder by signature (FF D8 JPEG, else PNG; a RIFF....WEBP file raises `webp: no decoder in this build yet` until `imkit.webp` is merged), and `pack` calls it, so an atlas can mix PNGs and JPEGs. Same 64 M pixel guard as `png_decode`, checked before any allocation. Checks: `tests/jpeg_test.sh` (ImageMagick writes fixtures and goldens, never run time).

WebP (`imkit.webp`, pure Mojo, no library): `webp_decode(bytes) -> (w, h, pixels)` takes lossless (VP8L, all transforms, colour cache), lossy
(VP8 key frames) and alpha (ALPH, raw or lossless, with filters); animation raises. `image_decode(bytes)` picks PNG, JPEG or WebP by signature,
and `pack` uses it, so atlases take all three.

`python3 tools/png_fixture.py` writes the test fixtures. `mojo run -I src tools/pack_atlas.mojo assets/atlas assets/src/*.png` packs 8-bit RGB/RGBA PNGs (Blender icons, ComfyUI textures) into `assets/atlas.bin` (RGBA bytes) and `assets/atlas.txt` (`name offset width height`, name = file stem). At run time: `ui.assets = Assets("assets/atlas")`, `layer.set_assets(ui.assets)` once (copies to the image pool from offset 0; a `set_image` picture below `len(assets.px)` makes it raise, so give `set_image` an offset past the atlas), then `ui.icon_img("play", x, y)` each frame (own size, or `w, h` to scale; `alpha`); an unknown name returns False and counts in `ui.d.dropped`.
