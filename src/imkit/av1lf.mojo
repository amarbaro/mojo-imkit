"""AV1 deblocking loop filter (spec 7.14), applied in place to a `Frame`.

Lane A fills `LfInput` per 4x4 luma unit (flat lists, index `row * mi_cols + col`) and calls `loop_filter(frame, inp)`.
Frame planes must cover MiCols*4 x MiRows*4 luma samples (chroma shifted); a smaller plane raises `lf: plane too small`.
"""
from imkit.av1frame import Frame, Plane
from imkit.av1tab import Tables

comptime LF_NEARESTMV = 14  # YMode values of spec 6.10.22
comptime LF_GLOBALMV = 16
comptime LF_GLOBAL_GLOBALMV = 24
comptime LF_MAX = 63  # MAX_LOOP_FILTER


struct LfInput(Copyable, Movable):
    """Everything the deblocking filter reads that is not a sample (spec names in snake_case)."""

    var mi_rows: Int
    var mi_cols: Int
    var frame_width: Int
    var frame_height: Int
    var loop_filter_level: List[Int]  # 4: Y vertical, Y horizontal, U, V
    var loop_filter_sharpness: Int
    var loop_filter_delta_enabled: Bool
    var loop_filter_ref_deltas: List[Int]  # 8
    var loop_filter_mode_deltas: List[Int]  # 2
    var delta_lf_multi: Bool
    var seg_feature_enabled: List[Bool]  # [segment * 8 + feature], as FrameHeader
    var seg_feature_data: List[Int]  # [segment * 8 + feature]
    # per 4x4 luma unit, index row * mi_cols + col
    var mi_sizes: List[UInt8]  # MiSizes
    var skips: List[UInt8]  # Skips
    var ref_frames: List[Int8]  # RefFrames[][][0] (INTRA_FRAME = 0; intrabc stores INTRA_FRAME)
    var y_modes: List[UInt8]  # YModes
    var segment_ids: List[UInt8]  # SegmentIds
    var delta_lfs: List[Int8]  # DeltaLFs, 4 per unit: index (row * mi_cols + col) * 4 + k
    # LoopfilterTxSizes[plane], index (row >> sub_y) * mi_cols + (col >> sub_x), row/col in luma 4x4 units
    var lf_tx_sizes: List[List[UInt8]]

    def __init__(out self, mi_rows: Int, mi_cols: Int, frame_width: Int, frame_height: Int, num_planes: Int):
        self.mi_rows = mi_rows
        self.mi_cols = mi_cols
        self.frame_width = frame_width
        self.frame_height = frame_height
        self.loop_filter_level = List[Int](length=4, fill=0)
        self.loop_filter_sharpness = 0
        self.loop_filter_delta_enabled = False
        self.loop_filter_ref_deltas = [1, 0, 0, 0, -1, 0, -1, -1]  # spec defaults
        self.loop_filter_mode_deltas = List[Int](length=2, fill=0)
        self.delta_lf_multi = False
        self.seg_feature_enabled = List[Bool](length=64, fill=False)
        self.seg_feature_data = List[Int](length=64, fill=0)
        var n = mi_rows * mi_cols
        self.mi_sizes = List[UInt8](length=n, fill=0)
        self.skips = List[UInt8](length=n, fill=0)
        self.ref_frames = List[Int8](length=n, fill=0)
        self.y_modes = List[UInt8](length=n, fill=0)
        self.segment_ids = List[UInt8](length=n, fill=0)
        self.delta_lfs = List[Int8](length=n * 4, fill=0)
        self.lf_tx_sizes = List[List[UInt8]]()
        for _ in range(num_planes):
            self.lf_tx_sizes.append(List[UInt8](length=n, fill=0))


def _residual_size(t: Tables, mi_size: Int, sub_x: Int, sub_y: Int) -> Int:
    """get_plane_residual_size: the block size whose dimensions are the plane block's (at least 4 samples each way)."""
    var w = max(4, (Int(t.num_4x4_blocks_wide[mi_size]) * 4) >> sub_x)
    var h = max(4, (Int(t.num_4x4_blocks_high[mi_size]) * 4) >> sub_y)
    for b in range(22):
        if Int(t.num_4x4_blocks_wide[b]) * 4 == w and Int(t.num_4x4_blocks_high[b]) * 4 == h:
            return b
    return 22  # BLOCK_INVALID, caught by the caller


def _clip3(lo: Int, hi: Int, v: Int) -> Int:
    return lo if v < lo else (hi if v > hi else v)


def _round2(x: Int, n: Int) -> Int:
    return (x + ((1 << n) >> 1)) >> n if n > 0 else x


