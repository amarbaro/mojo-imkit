"""Ui check without a GPU or a window: scripted input through widgets, the draw list and its tile bins.
Gates: a click is press then release on the same widget (not a press alone, not a second release); a press elsewhere
makes no click; the panel's command sits in the bin of a tile it covers and not in a far tile; bins hold exactly the
entries the spans predict; a frame past NBIN tile entries drops whole commands, counted, and keeps off[last] <= NBIN;
a list past NCMD commands drops, counted; text fields: typing keeps ASCII 32-126, Backspace, a maximum length, focus by click and
the focused flag; image_fits (set_image's check) and an image rect larger than the layer clipped to its tiles. PASS / FAIL, exit 1 on any FAIL.

usage: IMKIT_FONT=/path/font.ttf mojo run -I src tests/ui_cpu_test.mojo  (default font: Roboto Medium)
"""
from std.math import pow
from std.os import getenv
from imkit.draw import CLIP, GLYPH, LINE, flt
from imkit.font import Font
from imkit.layer import image_fits
from imkit.draw import ISRC, NBIN, NCMD, NSTY, TX, TY, UH, UW, FULL, bits, clipped, glass, rgba, rrect, srect
from imkit.theme import ACCENT, TEXT, Theme, flat, neon, glass as tglass
from imkit.ui import SC_BACKSPACE, Ui, cp_ceil, cp_floor, num
from imkit.window import Input


def check(ok: Bool, name: String, mut fails: Int):
    print(("PASS " if ok else "FAIL ") + name)
    if not ok:
        fails += 1


def in_bin(ui: Ui, tile: Int, k: Int) -> Bool:
    for j in range(Int(ui.d.off[tile]), Int(ui.d.off[tile + 1])):
        if Int(ui.d.bins[j]) == k:
            return True
    return False


def clip_at(ui: Ui, tile: Int, k: Int) -> SIMD[DType.float32, 4]:
    """The clip rect compose would hold in `tile` when it reaches command k (walks the tile's bin as the kernel does);
    (7, 7, 7, 7) if k is not in the tile."""
    var c = FULL
    for j in range(Int(ui.d.off[tile]), Int(ui.d.off[tile + 1])):
        var q = Int(ui.d.bins[j])
        if q == k:
            return c
        c = ui.d.clip_after(q, c)
    return SIMD[DType.float32, 4](7)


def frame(mut ui: Ui, inp: Input) -> Bool:
    ui.begin(inp)
    ui.panel(24, 20, 520, 96, "Run")
    _ = ui.icon(1, 0)
    var paused = ui.icon(2, 1, True)  # the second icon: x 84 to 120, y 60 to 96
    _ = ui.icon(3, 2)
    ui.finish()
    return paused


def typed(mut ui: Ui, mut a: String, mut b: String, inp: Input) -> Bool:
    """One frame with two fields (ids 1 and 2, max 8 and 4); True if the first changed."""
    ui.begin(inp)
    ui.x, ui.y = 10, 10  # field 1: y 10 to 40, field 2: y 48 to 78
    var c = ui.field(1, a, 8)
    _ = ui.field(2, b, 4)
    ui.finish()
    return c


def colors(mut ui: Ui, t: Theme) -> List[UInt32]:
    """The color word of every command of one frame with every widget, drawn under theme t."""
    ui.set_theme(t)
    ui.begin(Input(300, 300, 0, 0, 0, 0, 0, 0, SIMD[DType.uint64, 2](0), False))
    ui.panel(24, 20, 520, 300, "Gallery")
    _ = ui.button(1, "On", 60, 30, True)
    _ = ui.button(2, "Off", 60)
    _ = ui.icon(3, 0, True)
    _ = ui.icon(4, 2)
    var s = String("hi")
    _ = ui.field(5, s, 8)
    ui.bar("energy", 0.5, ui.theme.good, 200)
    ui.spark([Float32(0), Float32(1), Float32(0.5)], 0, 1, 120, 40, ui.theme.bad)
    ui.finish()
    var out = List[UInt32]()
    for k in range(ui.d.n):
        out.append(ui.d.cmd[k * 8 + 6])
    return out^


def lum(c: UInt32) -> Float32:
    """WCAG relative luminance of the rgb of a packed color."""
    var out = Float32(0)
    var w = [Float32(0.2126), Float32(0.7152), Float32(0.0722)]
    for k in range(3):
        var v = Float32((c >> UInt32(8 * k)) & 255) / 255
        out += w[k] * (v / 12.92 if v <= 0.03928 else pow((v + 0.055) / 1.055, Float32(2.4)))
    return out


