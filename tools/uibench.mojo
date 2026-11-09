"""CPU-only cost of the demo frame (build + finish): 40 rounds of N frames (default 300), the minimum round reported (a loaded
machine only adds to a round; valgrind cannot run Mojo binaries here). Build twice (-I old/src, -I src) and alternate:

    mojo build -I src tools/uibench.mojo -o .work/uibench
"""
from std.os import getenv
from std.sys import argv
from std.time import perf_counter_ns
from imkit.font import Font
from imkit.draw import UW, rgba
from imkit.theme import ACCENT, BAD, GOOD, TEXT, WARN
from imkit.ui import Ui
from imkit.window import Input


def frame(mut ui: Ui, inp: Input, names: List[String], vals: List[Float32]) -> Bool:
    ui.begin(inp)
    ui.panel(24, 20, 520, 96, "Run")
    _ = ui.icon(1, 0)
    var paused = ui.icon(2, 1, True)
    _ = ui.icon(3, 2)
    _ = ui.icon(4, 3)
    _ = ui.text(ui.x + 8, 58, "t 12.40 s   0.31x   62 fps", 0, TEXT)
    ui.panel(Float32(UW - 340), 20, Float32(UW - 24), 330, "Fly 1  walk")
    for k in range(5):
        _ = ui.button(10 + k, names[k], Float32(44 if k < 3 else 60), 28, k == 0)
    ui.x, ui.y = Float32(UW - 324), Float32(112)
    ui.bar("energy", 0.82, GOOD, 280)
    ui.bar("health", 0.95, ACCENT, 280)
    ui.bar("stamina", 0.41, WARN, 280)
    ui.spark(vals, 0, 1.5, 284, 60, BAD)
    ui.finish()
    return paused


def main() raises:
    var n = Int(argv()[1]) if len(argv()) > 1 else 300
    var ui = Ui(Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22]))
    var idle = Input(300, 300, 0, 0, 0, 0, 0, 0, SIMD[DType.uint64, 2](0), False)
    var names: List[String] = ["W", "A", "D", "space", "threat"]
    var vals = List[Float32]()
    for k in range(64):
        vals.append(Float32(k % 17) / 17 + Float32(k) / 128)
    _ = frame(ui, idle, names, vals)
    var best = 1 << 60
    for _ in range(40):  # the minimum round is the one the other lanes' load did not touch
        var s = perf_counter_ns()
        for _ in range(n):
            _ = frame(ui, idle, names, vals)
        best = min(best, Int(perf_counter_ns() - s) // n)
    print("ns per frame (min of 40 rounds of", n, ")", best, "commands", ui.d.n)
