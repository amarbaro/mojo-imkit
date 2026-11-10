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
from imkit.assets import Assets, pack
from imkit.font import Font
from imkit.font import AH, AW
from imkit.draw import BR, ISRC, NBIN, QH, QW, TX, TY, UH, UW, bits, glass, rgba, rrect, srect
from imkit.theme import ACCENT, BAD, GOOD, TEXT, WARN
from imkit.ui import Ui
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
    print("clicks idle/press/release/again:", c0, c1, c2, c3, "commands", ui.d.n, "tile entries", Int(ui.d.off[TX * TY]), "dropped", ui.d.dropped)
    if c0 or c1 or not c2 or c3 or ui.d.dropped:
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
    t0 = perf_counter_ns()
    for _ in range(200):
        layer.render_into(ui, layer.img)
    var into_us = Float64(perf_counter_ns() - t0) / 200 / 1000
    print("compose", us, "us per launch,", "render", render_us, "us per frame including transfers, at", UW, "x", UH)
    print("render_into (device buffer, no readback)", into_us, "us per frame; render (with readback)", render_us)
    var other = ctx.enqueue_create_buffer[DType.uint32](UW * UH)
    layer.render_into(ui, other)
    layer.render(ui)
    var ohost = ctx.enqueue_create_host_buffer[DType.uint32](UW * UH)
    ctx.enqueue_copy(ohost, other)
    ctx.synchronize()
    var odiff = 0
    for i in range(UW * UH):
        if ohost[i] != layer.pixels[i]:
            odiff += 1
    var short_raised = False
    try:
        layer.render_into(ui, ctx.enqueue_create_buffer[DType.uint32](16))
    except:
        short_raised = True
    print("render_into another buffer: pixels differing from render", odiff, "short buffer raised", short_raised)
    if odiff or not short_raised or into_us >= render_us:
        fails += 1
    # pixels (3.7 MB pinned) exist once something reads the layer back: a layer used with render_into alone never holds them
    var lazy = Layer(ctx, ui)
    var lazy0 = len(lazy.pixels)
    lazy.render_into(ui, lazy.img)
    var lazy1 = len(lazy.pixels)
    lazy.readback()
    var lazy_diff = 0
    for i in range(UW * UH):
        if lazy.pixels[i] != host[i]:
            lazy_diff += 1
    print("pixels: before render_into", lazy0, "after render_into", lazy1, "after readback", len(lazy.pixels), "differing from render", lazy_diff)
    if lazy0 != 0 or lazy1 != 0 or len(lazy.pixels) != UW * UH or lazy_diff:
        fails += 1
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
    var dropped0 = ui.d.dropped
    layer.render(ui)
    var near = lambda (p: UInt32, q: UInt32) -> Bool: abs(Int(p & 255) - Int(q & 255)) <= 1 and abs(Int((p >> 8) & 255) - Int((q >> 8) & 255)) <= 1 and (p >> 24) == 255
    var tl = layer.pixels[401 * UW + 201]
    var br = layer.pixels[407 * UW + 207]
    var mid = layer.pixels[403 * UW + 205]  # source (2, 1)
    print("image: top-left", hex(tl), "bottom-right", hex(br), "dropped", dropped0)
    if not near(tl, srcpx[0]) or not near(br, srcpx[15]) or not near(mid, srcpx[6]) or layer.pixels[409 * UW + 209] != 0 or dropped0 != 1:
        fails += 1
    # set_image: a 4 x 4 picture to pool offset 0, drawn 2x oversize (clipped by the layer edge); one over ISRC raises, pool untouched
    var big = List[UInt32](length=ISRC + 1, fill=0)
    layer.set_image(Span(srcpx), 4, 4)
    ui.begin(idle)
    ui.image(-8, -8, 8, 8, 0, 4, 4)  # source (2, 2) lands at the layer's (0, 0)
    ui.finish()
    layer.render(ui)
    var si = layer.pixels[0]
    var si_raised = False
    try:
        layer.set_image(Span(big), ISRC + 1, 1)
    except:
        si_raised = True
    print("set_image: pixel (0, 0)", hex(si), "raised over ISRC", si_raised)
    if not near(si, srcpx[10]) or not si_raised or layer.pixels[1] >> 24 != 255:
        fails += 1
    # RRECT: the GPU pixels match the shader's CPU form over the command's span (glow 10 px, border 3 px, gradient 60)
    var rc, rb = rgba(200, 100, 50, 230), rgba(0, 200, 255, 200)
    ui.begin(idle)
    ui.rrect(300, 500, 420, 560, 12, rc, 3, rb, 10, 60)
    ui.finish()
    layer.render(ui)
    var worst = 0
    for y in range(486, 574):
        for x in range(286, 434):
            var v = rrect(SIMD[DType.float32, 4](0), Float32(x) + 0.5, Float32(y) + 0.5, 300, 500, 420, 560, 12, rc, UInt32(5) | UInt32(12) << 8 | UInt32(10) << 16 | UInt32(60) << 24, rb)
            var inv = 1 / max(v[3], Float32(1e-6))
            var p = layer.pixels[y * UW + x]
            worst = max(worst, abs(Int(p & 255) - Int(min(v[0] * inv, 1) * 255)), abs(Int((p >> 8) & 255) - Int(min(v[1] * inv, 1) * 255)),
                        abs(Int((p >> 16) & 255) - Int(min(v[2] * inv, 1) * 255)), abs(Int(p >> 24) - Int(v[3] * 255)))
    print("rrect: worst channel difference GPU vs CPU", worst)
    if worst > 2 or layer.pixels[530 * UW + 360] >> 24 < 200:
        fails += 1
    # SRECT: radial gradient, shadow down-right and a border, GPU against the CPU form over the span
    var sc1 = rgba(250, 40, 120, 255)
    ui.begin(idle)
    var sid = ui.style(sc1, 2, 0, 0, 14, 18, 8, rgba(0, 0, 0, 160))
    ui.srect(600, 500, 720, 580, 16, rc, sid, 2, rb)
    ui.finish()
    layer.render(ui)
    var st = SIMD[DType.uint32, 8](2, sc1, 0, 0, bits(14), bits(18), bits(8), rgba(0, 0, 0, 160))
    var sworst = 0
    for y in range(480, 610):
        for x in range(580, 760):
            var v = srect(SIMD[DType.float32, 4](0), Float32(x) + 0.5, Float32(y) + 0.5, 600, 500, 720, 580, 16, rc, UInt32(6) | UInt32(8) << 8 | UInt32(1) << 16, rb, st)
            var inv = 1 / max(v[3], Float32(1e-6))
            var p = layer.pixels[y * UW + x]
            sworst = max(sworst, abs(Int(p & 255) - Int(min(v[0] * inv, 1) * 255)), abs(Int((p >> 8) & 255) - Int(min(v[1] * inv, 1) * 255)),
                         abs(Int((p >> 16) & 255) - Int(min(v[2] * inv, 1) * 255)), abs(Int(p >> 24) - Int(v[3] * 255)))
    print("srect: worst channel difference GPU vs CPU", sworst, "shadow alpha", layer.pixels[595 * UW + 660] >> 24)
    if sworst > 2 or layer.pixels[595 * UW + 660] >> 24 < 40:
        fails += 1
    # CLIP: a rect far larger than the clip draws only inside it (the pixel edge at the clip's half-open bounds), then draws freely
    ui.begin(idle)
    ui.clip(100, 620, 140, 650)
    ui.rect(0, 600, 400, 700, 0, ACCENT)
    ui.unclip()
    ui.rect(300, 660, 340, 690, 0, ACCENT)
    ui.finish()
    layer.render(ui)
    print("clip: inside", layer.pixels[635 * UW + 120] >> 24, "left edge", layer.pixels[635 * UW + 99] >> 24, hex(layer.pixels[635 * UW + 100]), "right", layer.pixels[635 * UW + 140] >> 24, "below", layer.pixels[650 * UW + 120] >> 24, "later rect", layer.pixels[675 * UW + 320] >> 24)
    if layer.pixels[635 * UW + 120] >> 24 != 255 or layer.pixels[635 * UW + 99] != 0 or layer.pixels[635 * UW + 100] >> 24 != 255 or layer.pixels[635 * UW + 140] != 0 or layer.pixels[650 * UW + 120] != 0 or layer.pixels[675 * UW + 320] >> 24 != 255 or layer.pixels[615 * UW + 120] != 0:
        fails += 1
    # GLASS: scene red | blue at x = 640; the backdrop is its 1 / 4 size, two triangle-weight passes, bilinear; GPU against a host blur
    var scene = List[UInt32](length=UW * UH, fill=0)
    for i in range(UW * UH):
        scene[i] = rgba(255, 0, 0, 255) if i % UW < 640 else rgba(0, 0, 255, 255)
    layer.set_scene(Span(scene))
    ui.begin(idle)
    ui.glass(560, 300, 720, 380, 12, rgba(0, 0, 0, 0))
    ui.finish()
    layer.render(ui)
    var q0 = List[SIMD[DType.float32, 4]](length=QW * QH, fill=0)  # host reference, quantized to u8 between passes like the buffers
    var q1 = q0.copy()
    var q2 = q0.copy()
    var rnd = lambda (v: SIMD[DType.float32, 4]) -> SIMD[DType.float32, 4]: SIMD[DType.float32, 4](Float32(Int(v[0] + 0.5)), Float32(Int(v[1] + 0.5)), Float32(Int(v[2] + 0.5)), 255)
    for i in range(QW * QH):
        var sum = SIMD[DType.float32, 4](0)
        for k in range(16):
            var p = scene[((i // QW) * 4 + k // 4) * UW + (i % QW) * 4 + k % 4]
            sum += SIMD[DType.float32, 4](Float32(p & 255), Float32((p >> 8) & 255), Float32((p >> 16) & 255), 255)
        q0[i] = rnd(sum / 16)
    for pass_ in range(2):
        for i in range(QW * QH):
            var sum = SIMD[DType.float32, 4](0)
            var wsum = Float32(0)
            for k in range(-BR, BR + 1):
                var wk = Float32(BR + 1 - abs(k))
                var xx = min(max(i % QW + (k if pass_ == 0 else 0), 0), QW - 1)
                var yy = min(max(i // QW + (k if pass_ == 1 else 0), 0), QH - 1)
                sum += (q0[yy * QW + xx] if pass_ == 0 else q1[yy * QW + xx]) * wk
                wsum += wk
            if pass_ == 0:
                q1[i] = rnd(sum / wsum)
            else:
                q2[i] = rnd(sum / wsum)
    var gworst = 0
    for y in range(290, 390):
        for x in range(540, 740):
            var fx = min(max((Float32(x) + 0.5) / 4 - 0.5, Float32(0)), Float32(QW - 1))
            var fy = min(max((Float32(y) + 0.5) / 4 - 0.5, Float32(0)), Float32(QH - 1))
            var ix, iy = Int(fx), Int(fy)
            var tx, ty = fx - Float32(ix), fy - Float32(iy)
            var bk = (q2[iy * QW + ix] * (1 - tx) + q2[iy * QW + min(ix + 1, QW - 1)] * tx) * (1 - ty) + (q2[min(iy + 1, QH - 1) * QW + ix] * (1 - tx) + q2[min(iy + 1, QH - 1) * QW + min(ix + 1, QW - 1)] * tx) * ty
            var v = glass(SIMD[DType.float32, 4](0), Float32(x) + 0.5, Float32(y) + 0.5, 560, 300, 720, 380, 12, rgba(0, 0, 0, 0), bk)
            var inv = 1 / max(v[3], Float32(1e-6))
            var p = layer.pixels[y * UW + x]
            gworst = max(gworst, abs(Int(p & 255) - Int(min(v[0] * inv, 1) * 255)), abs(Int((p >> 16) & 255) - Int(min(v[2] * inv, 1) * 255)), abs(Int(p >> 24) - Int(v[3] * 255)))
    var gl = layer.pixels[340 * UW + 570]
    var gm = layer.pixels[340 * UW + 640]
    var gr = layer.pixels[340 * UW + 710]
    t0 = perf_counter_ns()
    for _ in range(200):
        layer.blur_from(layer.scene)
    ctx.synchronize()
    var blur_us = Float64(perf_counter_ns() - t0) / 200 / 1000
    print("glass: worst difference GPU vs host blur", gworst, "left", hex(gl), "edge", hex(gm), "right", hex(gr), "; blur_from", blur_us, "us")
    if gworst > 2 or (gl & 255) < 250 or (gr >> 16) & 255 < 250 or (gm & 255) < 100 or (gm & 255) > 160 or layer.pixels[340 * UW + 540] != 0:
        fails += 1
    # UTF-8 + dynamic atlas: 日 is rasterized on the first frame, 語 only during the second (Layer sends the dirty rows); each glyph's
    # pixels on the card are exactly where the host atlas has ink, and a glyph neither font has draws as the '?' glyph
    var cui = Ui(Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22], getenv("IMKIT_CJK", "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc")))
    var clayer = Layer(ctx, cui)
    var cjk_ok = True
    var cps = List[Int]()
    cps.append(0x65E5)
    cps.append(0x8A9E)
    cps.append(0xE000)
    for round in range(2):
        cui.begin(idle)
        var mark = String(chr(cps[round]))
        _ = cui.text(50, 100, mark, 1, TEXT)
        _ = cui.text(150, 100, String(chr(0xE000)), 1, TEXT)
        cui.finish()
        clayer.render(cui)
        var gi = cui.d.font.glyph(1, cps[round])
        var gxx, gyy = 50 + Int(cui.d.font.g[gi + 4]), 100 + cui.d.font.ascent[1] - Int(cui.d.font.g[gi + 5])
        var gw, gh, ax, ay = Int(cui.d.font.g[gi + 2]), Int(cui.d.font.g[gi + 3]), Int(cui.d.font.g[gi]), Int(cui.d.font.g[gi + 1])
        var want, got = 0, 0
        for r in range(gh):
            for k in range(gw):
                want += 1 if cui.d.font.atlas[(ay + r) * AW + ax + k] > 0 else 0
                got += 1 if clayer.pixels[(gyy + r) * UW + gxx + k] >> 24 > 0 else 0
        var qg = cui.d.font.glyph(1, ord("?"))
        var pg = cui.d.font.glyph(1, 0xE000)
        print("cjk round", round, "U+", hex(cps[round]), "ink on host", want, "on card", got, "; U+E000 is '?':", pg == qg)
        if want < 40 or got != want or pg != qg:
            cjk_ok = False
    if not cjk_ok:
        fails += 1
    # asset atlas: pack a PNG, load it, put it in the pool, draw it 1:1: every pixel on the card is the PNG's (alpha too)
    pack(["tests/fixtures/rgba.png"], ".work/ui_assets")
    var assets = Assets(".work/ui_assets")
    var apx = assets.px.copy()
    # the pool is shared: set_assets over the picture set_image put at offset 0 raises, so does set_image into the atlas;
    # an offset past the atlas keeps both
    var clash1 = False
    try:
        layer.set_assets(assets)
    except:
        clash1 = True
    var al = Layer(ctx, ui)
    al.set_assets(assets)
    var clash2 = False
    try:
        al.set_image(Span(srcpx), 4, 4)
    except:
        clash2 = True
    al.set_image(Span(srcpx), 4, 4, len(assets.px))
    print("pool clash: set_assets over a picture raised", clash1, "set_image into the atlas raised", clash2)
    if not clash1 or not clash2:
        fails += 1
    ui.assets = assets^
    ui.begin(idle)
    var drew = ui.icon_img("rgba", 800, 600)
    ui.image(0, 0, 4, 4, 480, 4, 4)  # the picture past the atlas
    ui.finish()
    al.render(ui)
    var adiff = 0
    for y in range(20):
        for x in range(24):
            var want = apx[y * 24 + x]
            var got = al.pixels[(600 + y) * UW + 800 + x]
            var wa = Int(want >> 24)
            if abs(Int(got >> 24) - wa) > 1 or (wa >= 40 and (abs(Int(got & 255) - Int(want & 255)) > 2 or abs(Int((got >> 8) & 255) - Int((want >> 8) & 255)) > 2 or abs(Int((got >> 16) & 255) - Int((want >> 16) & 255)) > 2)):
                adiff += 1
    print("assets: icon_img drew", drew, "pixels differing from the PNG", adiff, "of 480")
    if not drew or adiff or not near(al.pixels[0], srcpx[0]):
        fails += 1
    # past NBIN tile entries: whole commands drop (counted), the ones kept still draw
    ui.d.dropped = 0
    ui.begin(idle)
    var each = TX * TY  # a full-screen rect touches every tile
    var want = NBIN // each + 5
    for _ in range(want):
        ui.rect(0, 0, Float32(UW), Float32(UH), 0, ACCENT)
    ui.finish()
    layer.render(ui)
    print("overflow: asked", want, "kept", ui.d.n, "dropped", ui.d.dropped, "tile entries", Int(ui.d.off[TX * TY]), "of", NBIN)
    if ui.d.n != NBIN // each or ui.d.dropped != want - NBIN // each or Int(ui.d.off[TX * TY]) > NBIN or layer.pixels[360 * UW + 640] >> 24 != 255:
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
    ui.d.font.atlas.resize(AW * AH + 1, 0)
    var rejected = False
    try:
        var invalid = Layer(ctx, ui)
        _ = invalid.pixels.unsafe_ptr()
    except:
        rejected = True
    if not rejected:
        fails += 1
    if fails:
        print("FAIL", fails, "ui checks")
        raise Error("FAIL " + String(fails) + " ui checks")
    print("PASS ui_test")
