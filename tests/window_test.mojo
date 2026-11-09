"""window.mojo check (needs a display, no GPU): opens the window, shows 120 gradient frames, pushes one event of each kind
through SDL's own queue and reads it back with poll(); in scripted mode a real-looking mouse (which 0, as SDL gives a
real mouse) between a scripted press and release is ignored; the frame rate shows vsync. PASS / FAIL per field, exit 1 on any FAIL.

usage: mojo run -I src tests/window_test.mojo
"""
from std.time import perf_counter_ns
from imkit.window import EV_BUTTON_DOWN, EV_BUTTON_UP, EV_KEY_DOWN, EV_KEY_UP, EV_MOTION, EV_QUIT, EV_TEXT, EV_WHEEL, Input, Window


def check(ok: Bool, name: String, mut fails: Int):
    print(("PASS " if ok else "FAIL ") + name)
    if not ok:
        fails += 1


def main() raises:
    comptime W = 640
    comptime H = 360
    var win = Window("window_test", W, H)
    var px = List[UInt32](length=W * H, fill=0)
    var t0 = perf_counter_ns()
    for fr in range(120):
        for i in range(W * H):
            px[i] = UInt32((i % W) * 255 // W) | UInt32(fr * 2 % 256) << 8 | UInt32((i // W) * 255 // H) << 16 | UInt32(255) << 24
        _ = win.poll()
        win.present(Int(px.unsafe_ptr()))
    var fps = 120.0 / (Float64(perf_counter_ns() - t0) / 1e9)
    var fails = 0
    win.push(EV_MOTION, 0, 100, 50, 3, -2)
    win.push(EV_BUTTON_DOWN, 1, 100, 50)
    win.push(EV_WHEEL, 0, 2)
    win.push(EV_KEY_DOWN, 44)  # space
    var a = win.poll()
    check(a.down == 1 and a.pressed == 1, "button down -> down 1, pressed 1", fails)
    check(a.wheel == 2, "wheel 2", fails)
    check(a.key(44) and not a.key(4), "space pressed, A not", fails)
    check(a.dx != 0 and a.dy != 0, "motion delta reaches dx, dy", fails)
    win.push(EV_BUTTON_UP, 1, 100, 50)
    var b = win.poll()
    check(b.down == 0 and b.released == 1, "button up -> down 0, released 1", fails)
    win.scripted = True  # a real mouse wanders in between a scripted press and release
    win.push(EV_BUTTON_DOWN, 1, 100, 50)
    win.push(EV_MOTION, 0, 10, 10, -90, -40, which=0)
    win.push(EV_BUTTON_UP, 1, 10, 10, which=0)
    var c = win.poll()
    check(c.x == 100 and c.y == 50 and c.pressed == 1 and c.released == 0 and c.dx == 0, "scripted: which 0 mouse ignored", fails)
    win.push(EV_BUTTON_UP, 1, 100, 50)
    check(win.poll().released == 1, "scripted: tagged release counts", fails)
    win.push(EV_KEY_DOWN, 26)  # W held across frames until its release
    var k1 = win.poll()
    var k2 = win.poll()
    check(k1.key(26) and not k2.key(26) and win.key_down(26), "key W: pressed once, held while down", fails)
    win.push(EV_KEY_UP, 26)
    _ = win.poll()
    check(not win.key_down(26) and not win.key_down(4), "key W released, A never down", fails)
    win.text_input(True)  # typed text: two pushed text events in one frame are joined, a key event rides along
    win.push(EV_TEXT, text="hi ")
    win.push(EV_KEY_DOWN, 42)  # Backspace
    win.push(EV_TEXT, text="you")
    var t1 = win.poll()
    check(t1.text == "hi you" and t1.key(42), "pushed text arrives joined, pushed key arrives", fails)
    check(win.poll().text == "", "text does not carry into the next frame", fails)
    var typed = String("text extra finger")  # a runtime string, not a literal: its bytes must outlive push() until poll()
    win.push(EV_TEXT, text=String(typed[byte=5:]))
    check(win.poll().text == "extra finger", "pushed runtime text equals polled text", fails)
    win.push(EV_KEY_UP, 42)
    _ = win.poll()
    win.text_input(False)
    var m = Input(1, 2, 0, 0, 0, 0, 0, 0, SIMD[DType.uint64, 2](0), False, "ab")  # merge: text joined in order
    m.merge(Input(3, 4, 0, 0, 0, 0, 0, 0, SIMD[DType.uint64, 2](0), False, "cd"))
    m.merge(Input(3, 4, 0, 0, 0, 0, 0, 0, SIMD[DType.uint64, 2](0), False))
    check(m.text == "abcd" and m.x == 3, "Input.merge joins text, newest position", fails)
    var dr = win.drawable()
    check(win.scale() > 0 and dr[0] > 0 and dr[1] > 0, "DPI: display scale and drawable size are queryable", fails)
    var lg = Input(300, 150, 6, 3, 2, 1, 1, 0, SIMD[DType.uint64, 2](0), False, "ab").logical(1.5)
    check(lg.x == 200 and lg.y == 100 and lg.dx == 4 and lg.dy == 2 and lg.wheel == 2 and lg.down == 1 and lg.text == "ab", "Input.logical(1.5): mouse / 1.5, the rest carries over", fails)
    win.push(EV_QUIT)
    check(win.poll().quit, "quit", fails)
    print("frames: 120 at", fps, "fps (vsync caps it at the display rate)")
    win.close()
    if fails:
        raise Error("FAIL " + String(fails) + " window checks")
    print("PASS window_test")