def _filter_level(inp: LfInput, row: Int, col: Int, plane: Int, pss: Int) -> Int:
    """7.14.4 + 7.14.5: lvl for the mode info unit at (row, col)."""
    var u = row * inp.mi_cols + col
    var segment = Int(inp.segment_ids[u])
    var ref0 = Int(inp.ref_frames[u])
    var mode = Int(inp.y_modes[u])
    var mode_type = 1 if (mode >= LF_NEARESTMV and mode != LF_GLOBALMV and mode != LF_GLOBAL_GLOBALMV) else 0
    var i = pss if plane == 0 else plane + 1
    var delta_lf = Int(inp.delta_lfs[u * 4 + (i if inp.delta_lf_multi else 0)])
    var lvl = _clip3(0, LF_MAX, delta_lf + inp.loop_filter_level[i])
    var feature = 1 + i  # SEG_LVL_ALT_LF_Y_V + i
    if inp.seg_feature_enabled[segment * 8 + feature]:
        lvl = _clip3(0, LF_MAX, inp.seg_feature_data[segment * 8 + feature] + lvl)
    if inp.loop_filter_delta_enabled:
        var n_shift = lvl >> 5
        if ref0 <= 0:
            lvl += inp.loop_filter_ref_deltas[0] << n_shift
        else:
            lvl += (inp.loop_filter_ref_deltas[ref0] << n_shift) + (inp.loop_filter_mode_deltas[mode_type] << n_shift)
        lvl = _clip3(0, LF_MAX, lvl)
    return lvl


def _filter4_clamp(v: Int, bd: Int) -> Int:
    return _clip3(-(1 << (bd - 1)), (1 << (bd - 1)) - 1, v)


def _sample_filter(
    mut pl: Plane, base: Int, step: Int, plane: Int, limit: Int, blimit: Int, thresh: Int, filter_size: Int, bd: Int
):
    """7.14.6: filter the line through `base` (q0), samples at base + k * step, p_k at base - (k + 1) * step."""
    var s = bd - 8
    var q0 = Int(pl.px[base])
    var q1 = Int(pl.px[base + step])
    var p0 = Int(pl.px[base - step])
    var p1 = Int(pl.px[base - 2 * step])
    var thresh_bd = thresh << s
    var hev = abs(p1 - p0) > thresh_bd or abs(q1 - q0) > thresh_bd
    var filter_len = 4
    if filter_size != 4:
        filter_len = 6 if plane != 0 else (8 if filter_size == 8 else 16)
    var limit_bd = limit << s
    var blimit_bd = blimit << s
    var bad = abs(p1 - p0) > limit_bd or abs(q1 - q0) > limit_bd or abs(p0 - q0) * 2 + abs(p1 - q1) // 2 > blimit_bd
    var q2 = 0
    var p2 = 0
    var q3 = 0
    var p3 = 0
    if filter_len >= 6:
        q2 = Int(pl.px[base + 2 * step])
        p2 = Int(pl.px[base - 3 * step])
        bad = bad or abs(p2 - p1) > limit_bd or abs(q2 - q1) > limit_bd
    if filter_len >= 8:
        q3 = Int(pl.px[base + 3 * step])
        p3 = Int(pl.px[base - 4 * step])
        bad = bad or abs(p3 - p2) > limit_bd or abs(q3 - q2) > limit_bd
    if bad:
        return
    var one = 1 << s
    var flat = False
    if filter_size >= 8:
        flat = not (abs(p1 - p0) > one or abs(q1 - q0) > one or abs(p2 - p0) > one or abs(q2 - q0) > one)
        if filter_len >= 8:
            flat = flat and not (abs(p3 - p0) > one or abs(q3 - q0) > one)
    var flat2 = False
    if filter_size >= 16:
        flat2 = True
        for k in range(4, 7):
            if abs(Int(pl.px[base - (k + 1) * step]) - p0) > one or abs(Int(pl.px[base + k * step]) - q0) > one:
                flat2 = False
    if filter_size == 4 or not flat:
        # 7.14.6.3 narrow filter
        var off = 0x80 << s
        var ps1 = p1 - off
        var ps0 = p0 - off
        var qs0 = q0 - off
        var qs1 = q1 - off
        var f = _filter4_clamp(ps1 - qs1, bd) if hev else 0
        f = _filter4_clamp(f + 3 * (qs0 - ps0), bd)
        var f1 = _filter4_clamp(f + 4, bd) >> 3
        var f2 = _filter4_clamp(f + 3, bd) >> 3
        pl.px[base] = UInt16(_filter4_clamp(qs0 - f1, bd) + off)
        pl.px[base - step] = UInt16(_filter4_clamp(ps0 + f2, bd) + off)
        if not hev:
            f = _round2(f1, 1)
            pl.px[base + step] = UInt16(_filter4_clamp(qs1 - f, bd) + off)
            pl.px[base - 2 * step] = UInt16(_filter4_clamp(ps1 + f, bd) + off)
        return
    # 7.14.6.4 wide filter
    var log2 = 3 if (filter_size == 8 or not flat2) else 4
    var n = 6 if log2 == 4 else (3 if plane == 0 else 2)
    var n2 = 0 if (log2 == 3 and plane == 0) else 1
    var src = List[Int](length=14, fill=0)  # samples -(n+1) .. n at index k + 7
    for k in range(-(n + 1), n + 1):
        src[k + 7] = Int(pl.px[base + k * step])
    for i in range(-n, n):
        var t = 0
        for j in range(-n, n + 1):
            var p = _clip3(-(n + 1), n, i + j)
            t += src[p + 7] * (2 if abs(j) <= n2 else 1)
        pl.px[base + i * step] = UInt16(_round2(t, log2))


