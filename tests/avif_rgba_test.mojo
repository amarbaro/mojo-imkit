"""avif_decode against avifdec's 8-bit PNG (dumped as RGBA by ImageMagick): prints max and mean channel difference.
Usage: avif_rgba_test FILE.avif REF.rgba [MAXDIFF] [MEAN]; PASS only within both bars."""
from std.sys import argv
from imkit.avifrgb import avif_decode


def main() raises:
    var data: List[UInt8]
    with open(argv()[1], "r") as f:
        data = f.read_bytes()
    var want: List[UInt8]
    with open(argv()[2], "r") as f:
        want = f.read_bytes()
    var maxbar = Int(argv()[3]) if len(argv()) > 3 else 0
    var meanbar = Float64(argv()[4]) if len(argv()) > 4 else 0.0
    var r = avif_decode(Span(data))
    var w = r[0]
    var h = r[1]
    if len(want) != w * h * 4:
        raise Error("FAIL avif_rgba: reference is " + String(len(want)) + " bytes, decode is " + String(w) + "x" + String(h))
    var maxd = 0
    var sum = 0
    for i in range(w * h):
        var p = r[2][i]
        for c in range(4):
            var d = abs(Int((p >> UInt32(8 * c)) & 255) - Int(want[i * 4 + c]))
            maxd = max(maxd, d)
            sum += d
    var mean = Float64(sum) / Float64(w * h * 4)
    print("size", String(w) + "x" + String(h), "max diff", maxd, "mean", mean)
    if maxd > maxbar or mean > meanbar:
        raise Error("FAIL avif_rgba: over the bar (max " + String(maxbar) + ", mean " + String(meanbar) + ")")
    print("PASS avif_rgba")
