"""UI and Layer check (GPU, under gpu-wait): a top bar and a fly card built from widgets with scripted input, composed on the
card by Layer. Gates: the pause icon reports a click after press + release on it (and not elsewhere), no command dropped,
a panel pixel has the panel's alpha, a pixel outside every panel is transparent, icon shapes, an image sampled where it
belongs, an empty frame clears the layer, re-rendering gives the same pixels at the same address, render before finish
raises, a frame past NBIN tile entries drops whole commands (counted) and still renders, an oversized atlas is refused.
compose and render timed. OUT (.ppm) gets the layer blended over a test background for a look.

usage: mojo run -I src tests/ui_test.mojo [OUT.ppm]
"""
from std.os import getenv
from std.sys import argv
from std.time import perf_counter_ns
from max.gpu.host import DeviceContext
from imkit.font import AW, Font
from imkit.ui import ACCENT, AH, BAD, GOOD, ISRC, NBIN, TEXT, TX, TY, UH, UW, WARN, Ui
from imkit.window import Input
from imkit.layer import Layer


def frame(mut ui: Ui, inp: Input) -> Bool:
    """The demo layout; returns whether the pause icon was clicked."""
    ui.begin(inp)
    ui.panel(24, 20, 520, 96, "Run")
    _ = ui.icon(1, 0)
    var paused = ui.icon(2, 1, True)
    _ = ui.icon(3, 2)
    _ = ui.icon(4, 3)
    _ = ui.text(ui.x + 8, 58, "t 12.40 s   0.31x   62 fps", 0, TEXT)
    ui.panel(Float32(UW - 340), 20, Float32(UW - 24), 330, "Fly 1  walk")
    var names: List[String] = ["W", "A", "D", "space", "threat"]
    for k in range(5):
        _ = ui.button(10 + k, names[k], Float32(44 if k < 3 else 60), 28, k == 0)
    ui.x, ui.y = Float32(UW - 324), Float32(112)
    ui.bar("energy", 0.82, GOOD, 280)
    ui.bar("health", 0.95, ACCENT, 280)
    ui.bar("stamina", 0.41, WARN, 280)
    var vals = List[Float32]()
    for k in range(64):
        vals.append(Float32(k % 17) / 17 + Float32(k) / 128)
    ui.spark(vals, 0, 1.5, 284, 60, BAD)
    ui.finish()
    return paused


