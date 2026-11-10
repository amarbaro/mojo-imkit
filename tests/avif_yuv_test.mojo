"""Stage 5 to 7 gate: decode an AVIF's primary item (or a raw .obu) to planes and compare them with a y4m written by avifdec
(libavif with libaom or dav1d), sample for sample. Usage: avif_yuv_test FILE REF.y4m. Prints per-plane mismatches and max diff,
`PASS` only when every sample of every plane is equal."""
from std.sys import argv
from imkit.avif import avif_info
from imkit.av1obu import parse_av1
from imkit.av1dec import decode_frame
from imkit.av1frame import Frame


def header_field(h: String, key: String) -> String:
    for part in h.split(" "):
        var p = String(part)
        if p.startswith(key):
            return String(p[byte = key.byte_length() :])
    return ""


def main() raises:
    var data: List[UInt8]
    with open(argv()[1], "r") as f:
        data = f.read_bytes()
    var y4m: List[UInt8]
    with open(argv()[2], "r") as f:
        y4m = f.read_bytes()
    var payload = List[UInt8]()
    if argv()[1].endswith(".obu"):
        payload = data.copy()
    else:
        var info = avif_info(Span(data))
        for i in range(info.primary_len):
            payload.append(data[info.primary_off + i])
    var frame = decode_frame(parse_av1(Span(payload)))
    var alpha = Frame(1, 1, 8, 0, 0, 1)
    var has_alpha = False
    if not argv()[1].endswith(".obu"):
        var ai = avif_info(Span(data))
        if ai.alpha_len > 0:
            var ap = List[UInt8]()
            for i in range(ai.alpha_len):
                ap.append(data[ai.alpha_off + i])
            alpha = decode_frame(parse_av1(Span(ap)))
            has_alpha = True
    var nl = 0
    while y4m[nl] != 10:
        nl += 1
    var h = String(unsafe_from_utf8=Span(y4m)[:nl])
    var c = header_field(h, "C")
    var wide = c.endswith("p10") or c.endswith("p12")
    var pos = nl + 1 + 6  # "FRAME\n"
    var total_bad = 0
    var planes = frame.planes.copy()
    if has_alpha:  # avifdec writes C444alpha: the alpha item's luma follows Y, U, V
        planes.append(alpha.planes[0].copy())
    for p in range(len(planes)):
        ref pl = planes[p]
        var bad = 0
        var maxd = 0
        for y in range(pl.h):
            for x in range(pl.w):
                var r: Int
                if wide:
                    r = Int(y4m[pos]) | (Int(y4m[pos + 1]) << 8)
                    pos += 2
                else:
                    r = Int(y4m[pos])
                    pos += 1
                var d = abs(pl.get(x, y) - r)
                if d != 0:
                    bad += 1
                    maxd = max(maxd, d)
        print("plane", p, String(pl.w) + "x" + String(pl.h), "mismatches", bad, "max diff", maxd)
        total_bad += bad
    if pos != len(y4m):
        print("FAIL y4m size: read", pos, "of", len(y4m), "bytes (plane sizes or format differ)")
        raise Error("FAIL avif_yuv")
    if total_bad > 0:
        raise Error("FAIL avif_yuv: " + String(total_bad) + " samples differ")
    print("PASS avif_yuv")
