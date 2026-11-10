"""AV1 intra prediction (spec 7.11.2), palette prediction (7.11.4) and chroma from luma (7.11.5).

Planes are written in place. A block may overhang the plane (the spec's CurrFrame is unbounded); samples outside are never read
back, so they are not stored. Edge reads stay inside MiCols * 4 x MiRows * 4 (luma), so the planes must be at least that big
(chroma: that size shifted by the subsampling)."""
from imkit.av1frame import Frame
from imkit.av1tab import Tables
from imkit.av1recon import round2, clip3
from imkit.av1state import (
    TX_SIZES_ALL, TX_WIDTH_LOG2, TX_HEIGHT_LOG2,
    V_PRED, D67_PRED, SMOOTH_PRED, SMOOTH_V_PRED, SMOOTH_H_PRED, PAETH_PRED,
)

comptime OFF = 16  # edge arrays are indexed from -OFF (upsampling reaches -2)
comptime ANGLE_STEP = 3
comptime INTRA_FILTER_SCALE_BITS = 4


struct IntraInput:
    """Block-level spec variables read by predict_intra; lane A sets them per block.

    mi_cols, mi_rows: MiCols, MiRows (bound the edge reads). angle_delta_y / angle_delta_uv: AngleDeltaY / AngleDeltaUV.
    use_filter_intra, filter_intra_mode: use_filter_intra, filter_intra_mode (applies to plane 0 only).
    enable_intra_edge_filter: sequence flag. filter_type: result of the spec's get_filter_type(plane) (7.11.2.8: 1 when the
    block above or left uses a smooth mode), computed by lane A because it needs YModes / UVModes / RefFrames."""
    var mi_cols: Int
    var mi_rows: Int
    var angle_delta_y: Int
    var angle_delta_uv: Int
    var use_filter_intra: Bool
    var filter_intra_mode: Int
    var enable_intra_edge_filter: Bool
    var filter_type: Int

    def __init__(out self):
        self.mi_cols = 0
        self.mi_rows = 0
        self.angle_delta_y = 0
        self.angle_delta_uv = 0
        self.use_filter_intra = False
        self.filter_intra_mode = 0
        self.enable_intra_edge_filter = False
        self.filter_type = 0


def sm_weight(tables: Tables, log2: Int, i: Int) -> Int:
    """Sm_Weights_Tx_NxN[i]. The 4x4 and 8x8 tables are not generated into `Tables` (request to lane owner), spec 10.2."""
    if log2 == 2:
        var w4 = [255, 149, 85, 64]
        return w4[i]
    if log2 == 3:
        var w8 = [255, 197, 146, 105, 73, 50, 37, 32]
        return w8[i]
    if log2 == 4:
        return Int(tables.sm_weights_tx_16x16[i])
    if log2 == 5:
        return Int(tables.sm_weights_tx_32x32[i])
    return Int(tables.sm_weights_tx_64x64[i])


def edge_strength(w: Int, h: Int, filter_type: Int, delta: Int) -> Int:
    """7.11.2.9."""
    var d = delta if delta >= 0 else -delta
    var wh = w + h
    var s = 0
    if filter_type == 0:
        if wh <= 8:
            if d >= 56:
                s = 1
        elif wh <= 12:
            if d >= 40:
                s = 1
        elif wh <= 16:
            if d >= 40:
                s = 1
        elif wh <= 24:
            if d >= 8:
                s = 1
            if d >= 16:
                s = 2
            if d >= 32:
                s = 3
        elif wh <= 32:
            s = 1
            if d >= 4:
                s = 2
            if d >= 32:
                s = 3
        else:
            s = 3
    else:
        if wh <= 8:
            if d >= 40:
                s = 1
            if d >= 64:
                s = 2
        elif wh <= 16:
            if d >= 20:
                s = 1
            if d >= 48:
                s = 2
        elif wh <= 24:
            if d >= 4:
                s = 3
        else:
            s = 3
    return s


def use_upsample(w: Int, h: Int, filter_type: Int, delta: Int) -> Bool:
    """7.11.2.10."""
    var d = delta if delta >= 0 else -delta
    if d <= 0 or d >= 40:
        return False
    if filter_type == 0:
        return w + h <= 16
    return w + h <= 8