def main() raises:
    var ui = Ui(Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22]))
    var fails = 0
    var idle = Input(300, 300, 0, 0, 0, 0, 0, 0, SIMD[DType.uint64, 2](0), False)
    var press = Input(102, 78, 0, 0, 0, 1, 1, 0, SIMD[DType.uint64, 2](0), False)  # on the pause icon (2nd icon)
    var release = Input(102, 78, 0, 0, 0, 0, 0, 1, SIMD[DType.uint64, 2](0), False)
    var c0 = frame(ui, idle)
    var c1 = frame(ui, press)
    var c2 = frame(ui, release)
    var c3 = frame(ui, release)  # a release with nothing active is no click
    print("clicks idle/press/release/again:", c0, c1, c2, c3, "commands", ui.n, "tile entries", Int(ui.off[TX * TY]), "dropped", ui.dropped)
    if c0 or c1 or not c2 or c3 or ui.dropped:
        fails += 1
    var ctx = DeviceContext()
    var layer = Layer(ctx, ui)
    layer.render(ui)
    var host = List[UInt32](length=UW * UH, fill=0)  # the reference frame
    for i in range(UW * UH):
        host[i] = layer.pixels[i]
    var pixel_ptr = Int(layer.pixels.unsafe_ptr())
    var t0 = perf_counter_ns()
    for _ in range(1000):
        layer.launch()
    ctx.synchronize()
    var us = Float64(perf_counter_ns() - t0) / 1000 / 1000
    t0 = perf_counter_ns()
    for _ in range(200):
        layer.render(ui)
    var render_us = Float64(perf_counter_ns() - t0) / 200 / 1000
    print("compose", us, "us per launch,", "render", render_us, "us per frame including transfers, at", UW, "x", UH)
    # an empty frame clears, the scene again matches the reference at the same address
    ui.begin(idle)
    ui.finish()
    layer.render(ui)
    for i in range(UW * UH):
        if layer.pixels[i] != 0:
            print("FAIL empty frame left pixel", i)
            fails += 1
            break
    _ = frame(ui, release)
    layer.render(ui)
    var diff = 0
    for i in range(UW * UH):
        if host[i] != layer.pixels[i]:
            diff += 1
    if diff or Int(layer.pixels.unsafe_ptr()) != pixel_ptr:
        print("FAIL re-render: pixels differ", diff)
        fails += 1
    var inside = host[60 * UW + 400] >> 24  # inside the Run panel, away from widgets
    var outside = host[600 * UW + 600] >> 24
    print("panel alpha", inside, "outside alpha", outside)
    if inside < 225 or inside > 240 or outside != 0:  # the glass panel (alpha 214) over its own soft shadow
        fails += 1
    # icon shapes (Run panel cursor x 40, y 60; icons 36 wide, 44 apart; centre +18): play triangle, pause bars
    var lum = lambda (p: UInt32) -> Int: Int(p & 255) + Int((p >> 8) & 255) + Int((p >> 16) & 255)
    var play = lum(host[78 * UW + 57])
    var bar_l = lum(host[78 * UW + 98])
    var gap = lum(host[78 * UW + 102])
    var bar_r = lum(host[78 * UW + 106])
    print("icon luminance: play centre", play, "pause bars", bar_l, bar_r, "gap", gap)
    if play < 600 or bar_l < 600 or bar_r < 600 or gap > 500:  # text-white shapes (sum ~687) on the surface or accent (sum 442)
        fails += 1
    if len(argv()) > 1:  # the layer over a test background, as SDL blends it
        var ppm = List[UInt8](capacity=UW * UH * 3)
        for i in range(UW * UH):
            var p = host[i]
            var a = Float32(p >> 24) / 255
            var bg: List[Float32] = [Float32(60 + (i % UW) * 80 // UW), Float32(90 + (i // UW) * 60 // UH), 70]
            for ch in range(3):
                ppm.append(UInt8(Float32((p >> UInt32(8 * ch)) & 255) * a + bg[ch] * (1 - a)))
        with open(String(argv()[1]), "w") as o:
            o.write("P6\n" + String(UW) + " " + String(UH) + "\n255\n")
            o.write_bytes(Span(ppm))
    # image: a 4 x 4 source at offset 7, drawn 2x into (200, 400)-(208, 408); nearest sampling, outside untouched
    var srcpx = List[UInt32](length=16, fill=0)
    for j in range(16):
        srcpx[j] = UInt32(16 * j) | UInt32(255 - 16 * j) << 8 | UInt32(77) << 16 | UInt32(255) << 24
    ctx.enqueue_copy(layer.src.create_sub_buffer[DType.uint32](7, 16), srcpx.unsafe_ptr())
    ui.begin(idle)
    ui.image(200, 400, 208, 408, 7, 4, 4)
    ui.image(0, 0, 8, 8, ISRC - 3, 4, 4)  # source past the buffer: dropped and counted, not drawn
    ui.finish()
    var dropped0 = ui.dropped
    layer.render(ui)
    var near = lambda (p: UInt32, q: UInt32) -> Bool: abs(Int(p & 255) - Int(q & 255)) <= 1 and abs(Int((p >> 8) & 255) - Int((q >> 8) & 255)) <= 1 and (p >> 24) == 255
    var tl = layer.pixels[401 * UW + 201]
    var br = layer.pixels[407 * UW + 207]
    var mid = layer.pixels[403 * UW + 205]  # source (2, 1)
    print("image: top-left", hex(tl), "bottom-right", hex(br), "dropped", dropped0)
    if not near(tl, srcpx[0]) or not near(br, srcpx[15]) or not near(mid, srcpx[6]) or layer.pixels[409 * UW + 209] != 0 or dropped0 != 1:
        fails += 1
    # past NBIN tile entries: whole commands drop (counted), the ones kept still draw
    ui.dropped = 0
    ui.begin(idle)
    var each = TX * TY  # a full-screen rect touches every tile
    var want = NBIN // each + 5
    for _ in range(want):
        ui.rect(0, 0, Float32(UW), Float32(UH), 0, ACCENT)
    ui.finish()
    layer.render(ui)
    print("overflow: asked", want, "kept", ui.n, "dropped", ui.dropped, "tile entries", Int(ui.off[TX * TY]), "of", NBIN)
    if ui.n != NBIN // each or ui.dropped != want - NBIN // each or Int(ui.off[TX * TY]) > NBIN or layer.pixels[360 * UW + 640] >> 24 != 255:
        fails += 1
    # render before finish raises
    ui.begin(idle)
    ui.rect(0, 0, 10, 10, 0, ACCENT)
    var refused = False
    try:
        layer.render(ui)
    except:
        refused = True
    if not refused:
        print("FAIL render before finish was accepted")
        fails += 1
    ui.finish()
    # Oversized atlases fail before device buffers are allocated.
    ui.font.atlas.resize(AW * AH + 1, 0)
    var rejected = False
    try:
        var invalid = Layer(ctx, ui)
        _ = invalid.pixels.unsafe_ptr()
    except:
        rejected = True
    if not rejected:
        fails += 1
    if fails:
        raise Error("FAIL " + String(fails) + " ui checks")
    print("PASS ui_test")
