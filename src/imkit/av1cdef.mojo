"""AV1 constrained directional enhancement filter (spec 7.15).

`cdef(frame, pre, inp)`: `pre` is CurrFrame (deblocked), `frame` receives CdefFrame. Planes must cover MiCols*4 x MiRows*4
luma samples (chroma shifted); `frame` and `pre` must have equal geometry. Strengths are the spec's values after the header
step "sec strength 3 becomes 4" (lane A applies it when reading cdef_y_sec_strength / cdef_uv_sec_strength).
"""
from imkit.av1frame import Frame
from imkit.av1tab import Tables


struct CdefInput(Copyable, Movable):
    var mi_rows: Int
    var mi_cols: Int
    var cdef_damping: Int  # CdefDamping (cdef_damping_minus_3 + 3)
    var cdef_y_pri_strength: List[Int]  # 8 entries, index idx
    var cdef_y_sec_strength: List[Int]
    var cdef_uv_pri_strength: List[Int]
    var cdef_uv_sec_strength: List[Int]
    var cdef_idx: List[Int8]  # per 64x64 luma block, index (row >> 4) * cdef_stride + (col >> 4); -1 = no filtering
    var cdef_stride: Int  # (mi_cols + 15) >> 4
    var skips: List[UInt8]  # Skips, per 4x4 luma unit, index row * mi_cols + col

    def __init__(out self, mi_rows: Int, mi_cols: Int):
        self.mi_rows = mi_rows
        self.mi_cols = mi_cols
        self.cdef_damping = 3
        self.cdef_y_pri_strength = List[Int](length=8, fill=0)
        self.cdef_y_sec_strength = List[Int](length=8, fill=0)
        self.cdef_uv_pri_strength = List[Int](length=8, fill=0)
        self.cdef_uv_sec_strength = List[Int](length=8, fill=0)
        self.cdef_stride = (mi_cols + 15) >> 4
        self.cdef_idx = List[Int8](length=((mi_rows + 15) >> 4) * self.cdef_stride, fill=-1)
        self.skips = List[UInt8](length=mi_rows * mi_cols, fill=0)


def _floor_log2(x: Int) -> Int:
    var n = 0
    var v = x
    while v > 1:
        v >>= 1
        n += 1
    return n


