"""AV1 loop restoration (spec 7.17): Wiener and self-guided filters over 64-row stripes.

`loop_restoration(frame, cdef_out, pre_cdef, inp)`: `cdef_out` = UpscaledCdefFrame, `pre_cdef` = UpscaledCurrFrame (deblocked, not
CDEF filtered), `frame` receives LrFrame (starts as a copy of `cdef_out`). All three have the same geometry. Super-resolution
upscaling is not applied here: the caller passes frames already at UpscaledWidth. The spec filters 4x4 blocks; the output is the
same for any block inside one stripe and one restoration unit (7.17.1 note), so this walks stripe x unit regions.
"""
from imkit.av1frame import Frame
from imkit.av1tab import Tables

comptime RESTORE_NONE = 0
comptime RESTORE_WIENER = 1
comptime RESTORE_SGRPROJ = 2


struct LrInput(Copyable, Movable):
    var frame_height: Int
    var upscaled_width: Int
    var uses_lr: Bool
    var frame_restoration_type: List[Int]  # per plane: RESTORE_NONE / WIENER / SGRPROJ / SWITCHABLE (3)
    var loop_restoration_size: List[Int]  # LoopRestorationSize per plane
    var unit_rows: List[Int]  # count_units_in_frame per plane
    var unit_cols: List[Int]
    # per plane, unit index unitRow * unit_cols + unitCol
    var lr_type: List[List[UInt8]]  # LrType: RESTORE_NONE / WIENER / SGRPROJ
    var lr_wiener: List[List[Int]]  # LrWiener, 6 per unit: [pass * 3 + i], pass 0 = vertical, 1 = horizontal
    var lr_sgr_set: List[List[UInt8]]  # LrSgrSet
    var lr_sgr_xqd: List[List[Int]]  # LrSgrXqd, 2 per unit

    def __init__(
        out self,
        frame_height: Int,
        upscaled_width: Int,
        sub_x: Int,
        sub_y: Int,
        num_planes: Int,
        uses_lr: Bool,
        frame_restoration_type: List[Int],
        loop_restoration_size: List[Int],
    ):
        self.frame_height = frame_height
        self.upscaled_width = upscaled_width
        self.uses_lr = uses_lr
        self.frame_restoration_type = frame_restoration_type.copy()
        self.loop_restoration_size = loop_restoration_size.copy()
        self.unit_rows = List[Int]()
        self.unit_cols = List[Int]()
        self.lr_type = List[List[UInt8]]()
        self.lr_wiener = List[List[Int]]()
        self.lr_sgr_set = List[List[UInt8]]()
        self.lr_sgr_xqd = List[List[Int]]()
        for p in range(num_planes):
            var sx = 0 if p == 0 else sub_x
            var sy = 0 if p == 0 else sub_y
            var size = loop_restoration_size[p]
            var rows = max((((frame_height + sy) >> sy) + (size >> 1)) // size, 1)
            var cols = max((((upscaled_width + sx) >> sx) + (size >> 1)) // size, 1)
            self.unit_rows.append(rows)
            self.unit_cols.append(cols)
            self.lr_type.append(List[UInt8](length=rows * cols, fill=0))
            self.lr_wiener.append(List[Int](length=rows * cols * 6, fill=0))
            self.lr_sgr_set.append(List[UInt8](length=rows * cols, fill=0))
            self.lr_sgr_xqd.append(List[Int](length=rows * cols * 2, fill=0))


def _round2(x: Int, n: Int) -> Int:
    return (x + ((1 << n) >> 1)) >> n if n > 0 else x


def _wiener(
    mut out: Frame, plane: Int, src: List[Int], w: Int, h: Int, x0: Int, y0: Int, coef: List[Int], base: Int, bd: Int
):
    """7.17.4 on one region; `src` is the (w + 6) x (h + 6) get_source_sample window."""
    var round0 = 5 if bd == 12 else 3
    var round1 = 9 if bd == 12 else 11
    var vf = List[Int](length=7, fill=0)
    var hf = List[Int](length=7, fill=0)
    vf[3] = 128
    hf[3] = 128
    for i in range(3):
        vf[i] = coef[base + i]
        vf[6 - i] = coef[base + i]
        vf[3] -= 2 * coef[base + i]
        hf[i] = coef[base + 3 + i]
        hf[6 - i] = coef[base + 3 + i]
        hf[3] -= 2 * coef[base + 3 + i]
    var offset = 1 << (bd + 7 - round0 - 1)
    var limit = (1 << (bd + 1 + 7 - round0)) - 1
    var sw = w + 6
    var inter = List[Int](length=(h + 6) * w, fill=0)
    for r in range(h + 6):
        for c in range(w):
            var s = 0
            for t in range(7):
                s += hf[t] * src[r * sw + c + t]
            var v = _round2(s, round0)
            inter[r * w + c] = max(-offset, min(limit - offset, v))
    var maxv = (1 << bd) - 1
    for r in range(h):
        for c in range(w):
            var s = 0
            for t in range(7):
                s += vf[t] * inter[(r + t) * w + c]
            out.planes[plane].set(x0 + c, y0 + r, max(0, min(maxv, _round2(s, round1))))


def _box(src: List[Int], cdef_px: List[Int], w: Int, h: Int, t: Tables, sgr_set: Int, pss: Int, bd: Int) -> List[Int]:
    """7.17.3: F as a flat h x w list (empty when r == 0). `cdef_px` is the window's centre (w + 6 wide), as `src`."""
    var r = Int(t.sgr_params[sgr_set * 4 + pss * 2])
    if r == 0:
        return List[Int]()
    var eps = Int(t.sgr_params[sgr_set * 4 + pss * 2 + 1])
    var n = (2 * r + 1) * (2 * r + 1)
    var n2e = n * n * eps
    var s = ((1 << 20) + n2e // 2) // n2e
    var one_over_n = ((1 << 12) + n // 2) // n
    var sw = w + 6
    var aw = w + 2
    var arr_a = List[Int](length=(h + 2) * aw, fill=0)
    var arr_b = List[Int](length=(h + 2) * aw, fill=0)
    for i in range(-1, h + 1):
        if pss == 0 and (i & 1) == 0:
            continue  # only odd rows of A and B are read when pass is 0
        for j in range(-1, w + 1):
            var a = 0
            var b = 0
            for dy in range(-r, r + 1):
                for dx in range(-r, r + 1):
                    var c = src[(i + 3 + dy) * sw + j + 3 + dx]
                    a += c * c
                    b += c
            a = _round2(a, 2 * (bd - 8))
            var d = _round2(b, bd - 8)
            var p = max(0, a * n - d * d)
            var z = _round2(p * s, 20)
            var a2: Int
            if z >= 255:
                a2 = 256
            elif z == 0:
                a2 = 1
            else:
                a2 = ((z << 8) + z // 2) // (z + 1)
            arr_a[(i + 1) * aw + j + 1] = a2
            arr_b[(i + 1) * aw + j + 1] = _round2((256 - a2) * b * one_over_n, 12)
    var f = List[Int](length=h * w, fill=0)
    for i in range(h):
        var shift = 4 if (pss == 0 and (i & 1) == 1) else 5
        for j in range(w):
            var a = 0
            var b = 0
            for dy in range(-1, 2):
                for dx in range(-1, 2):
                    var weight: Int
                    if pss == 0:
                        weight = (6 if dx == 0 else 5) if ((i + dy) & 1) == 1 else 0
                    else:
                        weight = 4 if (dx == 0 or dy == 0) else 3
                    a += weight * arr_a[(i + dy + 1) * aw + j + dx + 1]
                    b += weight * arr_b[(i + dy + 1) * aw + j + dx + 1]
            var v = a * cdef_px[(i + 3) * sw + j + 3] + b
            f[i * w + j] = _round2(v, 8 + shift - 4)
    return f^


def _selfguided(
    mut out: Frame, plane: Int, src: List[Int], w: Int, h: Int, x0: Int, y0: Int, t: Tables, sgr_set: Int, w0: Int, w1: Int, bd: Int
):
    """7.17.2 on one region."""
    var flt0 = _box(src, src, w, h, t, sgr_set, 0, bd)
    var flt1 = _box(src, src, w, h, t, sgr_set, 1, bd)
    var w2 = (1 << 7) - w0 - w1
    var r0 = Int(t.sgr_params[sgr_set * 4])
    var r1 = Int(t.sgr_params[sgr_set * 4 + 2])
    var maxv = (1 << bd) - 1
    var sw = w + 6
    for i in range(h):
        for j in range(w):
            var u = src[(i + 3) * sw + j + 3] << 4
            var v = w1 * u
            v += w0 * (flt0[i * w + j] if r0 != 0 else u)
            v += w2 * (flt1[i * w + j] if r1 != 0 else u)
            out.planes[plane].set(x0 + j, y0 + i, max(0, min(maxv, _round2(v, 4 + 7))))


def loop_restoration(mut frame: Frame, cdef_out: Frame, pre_cdef: Frame, inp: LrInput) raises:
    """Spec 7.17: restore every plane whose FrameRestorationType is not RESTORE_NONE, stripe by stripe, unit by unit."""
    var num_planes = len(cdef_out.planes)
    if len(frame.planes) != num_planes or len(pre_cdef.planes) != num_planes:
        raise Error("lr: frames differ in plane count")
    for p in range(num_planes):
        ref a = cdef_out.planes[p]
        if frame.planes[p].w != a.w or frame.planes[p].h != a.h or pre_cdef.planes[p].w != a.w or pre_cdef.planes[p].h != a.h:
            raise Error("lr: frames differ in geometry")
        for i in range(len(a.px)):  # LrFrame starts as a copy of UpscaledCdefFrame
            frame.planes[p].px[i] = a.px[i]
    if not inp.uses_lr:
        return
    var t = Tables()
    var bd = cdef_out.bit_depth
    for plane in range(num_planes):
        if inp.frame_restoration_type[plane] == RESTORE_NONE:
            continue
        var sx = 0 if plane == 0 else cdef_out.sub_x
        var sy = 0 if plane == 0 else cdef_out.sub_y
        var plane_end_x = ((inp.upscaled_width + sx) >> sx) - 1
        var plane_end_y = ((inp.frame_height + sy) >> sy) - 1
        if cdef_out.planes[plane].w <= plane_end_x or cdef_out.planes[plane].h <= plane_end_y:
            raise Error("lr: plane smaller than the frame")
        var unit_size = inp.loop_restoration_size[plane]
        if unit_size < (64 >> sy) or unit_size % (64 >> sy) != 0:  # a unit row would split a stripe (not a legal size, 5.9.20)
            raise Error("lr: unit size " + String(unit_size) + " does not hold whole stripes")
        var unit_rows = inp.unit_rows[plane]
        var unit_cols = inp.unit_cols[plane]
        var stripe = 0
        while True:
            var stripe_start = (-8 + stripe * 64) >> sy
            var stripe_end = stripe_start + (64 >> sy) - 1
            if stripe_start > plane_end_y:
                break
            var y0 = max(0, stripe_start)
            var y1 = min(plane_end_y, stripe_end)
            var unit_row = min(unit_rows - 1, (((stripe * 64) >> sy)) // unit_size)  # (lumaY + 8) >> subY over the stripe
            for unit_col in range(unit_cols):
                var x0 = unit_col * unit_size
                var x1 = plane_end_x if unit_col == unit_cols - 1 else min(plane_end_x, x0 + unit_size - 1)
                if x0 > plane_end_x:
                    break
                var w = x1 - x0 + 1
                var h = y1 - y0 + 1
                var u = unit_row * unit_cols + unit_col
                var rtype = Int(inp.lr_type[plane][u])
                if rtype == RESTORE_NONE:
                    continue
                var sw = w + 6
                var src = List[Int](length=sw * (h + 6), fill=0)  # get_source_sample window, 3 samples of border
                for r in range(-3, h + 3):
                    var yy = max(0, min(plane_end_y, y0 + r))
                    var from_pre = False
                    if yy < stripe_start:
                        yy = max(stripe_start - 2, yy)
                        from_pre = True
                    elif yy > stripe_end:
                        yy = min(stripe_end + 2, yy)
                        from_pre = True
                    for c in range(-3, w + 3):
                        var xx = max(0, min(plane_end_x, x0 + c))
                        src[(r + 3) * sw + c + 3] = pre_cdef.planes[plane].get(xx, yy) if from_pre else cdef_out.planes[plane].get(xx, yy)
                if rtype == RESTORE_WIENER:
                    _wiener(frame, plane, src, w, h, x0, y0, inp.lr_wiener[plane], u * 6, bd)
                elif rtype == RESTORE_SGRPROJ:
                    var sgr_set = Int(inp.lr_sgr_set[plane][u])
                    _selfguided(frame, plane, src, w, h, x0, y0, t, sgr_set, inp.lr_sgr_xqd[plane][u * 2], inp.lr_sgr_xqd[plane][u * 2 + 1], bd)
                else:
                    raise Error("lr: bad LrType " + String(rtype))
            stripe += 1
