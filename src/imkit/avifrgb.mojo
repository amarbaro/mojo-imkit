"""AVIF to 8-bit RGBA: decode the primary item (and the alpha auxiliary item when present) with av1dec, then convert YUV
to RGB with the file's matrix coefficients and range, the way libavif does: bilinear chroma upsampling with centred chroma
siting, float math, round to nearest. Pixels are r | g << 8 | b << 16 | a << 24, as `jpeg_decode` / `webp_decode`.
Matrices: 0 identity (GBR), 1 BT.709, 2 unspecified (BT.601 like libavif), 5 / 6 BT.601, 9 BT.2020 NCL; others raise."""
from imkit.avif import avif_info
from imkit.jpeg import MAXPX
from imkit.av1obu import parse_av1
from imkit.av1dec import decode_frame
from imkit.av1frame import Frame, Plane


def item_bytes(d: Span[UInt8, _], off: Int, length: Int) raises -> List[UInt8]:
    if off < 0 or length <= 0 or off + length > len(d):
        raise Error("avifrgb: item outside the file")
    var out = List[UInt8](capacity=length)
    for i in range(length):
        out.append(d[off + i])
    return out^


def kr_kb(matrix: Int) raises -> Tuple[Float64, Float64]:
    if matrix == 1:
        return (0.2126, 0.0722)
    if matrix == 2 or matrix == 5 or matrix == 6:
        return (0.299, 0.114)
    if matrix == 9:
        return (0.2627, 0.0593)
    raise Error("avifrgb: matrix coefficients " + String(matrix) + " not supported")


def chroma_at(p: Plane, x: Int, y: Int, sx: Int, sy: Int, cw: Int, ch: Int) -> Float64:
    """Bilinear sample of a subsampled chroma plane at luma position (x, y), chroma sited at the centre."""
    if sx == 0 and sy == 0:
        return Float64(p.get(x, y))
    var fx = (Float64(x) + 0.5) / Float64(1 << sx) - 0.5 if sx else Float64(x)
    var fy = (Float64(y) + 0.5) / Float64(1 << sy) - 0.5 if sy else Float64(y)
    var x0 = Int(fx) if fx >= 0 else -1
    var y0 = Int(fy) if fy >= 0 else -1
    var ax = fx - Float64(x0)
    var ay = fy - Float64(y0)
    var xa = min(max(x0, 0), cw - 1)
    var xb = min(max(x0 + 1, 0), cw - 1)
    var ya = min(max(y0, 0), ch - 1)
    var yb = min(max(y0 + 1, 0), ch - 1)
    var top = Float64(p.get(xa, ya)) * (1 - ax) + Float64(p.get(xb, ya)) * ax
    var bot = Float64(p.get(xa, yb)) * (1 - ax) + Float64(p.get(xb, yb)) * ax
    return top * (1 - ay) + bot * ay


def to8(v: Float64) -> UInt32:
    return UInt32(min(max(Int(v * 255.0 + 0.5), 0), 255))


def avif_decode(d: Span[UInt8, _]) raises -> Tuple[Int, Int, List[UInt32]]:
    """(width, height, pixels) of an AVIF still image (intra-coded primary item), RGBA 8-bit."""
    var info = avif_info(d)
    if info.width <= 0 or info.height <= 0 or info.width * info.height > MAXPX:
        raise Error("avif: " + String(info.width) + " x " + String(info.height) + " is too large")
    var st = parse_av1(Span(item_bytes(d, info.primary_off, info.primary_len)))
    var f = decode_frame(st)
    var w = f.planes[0].w
    var h = f.planes[0].h
    if w != info.width or h != info.height:
        raise Error("avifrgb: decoded size differs from the container's ispe")
    var maxv = Float64((1 << f.bit_depth) - 1)
    var full = st.seq.color_range
    var scale = Float64(1 << (f.bit_depth - 8))
    var ym = 16.0 * scale if not full else 0.0
    var yr = 219.0 * scale if not full else maxv
    var cr = 224.0 * scale if not full else maxv
    var mid = Float64(1 << (f.bit_depth - 1))
    var mono = len(f.planes) == 1
    var identity = st.seq.matrix_coefficients == 0
    var kr = 0.0
    var kb = 0.0
    if not mono and not identity:
        var k = kr_kb(st.seq.matrix_coefficients)
        kr = k[0]
        kb = k[1]
    var kg = 1.0 - kr - kb
    var sx = f.sub_x
    var sy = f.sub_y
    var alpha = List[UInt32]()
    if info.alpha_len > 0:
        var ast = parse_av1(Span(item_bytes(d, info.alpha_off, info.alpha_len)))
        var af = decode_frame(ast)
        if af.planes[0].w != w or af.planes[0].h != h:
            raise Error("avifrgb: alpha size differs from the colour image")
        var amax = Float64((1 << af.bit_depth) - 1)
        var afull = ast.seq.color_range
        var ascale = Float64(1 << (af.bit_depth - 8))
        alpha = List[UInt32](capacity=w * h)
        for y in range(h):
            for x in range(w):
                var v = Float64(af.planes[0].get(x, y))
                var a = v / amax if afull else (v - 16.0 * ascale) / (219.0 * ascale)
                alpha.append(to8(a))
    var px = List[UInt32](capacity=w * h)
    var cw = 0
    var ch = 0
    if not mono:
        cw = f.planes[1].w
        ch = f.planes[1].h
    for y in range(h):
        for x in range(w):
            var yy = (Float64(f.planes[0].get(x, y)) - ym) / yr
            var r: Float64
            var g: Float64
            var b: Float64
            if mono:
                r = yy
                g = yy
                b = yy
            else:
                var u = chroma_at(f.planes[1], x, y, sx, sy, cw, ch)
                var v = chroma_at(f.planes[2], x, y, sx, sy, cw, ch)
                if identity:  # GBR: Y carries G, U carries B, V carries R
                    g = yy
                    b = (u - ym) / yr
                    r = (v - ym) / yr
                else:
                    var uu = (u - mid) / cr
                    var vv = (v - mid) / cr
                    r = yy + 2.0 * (1.0 - kr) * vv
                    b = yy + 2.0 * (1.0 - kb) * uu
                    g = yy - (2.0 * kr * (1.0 - kr) * vv + 2.0 * kb * (1.0 - kb) * uu) / kg
            var a = alpha[y * w + x] if len(alpha) > 0 else UInt32(255)
            px.append(to8(r) | to8(g) << 8 | to8(b) << 16 | a << 24)
    return (w, h, px^)
