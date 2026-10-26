"""A headless frame: widgets with a scripted click, no window and no GPU. Prints what the frame produced.

usage: IMKIT_FONT=/path/font.ttf mojo run -I src examples/quickstart.mojo  (default font: Roboto Medium)
"""
from std.os import getenv
from imkit.font import Font
from imkit.ui import TX, TY, Ui
from imkit.window import Input


def frame(mut ui: Ui, inp: Input) -> Bool:
    ui.begin(inp)
    ui.panel(20, 16, 300, 100, "Run")
    var clicked = ui.icon(1, 1)  # 0 play, 1 pause, 2 step, 3 stop
    ui.finish()  # bins the commands into 16 x 16 tiles for the compose kernel
    return clicked


def main() raises:
    var ui = Ui(Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22]))
    var keys = SIMD[DType.uint64, 2](0)
    # the pause icon sits at (36, 56) to (72, 92): press and release on it
    var press = Input(50, 70, 0, 0, 0, 1, 1, 0, keys, False)
    var release = Input(50, 70, 0, 0, 0, 0, 0, 1, keys, False)
    var before = frame(ui, press)
    var clicked = frame(ui, release)
    print("click after press:", before, "after release:", clicked)
    print("commands:", ui.n, "tile entries:", Int(ui.off[TX * TY]), "dropped:", ui.dropped)
    if before or not clicked or ui.dropped != 0 or ui.n == 0:
        raise Error("quickstart: the click or the draw list is wrong")
