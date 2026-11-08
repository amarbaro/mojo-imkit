"""Ui check without a GPU or a window: scripted input through widgets, the draw list and its tile bins.
Gates: a click is press then release on the same widget (not a press alone, not a second release); a press elsewhere
makes no click; the panel's command sits in the bin of a tile it covers and not in a far tile; bins hold exactly the
entries the spans predict; a frame past NBIN tile entries drops whole commands, counted, and keeps off[last] <= NBIN;
a list past NCMD commands drops, counted; text fields: typing keeps ASCII 32-126, Backspace, a maximum length, focus by click and
the focused flag; image_fits (set_image's check) and an image rect larger than the layer clipped to its tiles. PASS / FAIL, exit 1 on any FAIL.

usage: IMKIT_FONT=/path/font.ttf mojo run -I src tests/ui_cpu_test.mojo  (default font: Roboto Medium)
"""
from std.os import getenv
from imkit.font import Font
from imkit.layer import image_fits
from imkit.ui import ACCENT, ISRC, NBIN, NCMD, SC_BACKSPACE, TX, TY, UH, UW, Ui
from imkit.window import Input


def check(ok: Bool, name: String, mut fails: Int):
    print(("PASS " if ok else "FAIL ") + name)
    if not ok:
        fails += 1


def in_bin(ui: Ui, tile: Int, k: Int) -> Bool:
    for j in range(Int(ui.off[tile]), Int(ui.off[tile + 1])):
        if Int(ui.bins[j]) == k:
            return True
    return False


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
    check(ui.dropped == 0 and ui.n > 10, "demo frame: commands kept, none dropped", fails)
    # the panel background is the second command (shadow first); it covers tile (60 / 16, 400 / 16) and not the far corner
    var near = (60 // 16) * TX + 400 // 16
    var far = (TY - 1) * TX + (TX - 1)
    check(in_bin(ui, near, 1) and not in_bin(ui, far, 1), "panel command is in a covered tile's bin and not in a far one", fails)
    var total = 0
    for k in range(ui.n):
        var s = ui.span(k)
        total += Int(s[1] - s[0]) * Int(s[3] - s[2])
    check(Int(ui.off[TX * TY]) == total and total <= NBIN, "bin entries equal the sum of the spans", fails)
    # tile entry overflow: full-screen rects touch every tile; past NBIN whole commands drop
    ui.dropped = 0
    ui.begin(idle)
    var want = NBIN // (TX * TY) + 5
    for _ in range(want):
        ui.rect(0, 0, Float32(TX * 16), Float32(TY * 16), 0, ACCENT)
    ui.finish()
    check(ui.n == NBIN // (TX * TY) and ui.dropped == want - NBIN // (TX * TY) and Int(ui.off[TX * TY]) <= NBIN, "past NBIN whole commands drop, counted", fails)
    # command list overflow
    ui.dropped = 0
    ui.begin(idle)
    for _ in range(NCMD + 10):
        ui.rect(0, 0, 4, 4, 0, ACCENT)
    check(ui.n == NCMD and ui.dropped == 10, "past NCMD commands drop, counted", fails)
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
    # a 4 x 4 image on a rect much larger than the layer (and one starting off-screen) is clipped to the tiles, not dropped
    fui.dropped = 0
    fui.begin(idle)
    fui.image(-300, -200, Float32(UW + 300), Float32(UH + 200), 0, 4, 4)
    fui.finish()
    check(fui.dropped == 0 and fui.n == 1 and Int(fui.off[TX * TY]) == TX * TY, "oversize image rect clipped to the layer's tiles", fails)
    if fails:
        raise Error("FAIL " + String(fails) + " ui_cpu checks")
    print("PASS ui_cpu_test")
