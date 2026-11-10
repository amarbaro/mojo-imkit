"""Generate src/imkit/styles.mojo: one Theme per style swatch (a ComfyUI picture of the style), colours measured, shape from a table.
usage: mojo run -I src tools/gen_styles.mojo OUT.mojo SHAPE.tsv swatch-NAME.png ...
Colours: k-means (k = 8) over every 16th pixel; panel = the largest cluster, accent = the most saturated cluster that is not the
panel, then each role is pushed toward black or white until the contrast gate (imkit.contrast) passes; a style that still
fails stops the run. SHAPE.tsv rows: name radius round border blur (logical units, as in Theme)."""
from std.sys import argv
from imkit.assets import png_decode
from imkit.contrast import contrast, theme_faults
from imkit.draw import rgba
from imkit.theme import Theme


def ch(c: UInt32, s: Int) -> Int:
    return Int((c >> UInt32(s)) & 255)


def mix(a: UInt32, b: UInt32, t: Float64, al: Int) -> UInt32:
    var r = Int(Float64(ch(a, 0)) * (1 - t) + Float64(ch(b, 0)) * t + 0.5)
    var g = Int(Float64(ch(a, 8)) * (1 - t) + Float64(ch(b, 8)) * t + 0.5)
    var bl = Int(Float64(ch(a, 16)) * (1 - t) + Float64(ch(b, 16)) * t + 0.5)
    return rgba(r, g, bl, al)


def sat(c: UInt32) -> Float64:
    var hi = max(ch(c, 0), max(ch(c, 8), ch(c, 16)))
    var lo = min(ch(c, 0), min(ch(c, 8), ch(c, 16)))
    return 0.0 if hi == 0 else Float64(hi - lo) / Float64(hi)


def push(c: UInt32, against: UInt32, want: Float64, al: Int) -> UInt32:
    """Move c toward black or white (whichever contrasts more with `against`) until contrast >= want."""
    var end = rgba(0, 0, 0, 255) if contrast(rgba(0, 0, 0, 255), against) > contrast(rgba(255, 255, 255, 255), against) else rgba(255, 255, 255, 255)
    for i in range(21):
        var m = mix(c, end, Float64(i) / 20, al)
        if contrast(m, against) >= want:
            return m
    return mix(c, end, 1, al)