def contrast(a: UInt32, b: UInt32) -> Float32:
    var la, lb = lum(a), lum(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def legible(t: Theme) -> Bool:
    """Text pairs reach WCAG 4.5, bars and the accent against the surface reach 3 (the panel's alpha is ignored)."""
    var text = min(contrast(t.text, t.panel), contrast(t.text, t.surface), contrast(t.text, t.hover), contrast(t.muted, t.panel), contrast(t.on_accent, t.accent))
    var graphic = min(contrast(t.good, t.surface), contrast(t.warn, t.surface), contrast(t.bad, t.surface), contrast(t.accent, t.surface))
    return text >= 4.5 and graphic >= 3


def only_roles(c: List[UInt32], t: Theme) -> Bool:
    var roles = [t.panel, t.surface, t.hover, t.accent, t.good, t.warn, t.bad, t.text, t.on_accent, t.muted, t.shadow, t.border_c]
    for v in c:
        var ok = False
        for r in roles:
            ok = ok or v == r
        if not ok:
            return False
    return True


def sframe(mut ui: Ui, inp: Input, v: Float32) -> Float32:
    ui.begin(inp)
    ui.x, ui.y = 20, 20  # track x 20 to 220, y 20 to 44
    var nv = ui.slider(1, v, 0, 100, 200)
    ui.finish()
    return nv


def mframe(mut ui: Ui, inp: Input, mut picked: Int):
    """A menu at (20, 20): header 20..120 x 20..50, popup items 58..86, 86..114, 114..142 (x 24..116)."""
    ui.begin(inp)
    ui.x, ui.y = 20, 20
    if ui.menu_begin(1, "File", 100, 3):
        for k in range(3):
            if ui.menu_item("item"):
                picked = k
        ui.menu_end()
    ui.finish()


def lframe(mut ui: Ui, inp: Input, rows: Int, mut off: Float32, mut sel: Int) -> Tuple[Int, Int]:
    """A scroll list of 200 x 100 at (20, 20), rows of 24; returns the rows drawn."""
    ui.begin(inp)
    ui.x, ui.y = 20, 20
    var fe = ui.scroll_begin(1, 200, 100, rows, 24, off)
    for k in range(fe[0], fe[1]):
        if ui.scroll_row(10 + k, k, "row", sel == k):
            sel = k
    ui.scroll_end()
    ui.finish()
    return fe


def tframe(mut ui: Ui, inp: Input, rows: Int, last_w: Float32, mut off: Float32, mut sel: Int):
    """A table at (20, 20): header 20..46, rows of 24 from y 48, three columns (100, 80, last_w) of 100 high."""
    ui.begin(inp)
    ui.x, ui.y = 20, 20
    var heads: List[String] = ["Name", "Value", "A very long header text"]
    var widths: List[Float32] = [100, 80, last_w]
    var fe = ui.table_begin(1, heads, widths, 100, rows, 24, off)
    for k in range(fe[0], fe[1]):
        if ui.table_row(10 + k, k, sel == k):
            sel = k
        ui.table_cell(k, 0, "row " + String(k))
        ui.table_cell(k, 1, "v")
        ui.table_cell(k, 2, "a very long cell text that cannot fit")
    ui.table_end()
    ui.finish()


def count(ui: Ui, kind: Int) -> Int:
    var n = 0
    for k in range(ui.d.n):
        n += 1 if Int(ui.d.cmd[k * 8]) == kind else 0
    return n


def pframe(mut ui: Ui, vals: List[Float32]):
    ui.begin(Input(400, 400, 0, 0, 0, 0, 0, 0, SIMD[DType.uint64, 2](0), False))
    ui.x, ui.y = 20, 20  # plot 300 x 120: area x 56..312, y 28..120
    ui.plot(vals, 0, 10, 300, 120, ui.theme.accent)
    ui.finish()


def main() raises:
    var ui = Ui(Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22]))
    var fails = 0
    var keys = SIMD[DType.uint64, 2](0)
    var idle = Input(300, 300, 0, 0, 0, 0, 0, 0, keys, False)
    var press = Input(102, 78, 0, 0, 0, 1, 1, 0, keys, False)
    var release = Input(102, 78, 0, 0, 0, 0, 0, 1, keys, False)
    var elsewhere = Input(400, 300, 0, 0, 0, 1, 1, 0, keys, False)
    var elsewhere_up = Input(400, 300, 0, 0, 0, 0, 0, 1, keys, False)
    var c0 = frame(ui, idle)
    var c1 = frame(ui, press)
    var c2 = frame(ui, release)
    var c3 = frame(ui, release)
    check(not c0 and not c1 and c2 and not c3, "click is press then release on the icon, once", fails)
    var e1 = frame(ui, elsewhere)
    var e2 = frame(ui, elsewhere_up)
    check(not e1 and not e2, "press and release elsewhere is no click", fails)
    check(ui.d.dropped == 0 and ui.d.n > 10, "demo frame: commands kept, none dropped", fails)
    # the panel background is the second command (shadow first); it covers tile (60 / 16, 400 / 16) and not the far corner
    var near = (60 // 16) * TX + 400 // 16
    var far = (TY - 1) * TX + (TX - 1)
    check(in_bin(ui, near, 1) and not in_bin(ui, far, 1), "panel command is in a covered tile's bin and not in a far one", fails)
    var total = 0
    for k in range(ui.d.n):
        var s = ui.d.span(k)
        total += Int(s[1] - s[0]) * Int(s[3] - s[2])
    check(Int(ui.d.off[TX * TY]) == total and total <= NBIN, "bin entries equal the sum of the spans", fails)
    # tile entry overflow: full-screen rects touch every tile; past NBIN whole commands drop
    ui.d.dropped = 0
    ui.begin(idle)
    var want = NBIN // (TX * TY) + 5
    for _ in range(want):
        ui.rect(0, 0, Float32(TX * 16), Float32(TY * 16), 0, ACCENT)
    ui.finish()
    check(ui.d.n == NBIN // (TX * TY) and ui.d.dropped == want - NBIN // (TX * TY) and Int(ui.d.off[TX * TY]) <= NBIN, "past NBIN whole commands drop, counted", fails)
    # command list overflow
    ui.d.dropped = 0
    ui.begin(idle)
    for _ in range(NCMD + 10):
        ui.rect(0, 0, 4, 4, 0, ACCENT)
    check(ui.d.n == NCMD and ui.d.dropped == 10, "past NCMD commands drop, counted", fails)
    # text fields
    var back = SIMD[DType.uint64, 2](0)
    back[SC_BACKSPACE >> 6] = UInt64(1) << UInt64(SC_BACKSPACE & 63)
    var a = String()
    var b = String()
    var fui = Ui(Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22]))
    var t0 = typed(fui, a, b, idle)
    check(not t0 and fui.field_focused and fui.focus == 1, "first field drawn takes focus, flag set, nothing typed", fails)
    var t1 = typed(fui, a, b, Input(300, 300, 0, 0, 0, 0, 0, 0, keys, False, "Ab 1" + chr(7) + chr(233) + "~"))
    check(t1 and a == "Ab 1~" and b == "", "typing keeps ASCII 32-126 only, goes to the focused field", fails)
    var t2 = typed(fui, a, b, Input(300, 300, 0, 0, 0, 0, 0, 0, back, False))
    check(t2 and a == "Ab 1", "Backspace removes the last byte", fails)
    var t3 = typed(fui, a, b, Input(300, 300, 0, 0, 0, 0, 0, 0, keys, False, "xyz12345"))
    check(t3 and a == "Ab 1xyz1" and a.byte_length() == 8, "typing stops at max", fails)
    var t4 = typed(fui, a, b, Input(300, 300, 0, 0, 0, 0, 0, 0, keys, False, "q"))
    check(not t4 and a == "Ab 1xyz1", "a full field reports no change", fails)
    var e = String()
    _ = typed(fui, e, b, Input(300, 300, 0, 0, 0, 0, 0, 0, back, False))
    check(e == "", "Backspace on an empty field does nothing", fails)
    var u = String("a") + chr(233) + chr(0x4E2D)  # 1 + 2 + 3 bytes
    for want in ["a" + chr(233), "a", ""]:
        _ = typed(fui, u, b, Input(300, 300, 0, 0, 0, 0, 0, 0, back, False))
        check(u == want, "Backspace removes the last code point, not a byte of it (" + String(want.byte_length()) + " bytes left)", fails)
    # the tail of a long text starts on a code point (Roboto's U+FFFD is as wide as its letters, so the stray start cannot
    # win the width scan here; the boundary helpers are checked directly)
    var cs = String("a") + chr(233) + chr(0x4E2D) + chr(0x1F600)  # 1 + 2 + 3 + 4 bytes
    var cu = cs.as_bytes()
    check(cp_floor(cu, 2) == 1 and cp_floor(cu, 5) == 3 and cp_floor(cu, 8) == 6 and cp_floor(cu, 0) == 0 and cp_floor(cu, 1) == 1 and cp_floor(cu, 10) == 10, "cp_floor: back to the start of the code point", fails)
    check(cp_ceil(cu, 2) == 3 and cp_ceil(cu, 4) == 6 and cp_ceil(cu, 7) == 10 and cp_ceil(cu, 1) == 1 and cp_ceil(cu, 10) == 10, "cp_ceil: forward to the next code point start", fails)
    _ = typed(fui, a, b, Input(50, 60, 0, 0, 0, 1, 1, 0, keys, False))  # press on field 2
    _ = typed(fui, a, b, Input(50, 60, 0, 0, 0, 0, 0, 1, keys, False))  # release: click
    check(fui.focus == 2, "a click gives the field focus", fails)
    _ = typed(fui, a, b, Input(300, 300, 0, 0, 0, 0, 0, 0, keys, False, "hello"))
    check(a == "Ab 1xyz1" and b == "hell", "the second field takes the typing, max 4", fails)
    fui.begin(idle)
    fui.finish()
    check(not fui.field_focused, "no field drawn: flag clear", fails)
    # set_image's fit rule: ISRC pixels at most, sides up to 0xFFFF, the slice must hold w * h
    check(image_fits(16, 4, 4) and image_fits(ISRC, 256, ISRC // 256) and not image_fits(ISRC + 256, 256, ISRC // 256 + 1) and not image_fits(15, 4, 4)
          and not image_fits(16, 0, 4) and not image_fits(16, 4, -4) and not image_fits(16, 0x10000, 1), "image_fits: fits, raises on over ISRC, short slice, bad sides", fails)
    check(image_fits(16, 4, 4, 480) and image_fits(16, 4, 4, ISRC - 16) and not image_fits(16, 4, 4, ISRC - 15) and not image_fits(16, 4, 4, -1), "image_fits: an offset keeps the picture inside ISRC", fails)
    # a 4 x 4 image on a rect much larger than the layer (and one starting off-screen) is clipped to the tiles, not dropped
    fui.d.dropped = 0
    fui.begin(idle)
    fui.image(-300, -200, Float32(UW + 300), Float32(UH + 200), 0, 4, 4)
    fui.finish()
    check(fui.d.dropped == 0 and fui.d.n == 1 and Int(fui.d.off[TX * TY]) == TX * TY, "oversize image rect clipped to the layer's tiles", fails)
    # RRECT (100, 100)-(200, 160), r 10, fill (200, 100, 50), border 4 px green, glow 8 px: closed-form pixels of the shader
    var z = SIMD[DType.float32, 4](0)
    var fc, bcn = rgba(200, 100, 50, 255), rgba(0, 255, 0, 255)
    var k = UInt32(5) | UInt32(16) << 8 | UInt32(8) << 16
    var near4 = lambda (v: SIMD[DType.float32, 4], r: Float32, g: Float32, b: Float32, a: Float32) -> Bool: abs(v[0] - r) < 0.01 and abs(v[1] - g) < 0.01 and abs(v[2] - b) < 0.01 and abs(v[3] - a) < 0.01
    check(near4(rrect(z, 150.5, 130.5, 100, 100, 200, 160, 10, fc, k, bcn), 200 / 255, 100 / 255, 50 / 255, 1), "rrect: fill inside", fails)
    check(near4(rrect(z, 102.5, 130.5, 100, 100, 200, 160, 10, fc, k, bcn), 0, 1, 0, 1), "rrect: border ring in bcol", fails)
    check(near4(rrect(z, 96.5, 130.5, 100, 100, 200, 160, 10, fc, k, bcn), 0, 0.31640625, 0, 0.31640625), "rrect: glow 3.5 px out of 8 is (1 - 3.5 / 8) squared", fails)
    check(near4(rrect(z, 50.5, 130.5, 100, 100, 200, 160, 10, fc, k, bcn), 0, 0, 0, 0), "rrect: nothing past the glow", fails)
    var gtop = rrect(z, 150.5, 100.5, 100, 100, 200, 160, 10, fc, UInt32(5) | UInt32(127) << 24, 0)
    var gbot = rrect(z, 150.5, 159.5, 100, 100, 200, 160, 10, fc, UInt32(5) | UInt32(127) << 24, 0)
    check(abs(gtop[0] * 255 - 254.08) < 0.1 and abs(gbot[0] * 255 - 3.3) < 0.1, "rrect: gradient + lightens the top and darkens the bottom", fails)
    var gneg = rrect(z, 150.5, 100.5, 100, 100, 200, 160, 10, fc, UInt32(5) | UInt32(129) << 24, 0)
    check(gneg[0] * 255 < 4, "rrect: gradient byte 129 is -127 (top darker)", fails)
    var rui = Ui(Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22]))
    rui.begin(idle)
    rui.rrect(100, 100, 116, 116, 0, fc, 4, bcn, 40, -127)
    rui.rrect(100, 100, 116, 116, 0, fc)
    rui.finish()
    check(rui.d.cmd[0] == (UInt32(5) | UInt32(16) << 8 | UInt32(40) << 16 | UInt32(129) << 24) and rui.d.cmd[8] == 5 and rui.d.cmd[7] == bcn, "rrect: kind word packs border px * 4, glow px, gradient i8; aux is bcol", fails)
    check(rui.d.span(0)[0] == 3 and rui.d.span(1)[0] == 6, "rrect: span grows by the glow radius", fails)
    # SRECT, same rect, fill (200, 100, 50) to (0, 100, 250): linear down the rect, radial from its centre, a shadow moved 10 px down
    var lin = SIMD[DType.uint32, 8](1, rgba(0, 100, 250, 255), bits(0), bits(1), 0, 0, 0, 0)
    var rad = SIMD[DType.uint32, 8](2, rgba(0, 100, 250, 255), 0, 0, 0, 0, 0, 0)
    var shd = SIMD[DType.uint32, 8](0, 0, 0, 0, bits(0), bits(10), bits(4), rgba(0, 0, 0, 255))
    var sk = UInt32(6)
    check(abs(srect(z, 150.5, 130.5, 100, 100, 200, 160, 10, fc, sk, 0, lin)[0] * 255 - 98.3) < 0.2, "srect: linear gradient is the mix at v = 0.508", fails)
    check(abs(srect(z, 180.5, 130.5, 100, 100, 200, 160, 10, fc, sk, 0, rad)[0] * 255 - 77.96) < 0.2, "srect: radial gradient is the mix at 2 * distance from the centre", fails)
    check(near4(srect(z, 150.5, 163.5, 100, 100, 200, 160, 10, fc, sk, 0, shd), 0, 0, 0, 1), "srect: shadow moved 10 px down covers 3.5 px under the rect", fails)
    check(near4(srect(z, 150.5, 171.5, 100, 100, 200, 160, 10, fc, sk, 0, shd), 0, 0, 0, 0.2), "srect: shadow edge 1.5 px past its box is 0.2", fails)
    check(near4(srect(z, 150.5, 130.5, 100, 100, 200, 160, 10, fc, sk, 0, shd), 200 / 255, 100 / 255, 50 / 255, 1), "srect: fill covers its shadow", fails)
    rui.begin(idle)
    var sid = rui.style(0, 0, 0, 1, 0, 30, 20, rgba(0, 0, 0, 200))
    var nid = rui.style(rgba(1, 2, 3, 255), 1)
    rui.srect(100, 100, 116, 116, 0, fc, sid)
    rui.srect(100, 100, 116, 116, 0, fc, nid)
    rui.finish()
    check(sid == 1 and nid == 2 and rui.d.cmd[0] == (UInt32(6) | UInt32(1) << 16) and rui.d.cmd[8] == (UInt32(6) | UInt32(2) << 16), "srect: style ids count from 1 and sit in the kind word's high 16 bits", fails)
    check(rui.d.span(0)[2] == 1 and rui.d.span(1)[2] == 6 and rui.d.span(0)[3] == 12, "srect: span grows by the larger shadow offset plus twice its radius (72 px here), not for a style without one", fails)
    rui.begin(idle)
    for _ in range(NSTY + 4):
        _ = rui.style()
    check(rui.d.ns == NSTY and rui.d.dropped >= 5, "style table full: counted, id 0", fails)
    # CLIP: pixels at the edge, and the bins: a clipped command is only in the clip's tiles, an unclipped one in all it covers
    var cr = SIMD[DType.float32, 4](10, 10, 20, 20)
    check(not clipped(10, 10, cr) and not clipped(19.5, 19.5, cr) and clipped(20, 15, cr) and clipped(15, 20, cr) and clipped(9.9, 15, cr) and clipped(15, 9.9, cr) and not clipped(-5, 1e6, FULL), "clip: half-open rect, FULL clips nothing", fails)
    rui.begin(idle)
    rui.clip(32, 32, 64, 64)
    rui.rect(0, 0, 1000, 700, 0, fc)
    rui.unclip()
    rui.rect(0, 0, 1000, 700, 0, fc)
    rui.unclip()  # none in force: no command
    rui.finish()
    check(rui.d.n == 4 and in_bin(rui, 2 * TX + 2, 1) and in_bin(rui, 4 * TX + 4, 1) and not in_bin(rui, 0, 1) and not in_bin(rui, 5 * TX + 5, 1) and not in_bin(rui, 2 * TX + 5, 1), "clip: a clipped command is binned only into the clip's tiles", fails)
    check(in_bin(rui, 0, 3) and in_bin(rui, 5 * TX + 5, 3) and in_bin(rui, 2 * TX + 2, 2) and in_bin(rui, 0, 0) == False, "clip: after unclip the next command covers all its tiles; the end marker sits in the clip's tiles", fails)
    # a clip replaced by another, then unclip: a tile only the first covered must not keep it for the commands after unclip
    rui.begin(idle)
    rui.clip(32, 32, 64, 64)
    rui.clip(200, 200, 232, 232)
    rui.unclip()
    rui.rect(0, 0, 1000, 700, 0, fc)
    var last = rui.d.n - 1
    rui.finish()
    check(clip_at(rui, 2 * TX + 2, last) == FULL and clip_at(rui, 13 * TX + 13, last) == FULL, "clip: replaced then unclip leaves no stale clip in the tiles of either rect", fails)
    # non-finite and huge coordinates: NaN commands drop (counted), infinite and 1e30 ones clamp, so a full-layer rect covers every tile
    var nan = Float32(0) / Float32(0)
    var inf = Float32(1) / Float32(0)
    var dropped0 = rui.d.dropped
    rui.begin(idle)
    rui.rect(nan, 10, 50, 50, 0, fc)
    rui.rect(-inf, -inf, inf, inf, 0, fc)
    rui.line(0, 0, nan, 5, 1, fc)
    rui.rect(0, 0, 50, 50, 0, fc, nan)
    rui.tri(1, 1, 5, 5, 1, nan, fc)
    rui.rect(10, 10, 1e30, 50, 0, fc)
    rui.rect(1e30, 1e30, 2e30, 2e30, 0, fc)
    rui.finish()
    check(rui.d.dropped - dropped0 == 4 and rui.d.n == 3 and in_bin(rui, 0, 0) and in_bin(rui, 5 * TX + 5, 0) and in_bin(rui, (TY - 1) * TX + TX - 1, 0), "NaN commands drop, a -inf..inf rect is binned into every tile", fails)
    var off_layer = False
    for t in range(TX * TY):
        off_layer = off_layer or in_bin(rui, t, 2)
    check(in_bin(rui, TX - 1, 1) and in_bin(rui, 3 * TX + TX - 1, 1) and not in_bin(rui, 4 * TX, 1) and not off_layer, "1e30 edge reaches the last column only in its rows; a rect wholly past the layer is in no tile", fails)
    # GLASS: the tint over the backdrop sample inside, the sample under a clear tint, nothing outside
    var bkd = SIMD[DType.float32, 4](10, 20, 30, 255)
    var tint = rgba(100, 0, 0, 128)
    check(near4(glass(z, 150.5, 130.5, 100, 100, 200, 160, 10, tint, bkd), 0.2164, 0.03906, 0.0586, 1), "glass: tint over the backdrop", fails)
    check(near4(glass(z, 150.5, 130.5, 100, 100, 200, 160, 10, rgba(0, 0, 0, 0), bkd), 10 / 255, 20 / 255, 30 / 255, 1), "glass: a clear tint shows the backdrop", fails)
    check(near4(glass(z, 150.5, 130.5, 100, 100, 200, 160, 10, tint, SIMD[DType.float32, 4](0)), 0.19686, 0, 0, 0.50196), "glass: no backdrop yet leaves the tint alone", fails)
    check(near4(glass(z, 50.5, 130.5, 100, 100, 200, 160, 10, tint, bkd), 0, 0, 0, 0), "glass: nothing outside the rect", fails)
    rui.begin(idle)
    rui.glass(100, 100, 200, 160, 10, tint)
    rui.finish()
    check(rui.d.n == 1 and rui.d.cmd[0] == 8 and in_bin(rui, 7 * TX + 7, 0) and not in_bin(rui, 0, 0), "glass: one GLASS command in the tiles it covers", fails)
    # animation: begin(input, dt) steps the id's spring, an id no widget asked for last frame is evicted
    var aui = Ui(Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22]))
    aui.begin(idle, 0.02)
    var first = aui.animate(9, 0)
    aui.begin(idle, 0.02)
    var stepped = aui.animate(9, 1)
    aui.begin(idle, 0.02)  # id 9 was asked for last frame: kept; nobody asks now
    aui.begin(idle, 0.02)
    check(first == 0 and abs(stepped - 0.104) < 1e-5 and len(aui.anim.id) == 0, "Ui.begin(input, dt): spring steps by dt, an unasked id is evicted", fails)
    # DPI: logical coordinates. The icon at logical (10, 10)-(46, 46) draws at that times the scale, and a click needs the
    # mouse (layer pixels) inside it: its center clicks, 0.2 past the right edge and 0.2 before the left edge do not, 0.2 inside the left edge does.
    for sc in [Float32(1), Float32(1.5), Float32(2)]:
        var dui = Ui(Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22]))
        dui.set_scale(sc)
        var hits = List[Bool]()
        for px in [Float32(28), Float32(46.2), Float32(9.8), Float32(10.2)]:  # logical x of the mouse; y is 28
            var mx = px * sc
            var ps = Input(mx, 28 * sc, 0, 0, 0, 1, 1, 0, keys, False)
            var rl = Input(mx, 28 * sc, 0, 0, 0, 0, 0, 1, keys, False)
            for inp in [ps.copy(), rl.copy()]:
                dui.begin(inp)
                dui.x, dui.y = 10, 10
                var clicked = dui.icon(1, 0)
                dui.finish()
                if inp.released & 1:
                    hits.append(clicked)
        var x0 = flt(dui.d.cmd[1])
        var x1 = flt(dui.d.cmd[3])
        check(hits[0] and not hits[1] and not hits[2] and hits[3] and abs(x0 - 10 * sc) < 1e-4 and abs(x1 - 46 * sc) < 1e-4
              and abs(dui.w() * sc - Float32(UW)) < 1e-3, "DPI " + String(sc) + ": hit test in logical units, rect drawn at logical x scale", fails)
    # theme: every widget colour is a role of the active preset; the presets differ; a runtime switch round-trips
    var tui = Ui(Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22]))
    var cg = colors(tui, tglass())
    var cn = colors(tui, neon())
    var cf = colors(tui, flat())
    var cg2 = colors(tui, tglass())
    check(only_roles(cg, tglass()) and only_roles(cn, neon()) and only_roles(cf, flat()), "theme: every drawn colour is a role of the active preset", fails)
    check(cg != cn and cn != cf and cg != cf and len(cg) > 20, "theme: glass, neon and flat draw different frames", fails)
    check(legible(tglass()) and legible(neon()) and legible(flat()), "theme: text pairs reach contrast 4.5, bars and accent reach 3, in all three presets", fails)
    check(cg == cg2 and tui.d.dropped == 0, "theme: switching presets at runtime and back gives the first frame again", fails)
    # slider: a press captures the mouse, the value follows x (also outside the track), the release position counts, then it holds
    var sui = Ui(Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22]))
    var mouse = SIMD[DType.uint64, 2](0)
    var v = sframe(sui, Input(120, 32, 0, 0, 0, 0, 0, 0, mouse, False), 10)
    check(v == 10, "slider: hover alone keeps the value", fails)
    v = sframe(sui, Input(120, 32, 0, 0, 0, 1, 1, 0, mouse, False), v)
    check(v == 50, "slider: press at the middle of the track sets 50", fails)
    v = sframe(sui, Input(170, 32, 0, 0, 0, 1, 0, 0, mouse, False), v)
    check(v == 75, "slider: held motion follows the mouse", fails)
    v = sframe(sui, Input(500, 300, 0, 0, 0, 1, 0, 0, mouse, False), v)
    check(v == 100, "slider: the drag is captured outside the track, clamped", fails)
    v = sframe(sui, Input(70, 300, 0, 0, 0, 0, 0, 1, mouse, False), v)
    check(v == 25, "slider: the release position counts", fails)
    v = sframe(sui, Input(180, 32, 0, 0, 0, 0, 0, 0, mouse, False), v)
    check(v == 25 and sui.active == 0, "slider: after release the value holds and the capture is gone", fails)
    v = sframe(sui, Input(400, 32, 0, 0, 0, 1, 1, 0, mouse, False), v)
    v = sframe(sui, Input(180, 32, 0, 0, 0, 1, 0, 0, mouse, False), v)
    check(v == 25, "slider: a press outside never captures", fails)
    _ = sframe(sui, Input(180, 32, 0, 0, 0, 0, 0, 1, mouse, False), v)
    # menu: header click opens, item click picks once and closes, outside press / Escape / header click close, closed items are dead
    var mui = Ui(Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22]))
    var pick = -1
    var esc = SIMD[DType.uint64, 2](0)
    esc[0] = UInt64(1) << 41
    mframe(mui, Input(60, 35, 0, 0, 0, 0, 0, 0, mouse, False), pick)
    var closed_n = mui.d.n
    mframe(mui, Input(60, 35, 0, 0, 0, 1, 1, 0, mouse, False), pick)
    check(mui.menu == 0, "menu: a press on the header does not open it yet", fails)
    mframe(mui, Input(60, 35, 0, 0, 0, 0, 0, 1, mouse, False), pick)
    check(mui.menu == 1 and mui.d.n > closed_n and mui.over, "menu: the header click opens the popup (more commands, mouse over UI)", fails)
    mframe(mui, Input(300, 300, 0, 0, 0, 0, 0, 0, mouse, False), pick)
    check(mui.menu == 1 and pick == -1, "menu: stays open while idle", fails)
    mframe(mui, Input(60, 100, 0, 0, 0, 1, 1, 0, mouse, False), pick)
    mframe(mui, Input(60, 100, 0, 0, 0, 0, 0, 1, mouse, False), pick)
    var picked_once = pick == 1 and mui.menu == 0
    mframe(mui, Input(300, 300, 0, 0, 0, 0, 0, 0, mouse, False), pick)
    check(picked_once and pick == 1 and mui.d.n == closed_n, "menu: item 1 picked once, the popup gone next frame", fails)
    pick = -1
    mframe(mui, Input(60, 100, 0, 0, 0, 1, 1, 0, mouse, False), pick)
    mframe(mui, Input(60, 100, 0, 0, 0, 0, 0, 1, mouse, False), pick)
    check(pick == -1, "menu: a closed menu has no clickable items", fails)
    mui.menu = 1
    mframe(mui, Input(400, 300, 0, 0, 0, 1, 1, 0, mouse, False), pick)
    check(mui.menu == 0, "menu: a press outside closes it", fails)
    mui.menu = 1
    mframe(mui, Input(300, 300, 0, 0, 0, 0, 0, 0, esc, False), pick)
    check(mui.menu == 0, "menu: Escape closes it", fails)
    mui.menu = 1
    mframe(mui, Input(60, 35, 0, 0, 0, 1, 1, 0, mouse, False), pick)
    mframe(mui, Input(60, 35, 0, 0, 0, 0, 0, 1, mouse, False), pick)
    check(mui.menu == 0, "menu: the header click toggles it closed", fails)
    # scroll list: only rows touching the viewport, clipped to it; the wheel over it scrolls, clamped; commands do not grow with the row count
    var lui = Ui(Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22]))
    var off = Float32(0)
    var sel = -1
    var fe = lframe(lui, Input(60, 60, 0, 0, 0, 0, 0, 0, mouse, False), 50, off, sel)
    check(fe[0] == 0 and fe[1] == 5, "scroll list: rows 0..4 touch the 100 high viewport (the last is clipped)", fails)
    var n50 = lui.d.n
    fe = lframe(lui, Input(60, 60, 0, 0, -2, 0, 0, 0, mouse, False), 50, off, sel)
    check(off == 48 and fe[0] == 2 and fe[1] == 7, "scroll list: wheel -2 scrolls two rows, rows 2..6", fails)
    fe = lframe(lui, Input(400, 300, 0, 0, -2, 0, 0, 0, mouse, False), 50, off, sel)
    check(off == 48, "scroll list: the wheel outside the viewport does nothing", fails)
    off = 10
    fe = lframe(lui, Input(400, 300, 0, 0, 0, 0, 0, 0, mouse, False), 50, off, sel)
    check(fe[0] == 0 and fe[1] == 5, "scroll list: a part-row offset still draws the touched rows", fails)
    off = 0
    _ = lframe(lui, Input(60, 130, 0, 0, 0, 1, 1, 0, mouse, False), 50, off, sel)  # row 4: y 116 to 140, the viewport ends at 120
    _ = lframe(lui, Input(60, 130, 0, 0, 0, 0, 0, 1, mouse, False), 50, off, sel)
    check(sel == -1, "scroll list: the clipped part of an edge row is not clickable", fails)
    _ = lframe(lui, Input(60, 118, 0, 0, 0, 1, 1, 0, mouse, False), 50, off, sel)
    _ = lframe(lui, Input(60, 118, 0, 0, 0, 0, 0, 1, mouse, False), 50, off, sel)
    check(sel == 4, "scroll list: the visible part of an edge row is", fails)
    off = 48
    _ = lframe(lui, Input(60, 56, 0, 0, 0, 1, 1, 0, mouse, False), 50, off, sel)  # row 3: y 44 to 68
    _ = lframe(lui, Input(60, 56, 0, 0, 0, 0, 0, 1, mouse, False), 50, off, sel)
    check(sel == 3, "scroll list: a click on a scrolled row selects it", fails)
    _ = lframe(lui, Input(400, 300, 0, 0, -1000, 0, 0, 0, mouse, False), 50, off, sel)
    var top = off
    _ = lframe(lui, Input(60, 60, 0, 0, -1000, 0, 0, 0, mouse, False), 50, off, sel)
    var bottom = off
    _ = lframe(lui, Input(60, 60, 0, 0, 1000, 0, 0, 0, mouse, False), 50, off, sel)
    check(bottom == 50 * 24 - 100 and off == 0 and top == 48, "scroll list: offset clamps to 0 and rows * rh - h", fails)
    off = 0
    _ = lframe(lui, Input(400, 300, 0, 0, 0, 0, 0, 0, mouse, False), 50, off, sel)
    var clips = 0
    for k in range(lui.d.n):
        clips += 1 if Int(lui.d.cmd[k * 8] & 255) == CLIP else 0
    check(clips == 2 and Int(lui.d.cmd[(lui.d.n - 1) * 8] & 255) != CLIP, "scroll list: one clip and one unclip around the rows", fails)
    _ = lframe(lui, Input(400, 300, 0, 0, 0, 0, 0, 0, mouse, False), 100000, off, sel)
    check(lui.d.n == n50, "scroll list: 100000 rows emit the same commands as 50", fails)
    # table: header, columns, cells cut to their column, whole visible rows only, row click, bounded commands
    var xui = Ui(Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22]))
    var toff = Float32(0)
    var tsel = -1
    tframe(xui, Input(400, 400, 0, 0, 0, 0, 0, 0, mouse, False), 1000, 60, toff, tsel)
    var glyphs = count(xui, GLYPH)
    var right = Float32(0)
    for k in range(xui.d.n):
        if Int(xui.d.cmd[k * 8]) == GLYPH:
            right = max(right, flt(xui.d.cmd[k * 8 + 3]))
    var tn = xui.d.n
    check(right <= 20 + 240 and glyphs > 20, "table: every glyph ends inside the table width (cells and header cut to their column)", fails)
    tframe(xui, Input(400, 400, 0, 0, 0, 0, 0, 0, mouse, False), 1000, 600, toff, tsel)
    check(count(xui, GLYPH) > glyphs, "table: a wider column shows more of the long text", fails)
    tframe(xui, Input(60, 84, 0, 0, 0, 1, 1, 0, mouse, False), 1000, 60, toff, tsel)  # row 1: y 72 to 96
    tframe(xui, Input(60, 84, 0, 0, 0, 0, 0, 1, mouse, False), 1000, 60, toff, tsel)
    check(tsel == 1, "table: a click on a row selects it", fails)
    tframe(xui, Input(60, 30, 0, 0, 0, 1, 1, 0, mouse, False), 1000, 60, toff, tsel)  # header
    tframe(xui, Input(60, 30, 0, 0, 0, 0, 0, 1, mouse, False), 1000, 60, toff, tsel)
    check(tsel == 1, "table: a click on the header selects no row", fails)
    tframe(xui, Input(400, 400, 0, 0, 0, 0, 0, 0, mouse, False), 1000000, 60, toff, tsel)
    check(abs(xui.d.n - tn) <= 1, "table: a million rows emit the commands of a thousand (the selected row's background aside)", fails)
    # plot: one point per pixel column, the spike survives, tiny inputs do not crash
    var pui = Ui(Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22]))
    var big = List[Float32](length=100000, fill=0)
    big[54321] = 10
    pframe(pui, big)
    var ptop = Float32(1e9)
    var nl = 0
    for k in range(pui.d.n):
        if Int(pui.d.cmd[k * 8]) == LINE:
            nl += 1
            if pui.d.cmd[k * 8 + 6] == pui.theme.accent:
                ptop = min(ptop, min(flt(pui.d.cmd[k * 8 + 2]), flt(pui.d.cmd[k * 8 + 4])))
    check(nl == 3 + 255 and ptop == 28, "plot: 100000 samples draw 255 segments (one point per pixel column) and the one spike reaches the top", fails)
    pframe(pui, List[Float32](length=100, fill=5))
    check(count(pui, LINE) == 3 + 99, "plot: fewer samples than pixels are drawn as they are", fails)
    pframe(pui, List[Float32](length=1, fill=5))
    pframe(pui, List[Float32]())
    check(count(pui, LINE) == 3 and pui.d.dropped == 0, "plot: one sample and none draw only the axes", fails)
    # DPI also reaches rrect and clip (lane A's methods): logical in, layer pixels out
    var rs = Ui(Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22]))
    rs.set_scale(1.5)
    rs.begin(idle)
    rs.clip(10, 10, 50, 50)
    rs.rrect(20, 20, 40, 40, 4, ACCENT)
    rs.finish()
    check(flt(rs.d.cmd[3]) == 75 and flt(rs.d.cmd[8 + 1]) == 30 and flt(rs.d.cmd[8 + 5]) == 6, "DPI 1.5: clip and rrect are scaled to layer pixels", fails)
    # a row height of 0, negative or NaN: the visible rows stay inside 0..rows (the height reads as 1), and axis labels print
    # something readable for NaN and for values Int cannot hold
    var qn = Float32(0) / Float32(0)
    var qi = Float32(1) / Float32(0)
    var sx = Ui(Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22]))
    var rows_ok = True
    for rh in [Float32(0), Float32(-4), qn, qi]:
        sx.begin(idle)
        var soff = Float32(0)
        var vr = sx.scroll_begin(2, 100, 100, 10, rh, soff)
        sx.scroll_end()
        rows_ok = rows_ok and 0 <= vr[0] <= vr[1] <= 10 and soff == soff
    check(rows_ok, "scroll_begin: a row height of 0, negative, NaN or inf keeps first <= end within the rows", fails)
    check(num(qn) == "nan" and num(qi) == ">1e9" and num(-qi) == "<-1e9" and num(1e30) == ">1e9" and num(12.34) == "12.3" and num(-0.04) == "0.0" and num(250.4) == "250", "num: NaN and huge values print as text, ordinary ones as before", fails)
    # a font size index the Font does not have: nothing is drawn or measured, the draw is counted, no out-of-range read
    var zs = Ui(Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22]))
    zs.begin(idle)
    var zx = zs.text(10, 10, "abc", 3, TEXT)
    var zy = zs.text(10, 10, "abc", -1, TEXT)
    var zw = zs.tw("abc", 3) + zs.tw("abc", -1) + zs.asc(3) + zs.asc(-1)
    var zok = zs.text(10, 10, "abc", 2, TEXT) > 10
    check(zx == 10 and zy == 10 and zw == 0 and zs.d.n == 3 and zs.d.dropped == 2 and zok, "text, width and ascent at a size index past the font's sizes: nothing, counted", fails)
    # glass and icon_img take logical coordinates too: positions and given sizes scale, an asset's own size stays in layer pixels
    rs.begin(idle)
    rs.assets.names.append("a")
    rs.assets.meta.extend([0, 8, 6])
    rs.assets.px = List[UInt32](length=48, fill=0)
    rs.glass(10, 20, 50, 60, 4, ACCENT)
    _ = rs.icon_img("a", 10, 20)
    _ = rs.icon_img("a", 10, 20, 16, 12)
    rs.finish()
    check(rs.d.n == 3 and flt(rs.d.cmd[1]) == 15 and flt(rs.d.cmd[4]) == 90 and flt(rs.d.cmd[5]) == 6, "DPI 1.5: glass is scaled to layer pixels", fails)
    check(flt(rs.d.cmd[8 + 1]) == 15 and flt(rs.d.cmd[8 + 2]) == 30 and flt(rs.d.cmd[8 + 3]) == 23 and flt(rs.d.cmd[8 + 4]) == 36, "DPI 1.5: icon_img origin scales, its own size stays in layer pixels", fails)
    check(flt(rs.d.cmd[16 + 3]) == 15 + 24 and flt(rs.d.cmd[16 + 4]) == 30 + 18, "DPI 1.5: icon_img with a given size scales it", fails)
    if fails:
        raise Error("FAIL " + String(fails) + " ui_cpu checks")
    print("PASS ui_cpu_test")