def edge_filter(mut buf: List[Int], sz: Int, strength: Int, tables: Tables):
    """7.11.2.12 on buf (entry i of the spec array is buf[OFF + i])."""
    if strength == 0:
        return
    var edge = List[Int](length=sz, fill=0)
    for i in range(sz):
        edge[i] = buf[OFF + i - 1]
    var kb = (strength - 1) * 5
    for i in range(1, sz):
        var s = 0
        for j in range(5):
            s += Int(tables.intra_edge_kernel[kb + j]) * edge[clip3(0, sz - 1, i - 2 + j)]
        buf[OFF + i - 1] = (s + 8) >> 4


def edge_upsample(mut buf: List[Int], num_px: Int, maxv: Int):
    """7.11.2.11 on buf: entries -1..numPx-1 in, entries -2..2*numPx-2 out."""
    var dup = List[Int](length=num_px + 3, fill=0)
    dup[0] = buf[OFF - 1]
    for i in range(-1, num_px):
        dup[i + 2] = buf[OFF + i]
    dup[num_px + 2] = buf[OFF + num_px - 1]
    buf[OFF - 2] = dup[0]
    for i in range(num_px):
        var s = -dup[i] + 9 * dup[i + 1] + 9 * dup[i + 2] - dup[i + 3]
        buf[OFF + 2 * i - 1] = clip3(0, maxv, Int(round2(s, 4)))
        buf[OFF + 2 * i] = dup[i + 2]


def at(buf: List[Int], i: Int) raises -> Int:
    """AboveRow[i] / LeftCol[i] with a bounds check (index derived from the stream's angle and block size)."""
    var k = OFF + i
    if k < 0 or k >= len(buf):
        raise Error("av1ipred: edge index out of range")
    return buf[k]


