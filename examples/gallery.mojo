"""Every widget, a theme switcher and UTF-8 text in one window (needs a GPU and a display).

    gallery                 interactive: click, drag the sliders, wheel over the lists, open the menu, type in the field
    gallery --shots DIR     headless: one frame per preset to DIR/gallery-<preset>.ppm, then exit (scripts/gallery.sh makes PNGs)

usage: scripts/gallery.sh [DIR]   (builds, runs under gpu-wait, converts to PNG)
"""
from std.os import getenv
from std.sys import argv
from std.math import sin
from std.time import perf_counter_ns
from max.gpu.host import DeviceContext
from imkit.draw import TX, TY, UH, UW
from imkit.font import Font
from imkit.layer import Layer
from imkit.styles import STYLE_NAMES, style
from imkit.theme import Theme, amarbaro, amarbaro_light, flat, glass, neon
from imkit.ui import Ui
from imkit.window import Input, Window



struct State(Movable):
    var preset: Int
    var playing: Bool
    var speed: Float32
    var volume: Float32
    var text: String
    var off1: Float32  # the list's and the table's scroll offsets
    var off2: Float32
    var pick1: Int
    var pick2: Int
    var wave: List[Float32]
    var last: String
    var zoom: List[Float32]

    def __init__(out self):
        self.preset, self.playing, self.speed, self.volume, self.text = 0, True, 40, 70, String("Hello, imkit")
        self.off1, self.off2, self.pick1, self.pick2, self.last = 0, 0, 2, 3, String("none")
        self.wave = List[Float32](length=4000, fill=0)
        for i in range(4000):
            self.wave[i] = 5 + 3.5 * sin(Float32(i) * 0.011) + 1.2 * sin(Float32(i) * 0.17)
        self.wave[2600] = 9.8  # one spike the decimation must keep
        self.zoom = List[Float32](length=300, fill=0)
        for i in range(300):
            self.zoom[i] = self.wave[1200 + i]


comptime NBUILT = 5  # glass, neon, flat, amarbaro, amarbaro-light; then the generated styles
comptime NPRESET = NBUILT + len(materialize[STYLE_NAMES]())


def name_of(i: Int) -> String:
    if i < NBUILT:
        return ["glass", "neon", "flat", "amarbaro", "amarbaro-light"][i]
    return String(materialize[STYLE_NAMES]()[i - NBUILT])


def theme_of(i: Int) -> Theme:
    if i < NBUILT:
        return glass() if i == 0 else (neon() if i == 1 else (flat() if i == 2 else (amarbaro() if i == 3 else amarbaro_light())))
    try:
        return style(materialize[STYLE_NAMES]()[i - NBUILT])
    except:
        return glass()


