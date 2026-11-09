"""font.mojo check (CPU): Roboto at 13 / 16 / 22 px into one atlas; every glyph present, metrics sane, atlas written
to OUT (.pgm) for a look (OCR reads it back). usage: IMKIT_FONT=/path/font.ttf mojo run -I src tests/font_test.mojo [OUT.pgm]  (default font: Roboto Medium)"""
from std.os import getenv
from std.sys import argv
from imkit.atlas import Skyline
from imkit.font import AH, AW, Font, GM, NCH, decode


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
    var bad = 0
    # the host atlas holds the rows in use (to the next 64), not AW x AH: the 512 KB of zeros are not allocated
    print("host atlas", len(f.atlas), "B for", f.height, "rows of", AH)
    if len(f.atlas) >= AW * AH // 2 or len(f.atlas) < AW * f.height or len(f.atlas) % (64 * AW) != 0:
        print("FAIL host atlas is not sized by the rows in use")
        fails += 1
    # a Font with more than 16 sizes: the cache key must tell size slot 16 from slot 0 (e-acute is 6 px at size 10, 13 at 26)
    var many = List[Int]()
    for k in range(17):
        many.append(10 + k)
    var mf = Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), many^)
    var g0 = mf.glyph(0, 233)
    var g16 = mf.glyph(16, 233)
    print("17 sizes: e-acute width at slot 0", mf.g[g0 + 2], "slot 16", mf.g[g16 + 2])
    if g0 == g16 or mf.g[g16 + 2] <= mf.g[g0 + 2]:
        print("FAIL size slot 16 returned slot 0's glyph")
        fails += 1
    # skyline: 300 boxes of mixed sizes on 64 x 64 stay inside, never overlap; a box bigger than the sheet is refused
    var sky = Skyline(64, 64)
    var rx = List[Int]()
    var ry = List[Int]()
    var rw = List[Int]()
    var rh = List[Int]()
    for n in range(300):
        var w, h = 3 + (n * 7) % 11, 2 + (n * 13) % 9
        var at = sky.place(w, h)
        if at[0] >= 0:
            if at[0] + w > 64 or at[1] + h > 64:
                bad += 1
            for k in range(len(rx)):
                if at[0] < rx[k] + rw[k] and rx[k] < at[0] + w and at[1] < ry[k] + rh[k] and ry[k] < at[1] + h:
                    bad += 1
            rx.append(at[0])
            ry.append(at[1])
            rw.append(w)
            rh.append(h)
    var area = 0
    for k in range(len(rw)):
        area += rw[k] * rh[k]
    print("skyline: placed", len(rx), "boxes, filled", area * 100 // 4096, "percent, overlaps or overruns", bad)
    if bad or area < 2500 or sky.place(65, 1)[0] >= 0 or sky.place(1, 65)[0] >= 0:
        fails += 1
    # UTF-8: 1 to 4 bytes, and every bad shape is one U+FFFD per byte so the scan moves on
    var u = "aé€😀".as_bytes()
    var cps = List[Int]()
    var at = 0
    while at < len(u):
        var d = decode(u, at)
        cps.append(d[0])
        at += d[1]
    var junk: List[UInt8] = [0xFF, 0xC3, 0x41, 0xE2, 0x82, 0xC0, 0x80, 0xED, 0xA0, 0x80, 0xF4, 0x90, 0x80, 0x80]  # bad lead, bad continuation, truncated, overlong, surrogate, past 10FFFF
    var bad_cp = 0
    var j = 0
    while j < len(junk):
        var d = decode(Span(junk), j)
        bad_cp += 1 if d[0] != 0xFFFD and d[0] != 0x41 else 0
        if d[1] != 1:
            bad_cp += 1
        j += d[1]
    print("utf8: aé€😀 ->", cps[0], cps[1], cps[2], cps[3], "; bad sequences off by", bad_cp)
    if len(cps) != 4 or cps[0] != 97 or cps[1] != 233 or cps[2] != 8364 or cps[3] != 128512 or bad_cp or decode(Span(junk), 1)[0] != 0xFFFD or decode(Span(junk), 2)[0] != 0x41:
        fails += 1
    # dynamic glyphs: Roboto has no CJK, the fallback does; one rasterize per (codepoint, size), rows marked dirty, '?' for a glyph neither has
    var cjk = "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc"
    var fb = Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22], cjk)
    var nofb = Font(getenv("IMKIT_FONT", "/usr/share/fonts/TTF/Roboto-Medium.ttf"), [13, 16, 22])
    fb.clean()
    var n0 = len(fb.g)
    var ri = fb.glyph(0, 0x65E5)  # 日
    var ri2 = fb.glyph(1, 0x65E5)
    var again = fb.glyph(0, 0x65E5)
    var gx, gy, gw, gh = Int(fb.g[ri]), Int(fb.g[ri + 1]), Int(fb.g[ri + 2]), Int(fb.g[ri + 3])
    var ink = 0
    for r in range(gh):
        for k in range(gw):
            ink += 1 if fb.atlas[(gy + r) * AW + gx + k] > 0 else 0
    var qi = fb.glyph(0, ord("?"))
    var pua = fb.glyph(0, 0xE000)
    var qn = nofb.glyph(0, 0x65E5)
    var e_acute = fb.glyph(0, 0xE9)
    print("dynamic: U+65E5 at", gx, gy, "size", gw, "x", gh, "ink", ink, "; new metrics", (len(fb.g) - n0) // GM, "; dirty rows", fb.dirty0, "to", fb.dirty1, "; width of 日本", fb.width("日本", 0))
    fb.clean()
    var cleaned = fb.dirty1 <= fb.dirty0
    if ri < 3 * NCH * GM or gw < 8 or gh < 8 or ink < 30 or ri2 == ri or again != ri or len(fb.g) - n0 != 4 * GM or fb.dirty0 < 0 or not cleaned or pua != qi or qn != nofb.glyph(0, ord("?")) or fb.g[e_acute + 6] <= 0 or fb.width("日本", 0) < 20 or fb.g[ri2 + 2] <= fb.g[ri + 2]:
        fails += 1
    if len(fb.atlas) < AW * fb.height or len(fb.atlas) > AW * AH:
        print("FAIL host atlas does not cover the rows a late glyph used")
        fails += 1
    var nb = fb.glyph(2, 0x672C)  # 本 at size 22 after clean()
    var ny, nh = Int(fb.g[nb + 1]), Int(fb.g[nb + 3])
    if fb.dirty0 > ny or fb.dirty1 < ny + nh or fb.dirty1 <= fb.dirty0:
        print("FAIL dirty rows do not cover a new glyph")
        fails += 1
    if len(argv()) > 1:
        with open(String(argv()[1]), "w") as o:
            o.write("P5\n" + String(AW) + " " + String(f.height) + "\n255\n")
            o.write_bytes(Span(f.atlas)[: AW * f.height])
    if not ok or fails:
        print("FAIL font_test")
        raise Error("FAIL font_test")
    print("PASS font_test")