def kmeans(px: List[UInt32]) -> Tuple[List[UInt32], List[Int]]:
    var k = 8
    var cen = List[SIMD[DType.float64, 4]]()
    for i in range(k):
        var c = px[(len(px) - 1) * i // (k - 1)]
        cen.append(SIMD[DType.float64, 4](Float64(ch(c, 0)), Float64(ch(c, 8)), Float64(ch(c, 16)), 0))
    var cnt = List[Int](length=k, fill=0)
    for _ in range(12):
        var sum = List[SIMD[DType.float64, 4]](length=k, fill=SIMD[DType.float64, 4](0))
        for j in range(k):
            cnt[j] = 0
        for c in px:
            var v = SIMD[DType.float64, 4](Float64(ch(c, 0)), Float64(ch(c, 8)), Float64(ch(c, 16)), 0)
            var best = 0
            var bd = 1e18
            for j in range(k):
                var d = ((v - cen[j]) ** 2).reduce_add()
                if d < bd:
                    bd = d
                    best = j
            sum[best] += v
            cnt[best] += 1
        for j in range(k):
            if cnt[j] > 0:
                cen[j] = sum[j] / Float64(cnt[j])
    var out = List[UInt32]()
    for j in range(k):
        out.append(rgba(Int(cen[j][0] + 0.5), Int(cen[j][1] + 0.5), Int(cen[j][2] + 0.5), 255))
    return (out^, cnt^)


def theme_of(path: String, radius: Float64, round: Float64, border: Float64, blur: Float64) raises -> Theme:
    var pic: Tuple[Int, Int, List[UInt32]]
    with open(path, "r") as f:
        pic = png_decode(Span(f.read_bytes()))
    var px = List[UInt32]()
    var i = 0
    while i < len(pic[2]):
        px.append(pic[2][i])
        i += 16
    var km = kmeans(px)
    var cols = km[0].copy()
    var cnt = km[1].copy()
    var pi = 0
    for j in range(len(cnt)):
        if cnt[j] > cnt[pi]:
            pi = j
    var ai = 0 if pi != 0 else 1
    for j in range(len(cols)):
        if j != pi and cnt[j] > 0 and sat(cols[j]) * contrast(cols[j], cols[pi]) > sat(cols[ai]) * contrast(cols[ai], cols[pi]):
            ai = j
    var panel = mix(cols[pi], cols[pi], 0, 228)
    var base = cols[pi]
    var away = rgba(255, 255, 255, 255) if contrast(rgba(255, 255, 255, 255), base) > contrast(rgba(0, 0, 0, 255), base) else rgba(0, 0, 0, 255)
    var accent = push(cols[ai], base, 3.0, 255)
    var on_accent = rgba(255, 255, 255, 255) if contrast(rgba(255, 255, 255, 255), accent) >= contrast(rgba(0, 0, 0, 255), accent) else rgba(0, 0, 0, 255)  # pure black or white: a label, not a tint
    var text = push(mix(base, away, 0.9, 255), base, 7.0, 255)
    var muted = push(mix(base, away, 0.55, 255), base, 3.2, 255)
    var good = push(rgba(52, 199, 120, 255), base, 3.0, 255)
    var warn = push(rgba(240, 170, 40, 255), base, 3.0, 255)
    var bad = push(rgba(235, 80, 80, 255), base, 3.0, 255)
    var surface = push(mix(base, away, 0.08, 255), base, 1.6, 255)  # a control must read against its panel; 1.6 so >= 1.25 survives the translucent panel on screen
    var hover = push(mix(surface, away, 0.08, 255), surface, 1.15, 255)
    if contrast(text, surface) < 4.5:  # labels sit on controls too
        text = push(text, surface, 4.5, 255)
    var t = Theme(panel, surface, hover, accent, good, warn, bad, text, on_accent, muted,
                  rgba(0, 0, 0, 110), mix(accent, accent, 0, 90), Float32(radius), Float32(round), Float32(border), Float32(blur))
    var f = theme_faults(t)
    if f != "":
        raise Error("FAIL gate " + path + ": " + f)
    return t^


def hexc(c: UInt32) -> String:
    return "rgba(" + String(ch(c, 0)) + ", " + String(ch(c, 8)) + ", " + String(ch(c, 16)) + ", " + String(ch(c, 24)) + ")"


def main() raises:
    var a = argv()
    if len(a) < 4:
        raise Error("FAIL usage: gen_styles OUT.mojo SHAPE.tsv swatch-NAME.png ...")
    var shape = Dict[String, List[Float64]]()
    with open(String(a[2]), "r") as f:
        for line in f.read().splitlines():
            var w = line.split()
            if len(w) == 5 and not w[0].startswith("#"):
                shape[String(w[0])] = [Float64(String(w[1])), Float64(String(w[2])), Float64(String(w[3])), Float64(String(w[4]))]
    var names = List[String]()
    var body = String()
    for i in range(3, len(a)):
        var p = String(a[i])
        var parts = p.split("/")
        var name = String(String(parts[len(parts) - 1]).split(".")[0]).replace("swatch-", "")
        if name not in shape:
            raise Error("FAIL shape: no row for " + name + " in " + String(a[2]))
        var s = shape[name].copy()
        var t = theme_of(p, s[0], s[1], s[2], s[3])
        names.append(name)
        body += "    if name == \"" + name + "\":\n        return Theme(" + hexc(t.panel) + ", " + hexc(t.surface) + ", " + hexc(t.hover) + ", " + hexc(t.accent) + ",\n"
        body += "                     " + hexc(t.good) + ", " + hexc(t.warn) + ", " + hexc(t.bad) + ", " + hexc(t.text) + ", " + hexc(t.on_accent) + ",\n"
        body += "                     " + hexc(t.muted) + ", " + hexc(t.shadow) + ", " + hexc(t.border_c) + ", " + String(s[0]) + ", " + String(s[1]) + ", " + String(s[2]) + ", " + String(s[3]) + ")\n"
    var out = String('"""Style presets measured from ComfyUI swatches (generated by tools/gen_styles.mojo, do not edit).\n')
    out += "Every preset passes imkit.contrast.theme_faults. `style(name)` raises on an unknown name.\n\"\"\"\n"
    out += "from .draw import rgba\nfrom .theme import Theme\n\n\ncomptime STYLE_NAMES = ["
    for i in range(len(names)):
        out += ("" if i == 0 else ", ") + "\"" + names[i] + "\""
    out += "]\n\n\ndef style(name: StringSlice) raises -> Theme:\n" + body + "    raise Error(\"unknown style: \" + String(name))\n"
    with open(String(a[1]), "w") as f:
        f.write(out)
    print("PASS gen_styles:", len(names), "styles ->", String(a[1]))
