"""Memory and speed ledger of the demo frame (memory-optimization): host bytes held by Ui / Draw / Font, device and pinned
bytes held by Layer, malloc calls and bytes per frame (LD_PRELOAD .work/malloc_count.so), compose time per launch (median of 5
x 1000). Same input every run, so two commits compare. Run under gpu-wait:

    gcc -shared -fPIC -O2 -o .work/malloc_count.so tools/malloc_count.c -ldl
    mojo build -I src tools/membench.mojo -o .work/membench
    LD_PRELOAD=$PWD/.work/malloc_count.so gpu-wait run --timeout 600 -- .work/membench
"""
from std.ffi import OwnedDLHandle
from std.os import getenv
from std.sys import size_of
from std.time import perf_counter_ns
from max.gpu.host import DeviceContext
from imkit.font import Font
from imkit.draw import ISRC, NBIN, NCMD, NSTY, QH, QW, TX, TY, UH, UW, CW, rgba
from imkit.theme import ACCENT, BAD, GOOD, TEXT, WARN
from imkit.ui import Ui
from imkit.window import Input
from imkit.layer import Layer


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


def row(name: String, bytes: Int):
    print("  ", name, bytes, "B")


def main() raises:
    var mc = OwnedDLHandle(getenv("MC_SO", ".work/malloc_count.so"))
    var calls = mc.get_function[Int]("mc_calls")
    var mbytes = mc.get_function[Int]("mc_bytes")
    var ui = Ui(Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22]))
    var idle = Input(300, 300, 0, 0, 0, 0, 0, 0, SIMD[DType.uint64, 2](0), False)
    var names: List[String] = ["W", "A", "D", "space", "threat"]  # the app's own data, held outside the frame
    var vals = List[Float32]()
    for k in range(64):
        vals.append(Float32(k % 17) / 17 + Float32(k) / 128)
    _ = frame(ui, idle, names, vals)
    _ = frame(ui, idle, names, vals)
    print("host heap held (capacity x element)")
    row("Draw.cmd", ui.d.cmd.capacity() * 4)
    row("Draw.bins", ui.d.bins.capacity() * 2)
    row("Draw.off + cur", (ui.d.off.capacity() + ui.d.cur.capacity()) * 4)
    row("Draw.sty", ui.d.sty.capacity() * 4)
    row("Font.atlas", ui.d.font.atlas.capacity())
    row("Font.g", ui.d.font.g.capacity() * 2)
    row("Font.ext entries", len(ui.d.font.ext))
    row("Ui shallow size_of", size_of[Ui]())
    var t0 = calls()
    var b0 = mbytes()
    var s0 = perf_counter_ns()
    for _ in range(1000):
        _ = frame(ui, idle, names, vals)
    var ns = (perf_counter_ns() - s0) // 1000
    print("per UI frame (build + finish, 1000 frames): malloc calls", (calls() - t0) // 1000, "bytes", (mbytes() - b0) // 1000, "time", ns, "ns")
    var ctx = DeviceContext()
    var layer = Layer(ctx, ui)
    var pinned0 = len(layer.pixels) * 4
    layer.render(ui)
    print("Layer device and pinned bytes")
    row("img", len(layer.img) * 4)
    row("cmd", len(layer.cmd) * 4)
    row("bins", len(layer.bins) * 2)
    row("off", len(layer.off) * 4)
    row("atlas", len(layer.atlas))
    row("sty", len(layer.sty) * 4)
    row("scene", len(layer.scene) * 4)
    row("q x3", (len(layer.q[0]) + len(layer.q[1]) + len(layer.q[2])) * 4)
    row("src", len(layer.src) * 4)
    row("pixels (pinned host) at Layer creation", pinned0)
    row("pixels (pinned host) after the first render", len(layer.pixels) * 4)
    t0 = calls()
    b0 = mbytes()
    s0 = perf_counter_ns()
    for _ in range(200):
        layer.render_into(ui, layer.img)
    print("per render_into (200): malloc calls", (calls() - t0) // 200, "bytes", (mbytes() - b0) // 200, "time us", Float64(perf_counter_ns() - s0) / 200 / 1000)
    t0 = calls()
    b0 = mbytes()
    s0 = perf_counter_ns()
    for _ in range(200):
        layer.render(ui)
    print("per render (200): malloc calls", (calls() - t0) // 200, "bytes", (mbytes() - b0) // 200, "time us", Float64(perf_counter_ns() - s0) / 200 / 1000)
    var best = List[Float64]()
    for _ in range(5):
        var s = perf_counter_ns()
        for _ in range(1000):
            layer.launch()
        ctx.synchronize()
        best.append(Float64(perf_counter_ns() - s) / 1000 / 1000)
    sort(best)
    print("compose us per launch, median of 5 x 1000:", best[2], "(min", best[0], "max", best[4], ")")