def predict_intra(
    mut frame: Frame,
    tables: Tables,
    inp: IntraInput,
    plane: Int,
    x: Int,
    y: Int,
    have_left: Bool,
    have_above: Bool,
    have_above_rt: Bool,
    have_below_lft: Bool,
    mode: Int,
    log2w: Int,
    log2h: Int,
) raises:
    if plane < 0 or plane >= len(frame.planes):
        raise Error("av1ipred: plane out of range")
    if mode < 0 or mode > PAETH_PRED:
        raise Error("av1ipred: mode out of range")
    if log2w < 2 or log2w > 6 or log2h < 2 or log2h > 6:
        raise Error("av1ipred: block size out of range")
    var w = 1 << log2w
    var h = 1 << log2h
    var bd = frame.bit_depth
    var maxv = (1 << bd) - 1
    var pw = frame.planes[plane].w
    var ph = frame.planes[plane].h
    if x < 0 or y < 0 or x >= pw or y >= ph:
        raise Error("av1ipred: block starts outside plane")
    if (have_left and x == 0) or (have_above and y == 0):
        raise Error("av1ipred: neighbour flag without neighbour")
    var max_x = inp.mi_cols * 4 - 1
    var max_y = inp.mi_rows * 4 - 1
    if plane > 0:
        max_x = ((inp.mi_cols * 4) >> frame.sub_x) - 1
        max_y = ((inp.mi_rows * 4) >> frame.sub_y) - 1
    if max_x >= pw or max_y >= ph:
        raise Error("av1ipred: plane smaller than MiCols * 4 x MiRows * 4")

    # edges (7.11.2): above[OFF + i] = AboveRow[i], left[OFF + i] = LeftCol[i]
    var n = w + h
    var above = List[Int](length=2 * n + 2 * OFF + 8, fill=0)
    var left = List[Int](length=2 * n + 2 * OFF + 8, fill=0)
    if not have_above and have_left:
        var v = frame.planes[plane].get(x - 1, y)
        for i in range(n):
            above[OFF + i] = v
    elif not have_above and not have_left:
        for i in range(n):
            above[OFF + i] = (1 << (bd - 1)) - 1
    else:
        var lim = min(max_x, x + (2 * w if have_above_rt else w) - 1)
        for i in range(n):
            above[OFF + i] = frame.planes[plane].get(min(lim, x + i), y - 1)
    if not have_left and have_above:
        var v = frame.planes[plane].get(x, y - 1)
        for i in range(n):
            left[OFF + i] = v
    elif not have_left and not have_above:
        for i in range(n):
            left[OFF + i] = (1 << (bd - 1)) + 1
    else:
        var lim = min(max_y, y + (2 * h if have_below_lft else h) - 1)
        for i in range(n):
            left[OFF + i] = frame.planes[plane].get(x - 1, min(lim, y + i))
    var corner: Int
    if have_above and have_left:
        corner = frame.planes[plane].get(x - 1, y - 1)
    elif have_above:
        corner = frame.planes[plane].get(x, y - 1)
    elif have_left:
        corner = frame.planes[plane].get(x - 1, y)
    else:
        corner = 1 << (bd - 1)
    above[OFF - 1] = corner
    left[OFF - 1] = corner

    var pred = List[Int](length=w * h, fill=0)
    if plane == 0 and inp.use_filter_intra:
        recursive_pred(pred, tables, above, left, inp.filter_intra_mode, w, h, maxv)
    elif mode >= V_PRED and mode <= D67_PRED:
        directional_pred(pred, tables, inp, above, left, plane, x, y, have_left, have_above, mode, w, h, max_x, max_y, maxv)
    elif mode == SMOOTH_PRED:
        for i in range(h):
            for j in range(w):
                var s = (
                    sm_weight(tables, log2h, i) * above[OFF + j]
                    + (256 - sm_weight(tables, log2h, i)) * left[OFF + h - 1]
                    + sm_weight(tables, log2w, j) * left[OFF + i]
                    + (256 - sm_weight(tables, log2w, j)) * above[OFF + w - 1]
                )
                pred[i * w + j] = Int(round2(s, 9))
    elif mode == SMOOTH_V_PRED:
        for i in range(h):
            for j in range(w):
                var s = sm_weight(tables, log2h, i) * above[OFF + j] + (256 - sm_weight(tables, log2h, i)) * left[OFF + h - 1]
                pred[i * w + j] = Int(round2(s, 8))
    elif mode == SMOOTH_H_PRED:
        for i in range(h):
            for j in range(w):
                var s = sm_weight(tables, log2w, j) * left[OFF + i] + (256 - sm_weight(tables, log2w, j)) * above[OFF + w - 1]
                pred[i * w + j] = Int(round2(s, 8))
    elif mode == PAETH_PRED:
        for i in range(h):
            for j in range(w):
                var base = above[OFF + j] + left[OFF + i] - corner
                var p_left = abs(base - left[OFF + i])
                var p_top = abs(base - above[OFF + j])
                var p_tl = abs(base - corner)
                if p_left <= p_top and p_left <= p_tl:
                    pred[i * w + j] = left[OFF + i]
                elif p_top <= p_tl:
                    pred[i * w + j] = above[OFF + j]
                else:
                    pred[i * w + j] = corner
    else:  # DC_PRED
        var v: Int
        if have_left and have_above:
            var sum = 0
            for k in range(h):
                sum += left[OFF + k]
            for k in range(w):
                sum += above[OFF + k]
            sum += (w + h) >> 1
            v = sum // (w + h)
        elif have_left:
            var sum = 0
            for k in range(h):
                sum += left[OFF + k]
            v = clip3(0, maxv, (sum + (h >> 1)) >> log2h)
        elif have_above:
            var sum = 0
            for k in range(w):
                sum += above[OFF + k]
            v = clip3(0, maxv, (sum + (w >> 1)) >> log2w)
        else:
            v = 1 << (bd - 1)
        for k in range(w * h):
            pred[k] = v

    for i in range(h):
        if y + i >= ph:
            break
        for j in range(w):
            if x + j >= pw:
                break
            frame.planes[plane].set(x + j, y + i, pred[i * w + j])


def recursive_pred(
    mut pred: List[Int], tables: Tables, above: List[Int], left: List[Int], fmode: Int, w: Int, h: Int, maxv: Int
) raises:
    """7.11.2.3 (filter intra)."""
    if fmode < 0 or fmode > 4:
        raise Error("av1ipred: filter_intra_mode out of range")
    var p = List[Int](length=7, fill=0)
    for i2 in range(h >> 1):
        for j4 in range(w >> 2):
            for i in range(7):
                if i < 5:
                    if i2 == 0:
                        p[i] = above[OFF + (j4 << 2) + i - 1]
                    elif j4 == 0 and i == 0:
                        p[i] = left[OFF + (i2 << 1) - 1]
                    else:
                        p[i] = pred[((i2 << 1) - 1) * w + (j4 << 2) + i - 1]
                else:
                    if j4 == 0:
                        p[i] = left[OFF + (i2 << 1) + i - 5]
                    else:
                        p[i] = pred[((i2 << 1) + i - 5) * w + (j4 << 2) - 1]
            for i1 in range(2):
                for j1 in range(4):
                    var pr = 0
                    for i in range(7):
                        pr += Int(tables.intra_filter_taps[(fmode * 8 + (i1 << 2) + j1) * 7 + i]) * p[i]
                    var r = Int(round2(pr, INTRA_FILTER_SCALE_BITS)) if pr >= 0 else -Int(round2(-pr, INTRA_FILTER_SCALE_BITS))
                    pred[((i2 << 1) + i1) * w + (j4 << 2) + j1] = clip3(0, maxv, r)