def cdef_direction(pre: Frame, t: Tables, r: Int, c: Int) -> Tuple[Int, Int]:
    """7.15.2: (yDir, var) of the 8x8 luma block at 4x4 unit (r, c)."""
    var partial = List[Int](length=8 * 15, fill=0)
    var cost = List[Int](length=8, fill=0)
    var x0 = c << 2
    var y0 = r << 2
    var sh = pre.bit_depth - 8
    ref pl = pre.planes[0]
    for i in range(8):
        for j in range(8):
            var x = (pl.get(x0 + j, y0 + i) >> sh) - 128
            partial[0 * 15 + i + j] += x
            partial[1 * 15 + i + j // 2] += x
            partial[2 * 15 + i] += x
            partial[3 * 15 + 3 + i - j // 2] += x
            partial[4 * 15 + 7 + i - j] += x
            partial[5 * 15 + 3 - i // 2 + j] += x
            partial[6 * 15 + j] += x
            partial[7 * 15 + i // 2 + j] += x
    var d8 = Int(t.div_table[8])
    for i in range(8):
        cost[2] += partial[2 * 15 + i] * partial[2 * 15 + i]
        cost[6] += partial[6 * 15 + i] * partial[6 * 15 + i]
    cost[2] *= d8
    cost[6] *= d8
    for i in range(7):
        var dv = Int(t.div_table[i + 1])
        cost[0] += (partial[i] * partial[i] + partial[14 - i] * partial[14 - i]) * dv
        cost[4] += (partial[4 * 15 + i] * partial[4 * 15 + i] + partial[4 * 15 + 14 - i] * partial[4 * 15 + 14 - i]) * dv
    cost[0] += partial[7] * partial[7] * d8
    cost[4] += partial[4 * 15 + 7] * partial[4 * 15 + 7] * d8
    for i in range(1, 8, 2):
        for j in range(5):
            cost[i] += partial[i * 15 + 3 + j] * partial[i * 15 + 3 + j]
        cost[i] *= d8
        for j in range(3):
            cost[i] += (partial[i * 15 + j] * partial[i * 15 + j] + partial[i * 15 + 10 - j] * partial[i * 15 + 10 - j]) * Int(
                t.div_table[2 * j + 2]
            )
    var best_cost = 0
    var y_dir = 0
    for i in range(8):
        if cost[i] > best_cost:
            best_cost = cost[i]
            y_dir = i
    return (y_dir, (best_cost - cost[(y_dir + 4) & 7]) >> 10)


def _constrain(diff: Int, threshold: Int, damping: Int) -> Int:
    if threshold == 0:
        return 0
    var adj = max(0, damping - _floor_log2(threshold))
    var a = abs(diff)
    var v = max(0, min(a, threshold - (a >> adj)))
    return -v if diff < 0 else v


def _filter_block(
    mut frame: Frame, pre: Frame, t: Tables, inp: CdefInput, plane: Int, r: Int, c: Int, pri: Int, sec: Int, damping: Int, dir: Int
):
    """7.15.3 for one 8x8 luma-unit block of `plane`."""
    var sub_x = 0 if plane == 0 else pre.sub_x
    var sub_y = 0 if plane == 0 else pre.sub_y
    var shift = pre.bit_depth - 8
    var x0 = (c * 4) >> sub_x
    var y0 = (r * 4) >> sub_y
    var w = 8 >> sub_x
    var h = 8 >> sub_y
    var tap_set = (pri >> shift) & 1
    ref src = pre.planes[plane]
    for i in range(h):
        for j in range(w):
            var s = 0
            var x = src.get(x0 + j, y0 + i)
            var mx = x
            var mn = x
            for k in range(2):
                for sgn in range(-1, 2, 2):
                    for slot in range(3):  # 0: primary along dir, 1/2: secondary along dir -2 / dir + 2
                        var d = dir if slot == 0 else (dir + (-2 if slot == 1 else 2)) & 7
                        var yy = y0 + i + sgn * Int(t.cdef_directions[(d * 2 + k) * 2])
                        var xx = x0 + j + sgn * Int(t.cdef_directions[(d * 2 + k) * 2 + 1])
                        var cand_r = (yy << sub_y) >> 2
                        var cand_c = (xx << sub_x) >> 2
                        if cand_r < 0 or cand_r >= inp.mi_rows or cand_c < 0 or cand_c >= inp.mi_cols:
                            continue
                        var p = src.get(xx, yy)
                        if slot == 0:
                            s += Int(t.cdef_pri_taps[tap_set * 2 + k]) * _constrain(p - x, pri, damping)
                        else:
                            s += Int(t.cdef_sec_taps[tap_set * 2 + k]) * _constrain(p - x, sec, damping)
                        mx = max(p, mx)
                        mn = min(p, mn)
            var v = x + ((8 + s - (1 if s < 0 else 0)) >> 4)
            frame.planes[plane].set(x0 + j, y0 + i, max(mn, min(mx, v)))


def cdef(mut frame: Frame, pre: Frame, inp: CdefInput) raises:
    """Spec 7.15: CdefFrame (`frame`) from CurrFrame (`pre`), one 8x8 block at a time."""
    var num_planes = len(pre.planes)
    if len(frame.planes) != num_planes:
        raise Error("cdef: frame and pre differ in plane count")
    if len(inp.skips) != inp.mi_rows * inp.mi_cols or inp.mi_rows % 2 != 0 or inp.mi_cols % 2 != 0:
        raise Error("cdef: bad mi dimensions")
    for p in range(num_planes):
        var sx = 0 if p == 0 else pre.sub_x
        var sy = 0 if p == 0 else pre.sub_y
        if pre.planes[p].w < (inp.mi_cols * 4) >> sx or pre.planes[p].h < (inp.mi_rows * 4) >> sy:
            raise Error("cdef: plane too small")
        if frame.planes[p].w != pre.planes[p].w or frame.planes[p].h != pre.planes[p].h:
            raise Error("cdef: frame and pre differ in geometry")
    var t = Tables()
    var shift = pre.bit_depth - 8
    for r in range(0, inp.mi_rows, 2):
        for c in range(0, inp.mi_cols, 2):
            for p in range(num_planes):  # the block copy of 7.15.1
                var sx = 0 if p == 0 else pre.sub_x
                var sy = 0 if p == 0 else pre.sub_y
                for y in range((r * 4) >> sy, (r * 4 + 8) >> sy):
                    for x in range((c * 4) >> sx, (c * 4 + 8) >> sx):
                        frame.planes[p].set(x, y, pre.planes[p].get(x, y))
            var idx = Int(inp.cdef_idx[(r >> 4) * inp.cdef_stride + (c >> 4)])
            if idx == -1:
                continue
            if idx < 0 or idx > 7:
                raise Error("cdef: bad cdef_idx " + String(idx))
            var u = r * inp.mi_cols + c
            if inp.skips[u] != 0 and inp.skips[u + inp.mi_cols] != 0 and inp.skips[u + 1] != 0 and inp.skips[u + inp.mi_cols + 1] != 0:
                continue
            var dv = cdef_direction(pre, t, r, c)
            var y_dir = dv[0]
            var var_ = dv[1]
            var pri = inp.cdef_y_pri_strength[idx] << shift
            var sec = inp.cdef_y_sec_strength[idx] << shift
            var dir = 0 if pri == 0 else y_dir
            var var_str = min(_floor_log2(var_ >> 6), 12) if (var_ >> 6) != 0 else 0
            pri = ((pri * (4 + var_str) + 8) >> 4) if var_ != 0 else 0
            var damping = inp.cdef_damping + shift
            _filter_block(frame, pre, t, inp, 0, r, c, pri, sec, damping, dir)
            if num_planes == 1:
                continue
            pri = inp.cdef_uv_pri_strength[idx] << shift
            sec = inp.cdef_uv_sec_strength[idx] << shift
            dir = 0 if pri == 0 else Int(t.cdef_uv_dir[(pre.sub_x * 2 + pre.sub_y) * 8 + y_dir])
            damping = inp.cdef_damping + shift - 1
            _filter_block(frame, pre, t, inp, 1, r, c, pri, sec, damping, dir)
            _filter_block(frame, pre, t, inp, 2, r, c, pri, sec, damping, dir)
