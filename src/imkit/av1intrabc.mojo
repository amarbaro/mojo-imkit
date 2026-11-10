"""Intra block copy: the motion vector stack of spec 7.10.2 for an intra frame, and assign_mv (5.11.26).

On an intra frame every inter candidate is an intrabc block (RefFrame = INTRA_FRAME, YMode = DC_PRED, no global motion,
force_integer_mv = 1, use_ref_frame_mvs = 0), so the temporal scan, the compound paths, the extra search (no candidate has
a reference above INTRA_FRAME) and the contexts reduce away; what is left is the spatial scans, weights, sort and clamp."""
from std.builtin.globals import global_constant
from imkit.av1state import (
    TileState, BLOCK_128X128, BLOCK_64X64, INTRA_FRAME, NUM_4X4_WIDE, NUM_4X4_HIGH, BLOCK_HEIGHT, BLOCK_WIDTH, MI_SIZE,
    INTRABC_DELAY_PIXELS, clip3,
)
from imkit.av1tile import read_mv_diff
from imkit.av1frame import Frame

comptime MV_BORDER = 128
comptime REF_CAT_LEVEL = 640
comptime MAX_REF_MV_STACK_SIZE = 8


struct MvStack(Movable):
    var rows: List[Int]
    var cols: List[Int]
    var weights: List[Int]
    var n: Int
    var found: Bool

    def __init__(out self):
        self.rows = List[Int](length=MAX_REF_MV_STACK_SIZE, fill=0)
        self.cols = List[Int](length=MAX_REF_MV_STACK_SIZE, fill=0)
        self.weights = List[Int](length=MAX_REF_MV_STACK_SIZE, fill=0)
        self.n = 0
        self.found = False


def lower_precision(v: Int) -> Int:
    """7.10.2.10 with force_integer_mv = 1."""
    var a_int = (abs(v) + 3) >> 3
    return a_int << 3 if v > 0 else -(a_int << 3)


def add_ref_mv_candidate(ts: TileState, mut s: MvStack, mv_row: Int, mv_col: Int, weight: Int):
    var idx = ts.at(mv_row, mv_col)
    if ts.is_inters[idx] == 0:
        return
    if ts.ref_frames[idx * 2] != INTRA_FRAME:
        return
    var r = lower_precision(ts.mvs[idx * 2])
    var c = lower_precision(ts.mvs[idx * 2 + 1])
    s.found = True
    for i in range(s.n):
        if s.rows[i] == r and s.cols[i] == c:
            s.weights[i] += weight
            return
    if s.n < MAX_REF_MV_STACK_SIZE:
        s.rows[s.n] = r
        s.cols[s.n] = c
        s.weights[s.n] = weight
        s.n += 1


def scan_row(ts: TileState, mut s: MvStack, delta_row0: Int):
    var bw4 = global_constant[NUM_4X4_WIDE]()[ts.mi_size]
    var end4 = min(min(bw4, ts.mi_cols - ts.mi_col), 16)
    var delta_row = delta_row0
    var delta_col = 0
    var use_step16 = bw4 >= 16
    if abs(delta_row) > 1:
        delta_row += ts.mi_row & 1
        delta_col = 1 - (ts.mi_col & 1)
    var i = 0
    while i < end4:
        var mv_row = ts.mi_row + delta_row
        var mv_col = ts.mi_col + delta_col + i
        if not ts.is_inside(mv_row, mv_col):
            break
        var ln = min(bw4, global_constant[NUM_4X4_WIDE]()[ts.mi_sizes[ts.at(mv_row, mv_col)]])
        if abs(delta_row) > 1:
            ln = max(2, ln)
        if use_step16:
            ln = max(4, ln)
        add_ref_mv_candidate(ts, s, mv_row, mv_col, ln * 2)
        i += ln