def draw(mut ui: Ui, inp: Input, dt: Float32, mut s: State):
    ui.set_theme(theme_of(s.preset))
    ui.begin(inp, dt)
    ui.panel(24, 20, 424, 350, "Controls")
    if ui.button(1, "Pause" if s.playing else "Play", 70, 30, s.playing):
        s.playing = not s.playing
    _ = ui.button(2, "Step", 60)
    if ui.button(3, "Reset", 60):
        s.speed, s.volume = 40, 70
    ui.x, ui.y = 40, ui.y + 40
    for k in range(4):
        _ = ui.icon(4 + k, k, k == 0 and s.playing)
    ui.x, ui.y = 40, ui.y + 44
    _ = ui.text(ui.x, ui.y, "Speed " + String(Int(s.speed)), 0, ui.theme.muted)
    ui.y += 18
    s.speed = ui.slider(8, s.speed, 0, 100, 360)
    _ = ui.text(ui.x, ui.y, "Volume " + String(Int(s.volume)), 0, ui.theme.muted)
    ui.y += 18
    s.volume = ui.slider(9, s.volume, 0, 100, 360)
    ui.bar("energy", 0.82, ui.theme.good, 360)
    ui.bar("health", 0.95, ui.theme.accent, 360)
    ui.bar("stamina", s.speed / 100, ui.theme.warn, 360)
    _ = ui.field(10, s.text, 24)

    ui.panel(24, 370, 424, 700, "Theme and plot")
    for k in range(3):
        if ui.button(20 + k, name_of(k), (368 - 2 * 8) / 3, 30, s.preset == k):  # three equal buttons + two 8 px gaps = 368, the panel inner width
            s.preset = k
    ui.x, ui.y = 40, ui.y + 40  # own row: three preset buttons already fill the panel width
    if ui.button(23, "style: " + name_of(max(s.preset, 3)), 368, 30, s.preset >= 3):
        s.preset = 3 if s.preset < 3 or s.preset + 1 >= NPRESET else s.preset + 1
    ui.x, ui.y = 40, ui.y + 40
    ui.plot(s.wave, 0, 10, 368, 170, ui.theme.accent)
    _ = ui.text(40, ui.y, "UTF-8: Grüße, 日本語, ✓", 0, ui.theme.muted)

    ui.panel(444, 20, 844, 700, "Lists")
    ui.x, ui.y = 460, 60
    _ = ui.text(460, ui.y, "scroll list, 60 rows, picked: " + String(s.pick1), 0, ui.theme.muted)
    ui.y += 22
    var fe = ui.scroll_begin(30, 368, 200, 60, 28, s.off1)
    for k in range(fe[0], fe[1]):
        if ui.scroll_row(100 + k, k, "Row " + String(k) + "  item " + String(k * 37 % 1000), s.pick1 == k):
            s.pick1 = k
    ui.scroll_end()
    _ = ui.text(460, ui.y + 6, "table, 100000 rows, picked: " + String(s.pick2), 0, ui.theme.muted)
    ui.y += 28
    var heads: List[String] = ["Row", "Name", "Value"]
    var widths: List[Float32] = [70, 170, 128]
    var te = ui.table_begin(31, heads, widths, 270, 100000, 26, s.off2)
    for k in range(te[0], te[1]):
        if ui.table_row(10000 + k, k, s.pick2 == k):
            s.pick2 = k
        ui.table_cell(k, 0, String(k), ui.theme.on_accent if s.pick2 == k else 0)
        ui.table_cell(k, 1, "sensor " + String(k * 7 % 101) + " with a long name")
        ui.table_cell(k, 2, String(k % 97 * 37 // 100) + "." + String(k % 97 * 37 % 100 // 10))
    ui.table_end()

    ui.panel(864, 20, 1256, 330, "Text sizes")
    ui.x, ui.y = 880, 58
    ui.heading("Display 36", 5, 360)
    ui.heading("Heading 28", 4, 360)
    _ = ui.text(880, ui.y, "Large 22 px text", 2, ui.theme.text)
    ui.y += 28
    _ = ui.text(880, ui.y, "Medium 16 px text", 1, ui.theme.text)
    ui.y += 22
    _ = ui.text(880, ui.y, "Small 13 px text", 0, ui.theme.text)
    ui.y += 18
    ui.caption("Caption 11 px, muted", 3)
    ui.x = 880
    _ = ui.badge("new", ui.theme.accent)
    _ = ui.badge("ok", ui.theme.good)
    _ = ui.badge("warn", ui.theme.warn)
    _ = ui.badge("error", ui.theme.bad)
    ui.x, ui.y = 880, ui.y + 26
    ui.separator(360)
    ui.kv("frame", "16.7 ms", 360)
    ui.kv("last menu pick", s.last, 360)

    ui.panel(864, 350, 1256, 700, "Menu")
    ui.x, ui.y = 880, 392
    _ = ui.text(880, 560, "draw menus last: draw order is z order", 0, ui.theme.muted)
    if ui.menu_begin(40, "File", 120, 4):
        if ui.menu_item("New"):
            s.last = "New"
        if ui.menu_item("Open..."):
            s.last = "Open"
        if ui.menu_item("Save"):
            s.last = "Save"
        if ui.menu_item("Quit"):
            s.last = "Quit"
        ui.menu_end()
    ui.finish()


def scene(mut px: List[UInt32]):
    """The window's backdrop: a dusk gradient with three soft blobs, so translucent panels have something behind them."""
    for y in range(UH):
        for x in range(UW):
            var r, g, b = Float32(24 + 40 * y // UH), Float32(30 + 50 * y // UH), Float32(70 + 90 * y // UH)
            for k in range(3):
                var cx, cy = Float32(250 + 400 * k), Float32(160 + 180 * (k % 2))
                var d = ((Float32(x) - cx) * (Float32(x) - cx) + (Float32(y) - cy) * (Float32(y) - cy)) / 40000
                var w = 1 / (1 + d * d)
                r, g, b = r + w * Float32(200 - 60 * k), g + w * Float32(60 + 70 * k), b + w * Float32(120 + 40 * k)
            px[y * UW + x] = UInt32(min(r, 255)) | UInt32(min(g, 255)) << 8 | UInt32(min(b, 255)) << 16 | UInt32(255) << 24


def shot(path: String, layer: Layer, bg: List[UInt32]) raises:
    """The layer blended (straight alpha) over the backdrop, as a binary PPM."""
    var ppm = List[UInt8]()
    for c in ("P6\n" + String(UW) + " " + String(UH) + "\n255\n").as_bytes():
        ppm.append(c)
    for i in range(UW * UH):
        var l = layer.pixels[i]
        var a = Int(l >> 24)
        var s = bg[i]
        for sh in [0, 8, 16]:
            ppm.append(UInt8((Int((s >> UInt32(sh)) & 255) * (255 - a) + Int((l >> UInt32(sh)) & 255) * a) // 255))
    with open(path, "w") as o:
        o.write_bytes(Span(ppm))


def main() raises:
    var ui = Ui(Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22, 11, 28, 36]))  # slots 0-2 as before; 3 = caption 11, 4 = heading 28, 5 = display 36
    var ctx = DeviceContext()
    var layer = Layer(ctx, ui)
    var bg = List[UInt32](length=UW * UH, fill=0)
    scene(bg)
    var s = State()
    var keys = SIMD[DType.uint64, 2](0)
    if len(argv()) > 2 and String(argv()[1]) == "--shots":
        var dir = String(argv()[2])
        s.off1, s.off2 = 70, 2600  # scrolled, so the clipped edge rows show
        for p in range(NPRESET):
            s.preset = p
            ui.menu = 40  # the menu open
            draw(ui, Input(600, 690, 0, 0, 0, 0, 0, 0, keys, False), 0, s)
            layer.render(ui)
            shot(dir + "/gallery-" + name_of(p) + ".ppm", layer, bg)
            print("frame", name_of(p), "commands", ui.d.n, "dropped", ui.d.dropped)
            if ui.d.dropped:
                raise Error("FAIL gallery: " + String(ui.d.dropped) + " commands dropped")
        return
    var win = Window("imkit gallery", UW, UH, UW, UH)
    win.text_input(True)
    var t = perf_counter_ns()
    while True:
        var inp = win.poll()
        if inp.quit:
            break
        var now = perf_counter_ns()
        draw(ui, inp, Float32(now - t) / 1e9, s)
        t = now
        layer.render(ui)
        win.present(Int(bg.unsafe_ptr()), Int(layer.pixels.unsafe_ptr()))
    win.close()
