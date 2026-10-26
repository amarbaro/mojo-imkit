"""font.mojo check (CPU): Roboto at 13 / 16 / 22 px into one atlas; every glyph present, metrics sane, atlas written
to OUT (.pgm) for a look (OCR reads it back). usage: IMKIT_FONT=/path/font.ttf mojo run -I src tests/font_test.mojo [OUT.pgm]  (default font: Roboto Medium)"""
from std.os import getenv
from std.sys import argv
from imkit.font import AW, Font, GM, NCH


def main() raises:
    var f = Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22])
    var fails = 0
    for s in range(3):
        for c in range(33, 127):  # every printable glyph but space has ink and an advance
            var g = f.glyph(s, c)
            if f.g[g + 2] <= 0 or f.g[g + 3] <= 0 or f.g[g + 6] <= 0:
                fails += 1
    var ok = fails == 0 and len(f.g) == 3 * NCH * GM and f.ascent[0] < f.ascent[1] < f.ascent[2] and f.width("Pause", 1) > f.width("Pause", 0)
    print("atlas", AW, "x", f.height, "(", len(f.atlas), "B ), glyphs", len(f.g) // GM, ", ascent", f.ascent[0], f.ascent[1], f.ascent[2], ", empty", fails)
    if len(argv()) > 1:
        with open(String(argv()[1]), "w") as o:
            o.write("P5\n" + String(AW) + " " + String(f.height) + "\n255\n")
            o.write_bytes(Span(f.atlas))
    if not ok:
        raise Error("FAIL font_test")
    print("PASS font_test")