def scan_col(ts: TileState, mut s: MvStack, delta_col0: Int):
    var bh4 = global_constant[NUM_4X4_HIGH]()[ts.mi_size]
    var end4 = min(min(bh4, ts.mi_rows - ts.mi_row), 16)
    var delta_row = 0
    var delta_col = delta_col0
    var use_step16 = bh4 >= 16
    if abs(delta_col) > 1:
        delta_row = 1 - (ts.mi_row & 1)
        delta_col += ts.mi_col & 1
    var i = 0
    while i < end4:
        var mv_row = ts.mi_row + delta_row + i
        var mv_col = ts.mi_col + delta_col
        if not ts.is_inside(mv_row, mv_col):
            break
        var ln = min(bh4, global_constant[NUM_4X4_HIGH]()[ts.mi_sizes[ts.at(mv_row, mv_col)]])
        if abs(delta_col) > 1:
            ln = max(2, ln)
        if use_step16:
            ln = max(4, ln)
        add_ref_mv_candidate(ts, s, mv_row, mv_col, ln * 2)
        i += ln


def scan_point(ts: TileState, mut s: MvStack, delta_row: Int, delta_col: Int):
    var mv_row = ts.mi_row + delta_row
    var mv_col = ts.mi_col + delta_col
    # RefFrames[..][0] "has been written for this frame": the grid starts at -2 (TileState.__init__)
    if ts.is_inside(mv_row, mv_col) and ts.ref_frames[ts.at(mv_row, mv_col) * 2] != -2:
        add_ref_mv_candidate(ts, s, mv_row, mv_col, 4)


def sort_stack(mut s: MvStack, start: Int, end0: Int):
    var end = end0
    while end > start:
        var new_end = start
        for idx in range(start + 1, end):
            if s.weights[idx - 1] < s.weights[idx]:
                var w = s.weights[idx - 1]
                s.weights[idx - 1] = s.weights[idx]
                s.weights[idx] = w
                var r = s.rows[idx - 1]
                s.rows[idx - 1] = s.rows[idx]
                s.rows[idx] = r
                var c = s.cols[idx - 1]
                s.cols[idx - 1] = s.cols[idx]
                s.cols[idx] = c
                new_end = idx
        end = new_end


def find_mv_stack_intrabc(mut ts: TileState):
    """find_mv_stack(0); leaves RefStackMv[0..1][0] as (row, col) pairs in ts.ref_stack_mv."""
    var s = MvStack()
    var bw4 = global_constant[NUM_4X4_WIDE]()[ts.mi_size]
    var bh4 = global_constant[NUM_4X4_HIGH]()[ts.mi_size]
    scan_row(ts, s, -1)
    var found_above = s.found
    s.found = False
    scan_col(ts, s, -1)
    var found_left = s.found
    s.found = False
    if max(bw4, bh4) <= 16:
        scan_point(ts, s, -1, bw4)
    if s.found:
        found_above = True
    var num_nearest = s.n
    for idx in range(num_nearest):
        s.weights[idx] += REF_CAT_LEVEL
    scan_point(ts, s, -1, -1)
    if s.found:
        found_above = True
    s.found = False
    scan_row(ts, s, -3)
    s.found = False
    scan_col(ts, s, -3)
    s.found = False
    if bh4 > 1:
        scan_row(ts, s, -5)
    s.found = False
    if bw4 > 1:
        scan_col(ts, s, -5)
    sort_stack(s, 0, num_nearest)
    sort_stack(s, num_nearest, s.n)
    # extra search: no candidate on an intra frame has a reference above INTRA_FRAME, so only the global (zero) fill remains
    var bh = global_constant[BLOCK_HEIGHT]()[ts.mi_size]
    var bw = global_constant[BLOCK_WIDTH]()[ts.mi_size]
    for i in range(4):
        ts.ref_stack_mv[i] = 0
    for idx in range(min(s.n, 2)):
        var to_top = -((ts.mi_row * MI_SIZE) * 8)
        var to_bottom = ((ts.mi_rows - bh4 - ts.mi_row) * MI_SIZE) * 8
        var border_r = MV_BORDER + bh * 8
        ts.ref_stack_mv[idx * 2] = clip3(to_top - border_r, to_bottom + border_r, s.rows[idx])
        var to_left = -((ts.mi_col * MI_SIZE) * 8)
        var to_right = ((ts.mi_cols - bw4 - ts.mi_col) * MI_SIZE) * 8
        var border_c = MV_BORDER + bw * 8
        ts.ref_stack_mv[idx * 2 + 1] = clip3(to_left - border_c, to_right + border_c, s.cols[idx])
    ts.num_mv_found = s.n