def loop_filter(mut frame: Frame, inp: LfInput) raises:
    """Spec 7.14: filter all vertical edges of a plane, then all its horizontal edges, plane by plane."""
    var num_planes = len(frame.planes)
    if len(inp.lf_tx_sizes) < num_planes:
        raise Error("lf: lf_tx_sizes has fewer planes than the frame")
    var n = inp.mi_rows * inp.mi_cols
    if len(inp.mi_sizes) != n or len(inp.delta_lfs) != n * 4:
        raise Error("lf: per-unit lists do not match mi_rows * mi_cols")
    var bd = frame.bit_depth
    var t = Tables()
    for plane in range(num_planes):
        var sub_x = 0 if plane == 0 else frame.sub_x
        var sub_y = 0 if plane == 0 else frame.sub_y
        if frame.planes[plane].w < (inp.mi_cols * 4) >> sub_x or frame.planes[plane].h < (inp.mi_rows * 4) >> sub_y:
            raise Error("lf: plane too small")
        if plane != 0 and inp.loop_filter_level[1 + plane] == 0:
            continue
        var stride = frame.planes[plane].stride
        for pss in range(2):
            var dx = 1 if pss == 0 else 0
            var dy = 1 - dx
            var step = dx + dy * stride
            for row0 in range(0, inp.mi_rows, 1 << sub_y):
                for col0 in range(0, inp.mi_cols, 1 << sub_x):
                    var x = col0 * 4
                    var y = row0 * 4
                    var row = row0 | sub_y
                    var col = col0 | sub_x
                    if x >= inp.frame_width or y >= inp.frame_height:
                        continue
                    if (pss == 0 and x == 0) or (pss == 1 and y == 0):
                        continue
                    var x_p = x >> sub_x
                    var y_p = y >> sub_y
                    var prev_row = row - (dy << sub_y)
                    var prev_col = col - (dx << sub_x)
                    var u = row * inp.mi_cols + col
                    var mi_size = Int(inp.mi_sizes[u])
                    var tx_sz = Int(inp.lf_tx_sizes[plane][(row >> sub_y) * inp.mi_cols + (col >> sub_x)])
                    var plane_size = _residual_size(t, mi_size, sub_x, sub_y)
                    if plane_size >= 22:
                        raise Error("lf: bad mi_size " + String(mi_size))
                    var skip = inp.skips[u] != 0
                    var is_intra = inp.ref_frames[u] <= 0
                    var prev_tx = Int(
                        inp.lf_tx_sizes[plane][(prev_row >> sub_y) * inp.mi_cols + (prev_col >> sub_x)]
                    )
                    var is_block_edge: Bool
                    var is_tx_edge: Bool
                    var base_size: Int
                    if pss == 0:
                        is_block_edge = x_p % Int(t.num_4x4_blocks_wide[plane_size]) * 4 == 0
                        is_tx_edge = x_p % Int(t.tx_width[tx_sz]) == 0
                        base_size = min(Int(t.tx_width[prev_tx]), Int(t.tx_width[tx_sz]))
                    else:
                        is_block_edge = y_p % Int(t.num_4x4_blocks_high[plane_size]) * 4 == 0
                        is_tx_edge = y_p % Int(t.tx_height[tx_sz]) == 0
                        base_size = min(Int(t.tx_height[prev_tx]), Int(t.tx_height[tx_sz]))
                    if not is_tx_edge or not (is_block_edge or not skip or is_intra):
                        continue
                    var filter_size = min(16 if plane == 0 else 8, base_size)
                    var lvl = _filter_level(inp, row, col, plane, pss)
                    if lvl == 0:
                        lvl = _filter_level(inp, prev_row, prev_col, plane, pss)
                    if lvl == 0:
                        continue
                    var sharp = inp.loop_filter_sharpness
                    var shift = 2 if sharp > 4 else (1 if sharp > 0 else 0)
                    var limit = _clip3(1, 9 - sharp, lvl >> shift) if sharp > 0 else max(1, lvl >> shift)
                    var blimit = 2 * (lvl + 2) + limit
                    var thresh = lvl >> 4
                    for i in range(4):
                        var base = (y_p + dx * i) * stride + x_p + dy * i
                        _sample_filter(frame.planes[plane], base, step, plane, limit, blimit, thresh, filter_size, bd)
