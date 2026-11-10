"""Style presets: every generated preset passes the contrast gate, a planted low-contrast theme is caught, flat passes, white on
black is 21:1."""
from imkit.contrast import contrast, theme_faults
from imkit.draw import rgba
from imkit.styles import STYLE_NAMES, style
from imkit.theme import Theme, amarbaro, amarbaro_light, flat


def main() raises:
    var fails = 0
    var wb = contrast(rgba(255, 255, 255, 255), rgba(0, 0, 0, 255))
    if wb < 20.99 or wb > 21.01:
        print("FAIL contrast: white/black", wb)
        fails += 1
    var bad = flat()
    bad.text = rgba(200, 200, 200, 255)  # grey text on a near-white panel
    if theme_faults(bad) == "":
        print("FAIL gate: planted low-contrast text passed")
        fails += 1
    if theme_faults(flat()) != "":
        print("FAIL gate: flat", theme_faults(flat()))
        fails += 1
    for t in [amarbaro(), amarbaro_light()]:
        if theme_faults(t) != "":
            print("FAIL gate: amarbaro preset", theme_faults(t))
            fails += 1
    var n = 0
    for name in materialize[STYLE_NAMES]():
        var f = theme_faults(style(name))
        if f != "":
            print("FAIL style", name, f)
            fails += 1
        n += 1
    try:
        _ = style("no-such-style")
        print("FAIL style: unknown name did not raise")
        fails += 1
    except:
        pass
    if fails:
        raise Error("FAIL style_test: " + String(fails))
    print("PASS style_test:", n, "presets pass the contrast gate, planted fault caught")