def assign_mv_intrabc(mut ts: TileState) raises:
    var pr = ts.ref_stack_mv[0]
    var pc = ts.ref_stack_mv[1]
    if pr == 0 and pc == 0:
        pr = ts.ref_stack_mv[2]
        pc = ts.ref_stack_mv[3]
    if pr == 0 and pc == 0:
        var sb4 = global_constant[NUM_4X4_HIGH]()[BLOCK_128X128 if ts.seq.use_128x128_superblock else BLOCK_64X64]
        if ts.mi_row - sb4 < ts.mi_row_start:
            pr = 0
            pc = -(sb4 * MI_SIZE + INTRABC_DELAY_PIXELS) * 8
        else:
            pr = -(sb4 * MI_SIZE * 8)
            pc = 0
    var d = read_mv_diff(ts)
    ts.mv_row = pr + d[0]
    ts.mv_col = pc + d[1]


def round2s(x: Int, n: Int) -> Int:
    """Round2Signed(x, n)."""
    if x >= 0:
        return (x + (1 << (n - 1))) >> n
    return -((-x + (1 << (n - 1))) >> n)


def predict_intrabc(
    mut frame: Frame, plane: Int, x: Int, y: Int, w: Int, h: Int, mv_row: Int, mv_col: Int, mi_cols: Int, mi_rows: Int
) raises:
    """predict_inter for use_intrabc (7.11.3.1 steps 9 to 13, 7.11.3.3, 7.11.3.4): the reference is the frame being decoded,
    scale 1 << 14, BILINEAR in both directions (Subpel_Filters[3][p] is 128 - 8 p, 8 p at taps 3 and 4), one reference, so
    InterRound0 = 3, InterRound1 = 11 (5 and 9 at 12 bit) and the result is Clip1(pred). Source positions clamp to the plane,
    to MiCols * 4 by MiRows * 4 (the spec's RefUpscaledWidth[-1] / RefFrameHeight[-1]); the planes may be larger."""
    var sx = frame.sub_x if plane > 0 else 0
    var sy = frame.sub_y if plane > 0 else 0
    var round0 = 3
    var round1 = 11
    if frame.bit_depth == 12:
        round0 = 5
        round1 = 9
    var maxv = (1 << frame.bit_depth) - 1
    var pw = frame.planes[plane].w
    var ph = frame.planes[plane].h
    var last_x = ((mi_cols * 4 + sx) >> sx) - 1
    var last_y = ((mi_rows * 4 + sy) >> sy) - 1
    var orig_x = (x << 4) + ((2 * mv_col) >> sx) + 8
    var orig_y = (y << 4) + ((2 * mv_row) >> sy) + 8
    var base_x = orig_x * (1 << 14) - (8 << 14)
    var base_y = orig_y * (1 << 14) - (8 << 14)
    var start_x = round2s(base_x, 14 + 4 - 10) + 32
    var start_y = round2s(base_y, 14 + 4 - 10) + 32
    var step = 1 << 10
    var inter_h = (((h - 1) * step + (1 << 10) - 1) >> 10) + 8
    var inter = List[Int](length=inter_h * w, fill=0)
    for r in range(inter_h):
        var ry = clip3(0, last_y, (start_y >> 10) + r - 3)
        for c in range(w):
            var p = start_x + step * c
            var f = (p >> 6) & 15
            var px = p >> 10
            var s = (128 - 8 * f) * frame.planes[plane].get(clip3(0, last_x, px + 3 - 3), ry)
            s += 8 * f * frame.planes[plane].get(clip3(0, last_x, px + 4 - 3), ry)
            inter[r * w + c] = (s + (1 << (round0 - 1))) >> round0
    for r in range(h):
        var p = (start_y & 1023) + step * r
        var f = (p >> 6) & 15
        for c in range(w):
            var s = (128 - 8 * f) * inter[((p >> 10) + 3) * w + c] + 8 * f * inter[((p >> 10) + 4) * w + c]
            var v = clip3(0, maxv, (s + (1 << (round1 - 1))) >> round1)
            if x + c < pw and y + r < ph:
                frame.planes[plane].set(x + c, y + r, v)
