"""Ui check without a GPU or a window: scripted input through widgets, the draw list and its tile bins.
Gates: a click is press then release on the same widget (not a press alone, not a second release); a press elsewhere
makes no click; the panel's command sits in the bin of a tile it covers and not in a far tile; bins hold exactly the
entries the spans predict; a frame past NBIN tile entries drops whole commands, counted, and keeps off[last] <= NBIN;
a list past NCMD commands drops, counted. PASS / FAIL, exit 1 on any FAIL.

usage: IMKIT_FONT=/path/font.ttf mojo run -I src tests/ui_cpu_test.mojo  (default font: Roboto Medium)
"""
from std.os import getenv
from imkit.font import Font
from imkit.ui import ACCENT, NBIN, NCMD, TX, TY, Ui
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
    if fails:
        raise Error("FAIL " + String(fails) + " ui_cpu checks")
    print("PASS ui_cpu_test")