def directional_pred(
    mut pred: List[Int],
    tables: Tables,
    inp: IntraInput,
    mut above: List[Int],
    mut left: List[Int],
    plane: Int,
    x: Int,
    y: Int,
    have_left: Bool,
    have_above: Bool,
    mode: Int,
    w: Int,
    h: Int,
    max_x: Int,
    max_y: Int,
    maxv: Int,
) raises:
    """7.11.2.4."""
    var delta = inp.angle_delta_y if plane == 0 else inp.angle_delta_uv
    var p_angle = Int(tables.mode_to_angle[mode]) + delta * ANGLE_STEP
    var up_above = 0
    var up_left = 0
    if inp.enable_intra_edge_filter and p_angle != 90 and p_angle != 180:
        if p_angle > 90 and p_angle < 180 and w + h >= 24:
            var s = left[OFF] * 5 + above[OFF - 1] * 6 + above[OFF] * 5
            var c = Int(round2(s, 4))
            left[OFF - 1] = c
            above[OFF - 1] = c
        var ft = inp.filter_type
        if have_above:
            var st = edge_strength(w, h, ft, p_angle - 90)
            var num_px = min(w, max_x - x + 1) + (h if p_angle < 90 else 0) + 1
            edge_filter(above, num_px, st, tables)
        if have_left:
            var st = edge_strength(w, h, ft, p_angle - 180)
            var num_px = min(h, max_y - y + 1) + (w if p_angle > 180 else 0) + 1
            edge_filter(left, num_px, st, tables)
        if use_upsample(w, h, ft, p_angle - 90):
            up_above = 1
            edge_upsample(above, w + (h if p_angle < 90 else 0), maxv)
        if use_upsample(w, h, ft, p_angle - 180):
            up_left = 1
            edge_upsample(left, h + (w if p_angle > 180 else 0), maxv)

    if p_angle < 90:
        var dx = Int(tables.dr_intra_derivative[p_angle])
        var max_base_x = (w + h - 1) << up_above
        for i in range(h):
            for j in range(w):
                var idx = (i + 1) * dx
                var base = (idx >> (6 - up_above)) + (j << up_above)
                var shift = ((idx << up_above) >> 1) & 0x1F
                if base < max_base_x:
                    pred[i * w + j] = Int(round2(at(above, base) * (32 - shift) + at(above, base + 1) * shift, 5))
                else:
                    pred[i * w + j] = at(above, max_base_x)
    elif p_angle > 90 and p_angle < 180:
        var dx = Int(tables.dr_intra_derivative[180 - p_angle])
        var dy = Int(tables.dr_intra_derivative[p_angle - 90])
        for i in range(h):
            for j in range(w):
                var idx = (j << 6) - (i + 1) * dx
                var base = idx >> (6 - up_above)
                if base >= -(1 << up_above):
                    var shift = ((idx << up_above) >> 1) & 0x1F
                    pred[i * w + j] = Int(round2(at(above, base) * (32 - shift) + at(above, base + 1) * shift, 5))
                else:
                    idx = (i << 6) - (j + 1) * dy
                    base = idx >> (6 - up_left)
                    var shift = ((idx << up_left) >> 1) & 0x1F
                    pred[i * w + j] = Int(round2(at(left, base) * (32 - shift) + at(left, base + 1) * shift, 5))
    elif p_angle > 180:
        var dy = Int(tables.dr_intra_derivative[270 - p_angle])
        for i in range(h):
            for j in range(w):
                var idx = (j + 1) * dy
                var base = (idx >> (6 - up_left)) + (i << up_left)
                var shift = ((idx << up_left) >> 1) & 0x1F
                pred[i * w + j] = Int(round2(at(left, base) * (32 - shift) + at(left, base + 1) * shift, 5))
    elif p_angle == 90:
        for i in range(h):
            for j in range(w):
                pred[i * w + j] = above[OFF + j]
    else:
        for i in range(h):
            for j in range(w):
                pred[i * w + j] = left[OFF + i]


def tx_dims(tx_size: Int) raises -> Tuple[Int, Int]:
    """(log2 width, log2 height) of a transform size, from av1state's tables."""
    if tx_size < 0 or tx_size >= TX_SIZES_ALL:
        raise Error("av1ipred: tx_size out of range")
    return (materialize[TX_WIDTH_LOG2]()[tx_size], materialize[TX_HEIGHT_LOG2]()[tx_size])


def predict_palette(
    mut frame: Frame,
    plane: Int,
    start_x: Int,
    start_y: Int,
    x: Int,
    y: Int,
    tx_size: Int,
    palette: Span[UInt16, _],
    color_map: Span[UInt8, _],
    map_stride: Int,
) raises:
    """7.11.4: CurrFrame[plane][startY + i][startX + j] = palette[map[y * 4 + i][x * 4 + j]]; x, y in 4x4 units."""
    if plane < 0 or plane >= len(frame.planes):
        raise Error("av1ipred: plane out of range")
    var d = tx_dims(tx_size)
    var w = 1 << d[0]
    var h = 1 << d[1]
    var pw = frame.planes[plane].w
    var ph = frame.planes[plane].h
    if start_x < 0 or start_y < 0 or start_x >= pw or start_y >= ph:
        raise Error("av1ipred: palette block starts outside plane")
    if x < 0 or y < 0 or map_stride <= 0 or ((y * 4 + h - 1) * map_stride + x * 4 + w) > len(color_map):
        raise Error("av1ipred: color map index out of range")
    for i in range(h):
        if start_y + i >= ph:
            break
        for j in range(w):
            if start_x + j >= pw:
                break
            var c = Int(color_map[(y * 4 + i) * map_stride + x * 4 + j])
            if c >= len(palette):
                raise Error("av1ipred: palette index out of range")
            frame.planes[plane].set(start_x + j, start_y + i, Int(palette[c]))


def predict_chroma_from_luma(
    mut frame: Frame,
    plane: Int,
    start_x: Int,
    start_y: Int,
    tx_size: Int,
    alpha: Int,
    max_luma_w: Int = -1,
    max_luma_h: Int = -1,
) raises:
    """7.11.5. max_luma_w / max_luma_h = MaxLumaW / MaxLumaH (spec 5.11.35); -1 means the luma plane size.
    The chroma plane already holds the DC prediction."""
    if plane < 1 or plane >= len(frame.planes):
        raise Error("av1ipred: cfl plane out of range")
    var d = tx_dims(tx_size)
    var w = 1 << d[0]
    var h = 1 << d[1]
    var sx = frame.sub_x
    var sy = frame.sub_y
    var lw = frame.planes[0].w
    var lh = frame.planes[0].h
    var mw = lw if max_luma_w < 0 else max_luma_w
    var mh = lh if max_luma_h < 0 else max_luma_h
    var pw = frame.planes[plane].w
    var ph = frame.planes[plane].h
    if start_x < 0 or start_y < 0 or start_x >= pw or start_y >= ph:
        raise Error("av1ipred: cfl block starts outside plane")
    if mw > lw or mh > lh or mw < (1 << sx) or mh < (1 << sy):
        raise Error("av1ipred: MaxLumaW / MaxLumaH out of range")
    var luma = List[Int](length=w * h, fill=0)
    var avg = 0
    for i in range(h):
        var ly = min((start_y + i) << sy, mh - (1 << sy))
        for j in range(w):
            var lx = min((start_x + j) << sx, mw - (1 << sx))
            var t = 0
            for dy in range(sy + 1):
                for dx in range(sx + 1):
                    t += frame.planes[0].get(lx + dx, ly + dy)
            var v = t << (3 - sx - sy)
            luma[i * w + j] = v
            avg += v
    avg = Int(round2(avg, d[0] + d[1]))
    var maxv = (1 << frame.bit_depth) - 1
    for i in range(h):
        if start_y + i >= ph:
            break
        for j in range(w):
            if start_x + j >= pw:
                break
            var dc = frame.planes[plane].get(start_x + j, start_y + i)
            var m = alpha * (luma[i * w + j] - avg)
            var scaled = Int(round2(m, 6)) if m >= 0 else -Int(round2(-m, 6))
            frame.planes[plane].set(start_x + j, start_y + i, clip3(0, maxv, dc + scaled))
