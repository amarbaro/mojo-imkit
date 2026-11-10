"""AV1 intra tile syntax: spec 5.11.2 to 5.11.28 and 5.11.57 (loop restoration units), CDF selection of 8.3.

`parse_frame` parses every tile of an intra frame into one `TileState` (frame-wide mode-info grids, block and transform
records for reconstruction); `parse_tiles` is the same with only per-tile statistics, for the stage 4 gate."""
from std.builtin.globals import global_constant
from std.collections import List
from imkit.av1obu import Av1Stream
from imkit.av1state import (
    TileState, TileStats, TxRec, BlockInfo, CdfBase,
    BLOCK_4X4, BLOCK_8X8, BLOCK_64X64, BLOCK_128X128, BLOCK_INVALID,
    PARTITION_NONE, PARTITION_HORZ, PARTITION_VERT, PARTITION_SPLIT, PARTITION_HORZ_A, PARTITION_HORZ_B,
    PARTITION_VERT_A, PARTITION_VERT_B, PARTITION_HORZ_4, PARTITION_VERT_4,
    TX_4X4, TX_MODE_SELECT, DC_PRED, V_PRED, UV_CFL_PRED, INTRA_MODES, INTRA_FRAME, NONE_FRAME, SEG_LVL_SKIP,
    RESTORE_NONE, RESTORE_WIENER, RESTORE_SGRPROJ, MAX_VARTX_DEPTH, FRAME_LF_COUNT, MAX_LOOP_FILTER, DELTA_Q_SMALL,
    DELTA_LF_SMALL, PALETTE_COLORS, PALETTE_NUM_NEIGHBORS, CFL_SIGN_ZERO, CFL_SIGN_NEG, CLASS0_SIZE,
    MV_INTRABC_CONTEXT, SUPERRES_NUM, SGRPROJ_PARAMS_BITS, SGRPROJ_PRJ_SUBEXP_K, SGRPROJ_PRJ_BITS, MI_SIZE,
    BLOCK_WIDTH, BLOCK_HEIGHT, MI_WIDTH_LOG2, MI_HEIGHT_LOG2, NUM_4X4_WIDE, NUM_4X4_HIGH, MAX_TX_SIZE_RECT,
    MAX_TX_DEPTH_TABLE, SPLIT_TX_SIZE, TX_WIDTH, TX_HEIGHT, TX_SIZE_SQR_UP, INTRA_MODE_CONTEXT,
    PALETTE_COLOR_HASH_MULTIPLIERS, PALETTE_COLOR_CONTEXT, WIENER_TAPS_MIN, WIENER_TAPS_MAX, WIENER_TAPS_K,
    SGRPROJ_XQD_MIN, SGRPROJ_XQD_MAX, BDSZ, PAD,
    partition_subsize, subsampled_size, is_directional_mode, find_tx_size, ceil_log2, clip3, zeros, fill_ints,
)
from imkit.av1coef import residual
from imkit.av1intrabc import find_mv_stack_intrabc, assign_mv_intrabc

comptime MV_JOINT_HNZVZ = 1
comptime MV_JOINT_HZVNZ = 2
comptime MV_JOINT_HNZVNZ = 3


def parse_frame(st: Av1Stream) raises -> TileState:
    var ts = TileState(st)
    for i in range(len(st.tile_offs)):
        if i > 0:
            ts.start_tile(st, i)
        decode_tile(ts)
        ts.sym.exit_process()
        if ts.stats.mi_covered != ts.stats.mi_total:
            raise Error("av1tile: tile " + String(i) + " covered " + String(ts.stats.mi_covered) + " of " + String(ts.stats.mi_total))
        ts.tile_stats.append(ts.stats.copy())
    return ts^


def parse_tiles(st: Av1Stream) raises -> List[TileStats]:
    var ts = parse_frame(st)
    return ts.tile_stats.copy()


def decode_tile(mut ts: TileState) raises:
    ts.clear_above_context()
    for i in range(FRAME_LF_COUNT):
        ts.delta_lf[i] = 0
    var sb_size = BLOCK_128X128 if ts.seq.use_128x128_superblock else BLOCK_64X64
    var sb4 = global_constant[NUM_4X4_WIDE]()[sb_size]
    for r in range(ts.mi_row_start, ts.mi_row_end, sb4):
        ts.clear_left_context()
        for c in range(ts.mi_col_start, ts.mi_col_end, sb4):
            ts.read_deltas = ts.frame.delta_q_present
            ts.clear_cdef(r, c)
            clear_block_decoded_flags(ts, r, c, sb4)
            read_lr(ts, r, c, sb_size)
            decode_partition(ts, r, c, sb_size)


def clear_block_decoded_flags(mut ts: TileState, r: Int, c: Int, sb4: Int):
    for plane in range(ts.num_planes):
        var sx = ts.sub_x if plane > 0 else 0
        var sy = ts.sub_y if plane > 0 else 0
        var sb_w4 = (ts.mi_col_end - c) >> sx
        var sb_h4 = (ts.mi_row_end - r) >> sy
        for y in range(-1, (sb4 >> sy) + 1):
            for x in range(-1, (sb4 >> sx) + 1):
                var v = False
                if y < 0 and x < sb_w4:
                    v = True
                elif x < 0 and y < sb_h4:
                    v = True
                ts.block_decoded[plane * BDSZ * BDSZ + (y + 1) * BDSZ + (x + 1)] = v
        ts.block_decoded[plane * BDSZ * BDSZ + ((sb4 >> sy) + 1) * BDSZ + 0] = False


# ---- partition ----
def partition_cdf(ts: TileState, bsl: Int, ctx: Int) -> Tuple[Int, Int]:
    """(pool offset of the row, symbol count) of the partition CDF for a block width log2 and context."""
    if bsl == 1:
        return (ts.cb.partition_w8 + ctx * 5, 4)
    if bsl == 2:
        return (ts.cb.partition_w16 + ctx * 11, 10)
    if bsl == 3:
        return (ts.cb.partition_w32 + ctx * 11, 10)
    if bsl == 4:
        return (ts.cb.partition_w64 + ctx * 11, 10)
    return (ts.cb.partition_w128 + ctx * 9, 8)


def read_split_or(mut ts: TileState, bsl: Int, ctx: Int, horz: Bool) raises -> Bool:
    """split_or_horz (horz) / split_or_vert: a bool built from the partition CDF (8.3.2). Rows are stored inverse, so the
    probability of symbol X is pool[X - 1] - pool[X]."""
    var pc = partition_cdf(ts, bsl, ctx)
    var off = pc[0]
    var ids = List[Int]()
    if horz:
        ids.append(PARTITION_VERT)
        ids.append(PARTITION_SPLIT)
        ids.append(PARTITION_HORZ_A)
        ids.append(PARTITION_VERT_A)
        ids.append(PARTITION_VERT_B)
        if bsl != 5:
            ids.append(PARTITION_VERT_4)
    else:
        ids.append(PARTITION_HORZ)
        ids.append(PARTITION_SPLIT)
        ids.append(PARTITION_HORZ_A)
        ids.append(PARTITION_HORZ_B)
        ids.append(PARTITION_VERT_A)
        if bsl != 5:
            ids.append(PARTITION_HORZ_4)
    var psum = 0
    for k in range(len(ids)):
        psum += Int(ts.pool[off + ids[k] - 1]) - Int(ts.pool[off + ids[k]])
    var c = List[UInt16]()
    c.append(UInt16(psum))
    c.append(UInt16(0))
    c.append(UInt16(0))
    return ts.sym.read_symbol(c, 2) == 1


def decode_partition(mut ts: TileState, r: Int, c: Int, bsize: Int) raises:
    if r >= ts.mi_rows or c >= ts.mi_cols:
        return
    var avail_u = ts.is_inside(r - 1, c)
    var avail_l = ts.is_inside(r, c - 1)
    var num4 = global_constant[NUM_4X4_WIDE]()[bsize]
    var half = num4 >> 1
    var quarter = half >> 1
    var has_rows = (r + half) < ts.mi_rows
    var has_cols = (c + half) < ts.mi_cols
    var partition = PARTITION_NONE
    if bsize < BLOCK_8X8:
        partition = PARTITION_NONE
    else:
        var bsl = global_constant[MI_WIDTH_LOG2]()[bsize]
        var above = avail_u and global_constant[MI_WIDTH_LOG2]()[ts.mi_sizes[ts.at(r - 1, c)]] < bsl
        var left = avail_l and global_constant[MI_HEIGHT_LOG2]()[ts.mi_sizes[ts.at(r, c - 1)]] < bsl
        var ctx = (2 if left else 0) + (1 if above else 0)
        if has_rows and has_cols:
            var pc = partition_cdf(ts, bsl, ctx)
            partition = ts.rd(pc[0], pc[1])
        elif has_cols:
            partition = PARTITION_SPLIT if read_split_or(ts, bsl, ctx, True) else PARTITION_HORZ
        elif has_rows:
            partition = PARTITION_SPLIT if read_split_or(ts, bsl, ctx, False) else PARTITION_VERT
        else:
            partition = PARTITION_SPLIT
    var sub_size = partition_subsize(partition, bsize)
    var split_size = partition_subsize(PARTITION_SPLIT, bsize)
    if sub_size == BLOCK_INVALID:
        raise Error("av1tile: partition " + String(partition) + " invalid for block " + String(bsize))
    if partition == PARTITION_NONE:
        decode_block(ts, r, c, sub_size)
    elif partition == PARTITION_HORZ:
        decode_block(ts, r, c, sub_size)
        if has_rows:
            decode_block(ts, r + half, c, sub_size)
    elif partition == PARTITION_VERT:
        decode_block(ts, r, c, sub_size)
        if has_cols:
            decode_block(ts, r, c + half, sub_size)
    elif partition == PARTITION_SPLIT:
        decode_partition(ts, r, c, sub_size)
        decode_partition(ts, r, c + half, sub_size)
        decode_partition(ts, r + half, c, sub_size)
        decode_partition(ts, r + half, c + half, sub_size)
    elif partition == PARTITION_HORZ_A:
        decode_block(ts, r, c, split_size)
        decode_block(ts, r, c + half, split_size)
        decode_block(ts, r + half, c, sub_size)
    elif partition == PARTITION_HORZ_B:
        decode_block(ts, r, c, sub_size)
        decode_block(ts, r + half, c, split_size)
        decode_block(ts, r + half, c + half, split_size)
    elif partition == PARTITION_VERT_A:
        decode_block(ts, r, c, split_size)
        decode_block(ts, r + half, c, split_size)
        decode_block(ts, r, c + half, sub_size)
    elif partition == PARTITION_VERT_B:
        decode_block(ts, r, c, sub_size)
        decode_block(ts, r, c + half, split_size)
        decode_block(ts, r + half, c + half, split_size)
    elif partition == PARTITION_HORZ_4:
        decode_block(ts, r, c, sub_size)
        decode_block(ts, r + quarter, c, sub_size)
        decode_block(ts, r + quarter * 2, c, sub_size)
        if r + quarter * 3 < ts.mi_rows:
            decode_block(ts, r + quarter * 3, c, sub_size)
    else:
        decode_block(ts, r, c, sub_size)
        decode_block(ts, r, c + quarter, sub_size)
        decode_block(ts, r, c + quarter * 2, sub_size)
        if c + quarter * 3 < ts.mi_cols:
            decode_block(ts, r, c + quarter * 3, sub_size)


# ---- block ----
def decode_block(mut ts: TileState, r: Int, c: Int, bsize: Int) raises:
    ts.mi_row = r
    ts.mi_col = c
    ts.mi_size = bsize
    var bw4 = global_constant[NUM_4X4_WIDE]()[bsize]
    var bh4 = global_constant[NUM_4X4_HIGH]()[bsize]
    if bh4 == 1 and ts.sub_y == 1 and (r & 1) == 0:
        ts.has_chroma = False
    elif bw4 == 1 and ts.sub_x == 1 and (c & 1) == 0:
        ts.has_chroma = False
    else:
        ts.has_chroma = ts.num_planes > 1
    ts.avail_u = ts.is_inside(r - 1, c)
    ts.avail_l = ts.is_inside(r, c - 1)
    ts.avail_u_chroma = ts.avail_u
    ts.avail_l_chroma = ts.avail_l
    if ts.has_chroma:
        if ts.sub_y == 1 and bh4 == 1:
            ts.avail_u_chroma = ts.is_inside(r - 2, c)
        if ts.sub_x == 1 and bw4 == 1:
            ts.avail_l_chroma = ts.is_inside(r, c - 2)
    else:
        ts.avail_u_chroma = False
        ts.avail_l_chroma = False
    intra_frame_mode_info(ts)
    palette_tokens(ts)
    read_block_tx_size(ts)
    if ts.skip:
        reset_block_context(ts, bw4, bh4)
    for y in range(bh4):
        for x in range(bw4):
            var idx = ts.at(r + y, c + x)
            ts.y_modes[idx] = ts.y_mode
            if ts.has_chroma:
                ts.uv_modes[idx] = ts.uv_mode
            ts.ref_frames[idx * 2] = INTRA_FRAME
            ts.ref_frames[idx * 2 + 1] = NONE_FRAME
            if ts.is_inter:
                ts.mvs[idx * 2] = ts.mv_row
                ts.mvs[idx * 2 + 1] = ts.mv_col
    var info = BlockInfo()
    info.tx_first = len(ts.txs)
    residual(ts)
    info.tx_end = len(ts.txs)
    var total = ts.stride * (ts.mi_rows + PAD)
    for y in range(bh4):
        for x in range(bw4):
            var idx = ts.at(r + y, c + x)
            ts.is_inters[idx] = 1 if ts.is_inter else 0
            ts.skip_modes[idx] = 0
            ts.skips[idx] = 1 if ts.skip else 0
            ts.tx_sizes[idx] = ts.tx_size
            ts.mi_sizes[idx] = ts.mi_size
            ts.segment_ids[idx] = ts.segment_id
            ts.palette_sizes[idx] = ts.palette_size_y
            ts.palette_sizes[total + idx] = ts.palette_size_uv
            for i in range(ts.palette_size_y):
                ts.palette_colors[idx * 8 + i] = UInt16(ts.palette_colors_y[i])
            for i in range(ts.palette_size_uv):
                ts.palette_colors[(total + idx) * 8 + i] = UInt16(ts.palette_colors_u[i])
            for i in range(FRAME_LF_COUNT):
                ts.delta_lfs[idx * FRAME_LF_COUNT + i] = ts.delta_lf[i]
    info.mi_row = r
    info.mi_col = c
    info.mi_size = bsize
    info.has_chroma = ts.has_chroma
    info.avail_u = ts.avail_u
    info.avail_l = ts.avail_l
    info.avail_u_chroma = ts.avail_u_chroma
    info.avail_l_chroma = ts.avail_l_chroma
    info.segment_id = ts.segment_id
    info.skip = ts.skip
    info.lossless = ts.lossless
    info.current_qindex = ts.current_qindex
    info.is_inter = ts.is_inter
    info.use_intrabc = ts.use_intrabc
    info.mv_row = ts.mv_row
    info.mv_col = ts.mv_col
    info.y_mode = ts.y_mode
    info.uv_mode = ts.uv_mode
    info.angle_delta_y = ts.angle_delta_y
    info.angle_delta_uv = ts.angle_delta_uv
    info.cfl_alpha_u = ts.cfl_alpha_u
    info.cfl_alpha_v = ts.cfl_alpha_v
    info.use_filter_intra = ts.use_filter_intra
    info.filter_intra_mode = ts.filter_intra_mode
    info.palette_size_y = ts.palette_size_y
    info.palette_size_uv = ts.palette_size_uv
    info.palette_y = ts.palette_colors_y.copy()
    info.palette_u = ts.palette_colors_u.copy()
    info.palette_v = ts.palette_colors_v.copy()
    info.map_y_off = ts.map_y_off
    info.map_uv_off = ts.map_uv_off
    info.map_uv_stride = ts.map_uv_stride
    info.tx_size = ts.tx_size
    ts.blocks.append(info^)
    ts.stats.blocks += 1
    ts.stats.mi_covered += min(bw4, ts.mi_col_end - c) * min(bh4, ts.mi_row_end - r)
    if ts.skip:
        ts.stats.skip += 1
    if ts.segment_id > 0:
        ts.stats.segmented += 1
    if ts.use_intrabc:
        ts.stats.intrabc += 1
    if ts.palette_size_y > 0 or ts.palette_size_uv > 0:
        ts.stats.palette += 1
    if ts.has_chroma and not ts.use_intrabc and ts.uv_mode == UV_CFL_PRED:
        ts.stats.cfl += 1
    if ts.use_filter_intra:
        ts.stats.filter_intra += 1


def reset_block_context(mut ts: TileState, bw4: Int, bh4: Int):
    for plane in range(1 + (2 if ts.has_chroma else 0)):
        var sx = ts.sub_x if plane > 0 else 0
        var sy = ts.sub_y if plane > 0 else 0
        for i in range(ts.mi_col >> sx, (ts.mi_col + bw4) >> sx):
            ts.above_level[plane * ts.stride + i] = 0
            ts.above_dc[plane * ts.stride + i] = 0
        for i in range(ts.mi_row >> sy, (ts.mi_row + bh4) >> sy):
            ts.left_level[plane * (ts.mi_rows + PAD) + i] = 0
            ts.left_dc[plane * (ts.mi_rows + PAD) + i] = 0


def intra_frame_mode_info(mut ts: TileState) raises:
    ts.skip = False
    ts.palette_size_y = 0
    ts.palette_size_uv = 0
    ts.palette_colors_y = List[Int]()
    ts.palette_colors_u = List[Int]()
    ts.palette_colors_v = List[Int]()
    ts.use_filter_intra = False
    ts.filter_intra_mode = 0
    ts.cfl_alpha_u = 0
    ts.cfl_alpha_v = 0
    ts.angle_delta_y = 0
    ts.angle_delta_uv = 0
    ts.mv_row = 0
    ts.mv_col = 0
    if ts.seg_id_pre_skip:
        intra_segment_id(ts)
    read_skip(ts)
    if not ts.seg_id_pre_skip:
        intra_segment_id(ts)
    read_cdef(ts)
    read_delta_qindex(ts)
    read_delta_lf(ts)
    ts.read_deltas = False
    ts.use_intrabc = False
    if ts.frame.allow_intrabc:
        ts.use_intrabc = ts.rd(ts.cb.intrabc, 2) == 1
    if ts.use_intrabc:
        ts.is_inter = True
        ts.y_mode = DC_PRED
        ts.uv_mode = DC_PRED
        find_mv_stack_intrabc(ts)
        assign_mv_intrabc(ts)
        return
    ts.is_inter = False
    var above_mode = global_constant[INTRA_MODE_CONTEXT]()[ts.y_modes[ts.at(ts.mi_row - 1, ts.mi_col)] if ts.avail_u else DC_PRED]
    var left_mode = global_constant[INTRA_MODE_CONTEXT]()[ts.y_modes[ts.at(ts.mi_row, ts.mi_col - 1)] if ts.avail_l else DC_PRED]
    ts.y_mode = ts.rd(ts.cb.intra_frame_y_mode + (above_mode * 5 + left_mode) * 14, 13)
    intra_angle_info_y(ts)
    ts.uv_mode = DC_PRED
    if ts.has_chroma:
        var cfl_allowed: Bool
        if ts.lossless and subsampled_size(ts.mi_size, ts.sub_x, ts.sub_y) == BLOCK_4X4:
            cfl_allowed = True
        elif not ts.lossless and max(global_constant[BLOCK_WIDTH]()[ts.mi_size], global_constant[BLOCK_HEIGHT]()[ts.mi_size]) <= 32:
            cfl_allowed = True
        else:
            cfl_allowed = False
        if cfl_allowed:
            ts.uv_mode = ts.rd(ts.cb.uv_mode_cfl_allowed + ts.y_mode * 15, 14)
        else:
            ts.uv_mode = ts.rd(ts.cb.uv_mode_cfl_not_allowed + ts.y_mode * 14, 13)
        if ts.uv_mode == UV_CFL_PRED:
            read_cfl_alphas(ts)
        intra_angle_info_uv(ts)
    if (
        ts.mi_size >= BLOCK_8X8 and global_constant[BLOCK_WIDTH]()[ts.mi_size] <= 64 and global_constant[BLOCK_HEIGHT]()[ts.mi_size] <= 64
        and ts.frame.allow_screen_content_tools
    ):
        palette_mode_info(ts)
    filter_intra_mode_info(ts)


def filter_intra_mode_info(mut ts: TileState) raises:
    ts.use_filter_intra = False
    if (
        ts.seq.enable_filter_intra and ts.y_mode == DC_PRED and ts.palette_size_y == 0
        and max(global_constant[BLOCK_WIDTH]()[ts.mi_size], global_constant[BLOCK_HEIGHT]()[ts.mi_size]) <= 32
    ):
        ts.use_filter_intra = ts.rd(ts.cb.filter_intra + ts.mi_size * 3, 2) == 1
        if ts.use_filter_intra:
            ts.filter_intra_mode = ts.rd(ts.cb.filter_intra_mode, 5)


def intra_segment_id(mut ts: TileState) raises:
    if ts.frame.segmentation_enabled:
        read_segment_id(ts)
    else:
        ts.segment_id = 0
    ts.lossless = ts.lossless_arr[ts.segment_id]


def read_segment_id(mut ts: TileState) raises:
    var prev_ul = -1
    var prev_u = -1
    var prev_l = -1
    if ts.avail_u and ts.avail_l:
        prev_ul = ts.segment_ids[ts.at(ts.mi_row - 1, ts.mi_col - 1)]
    if ts.avail_u:
        prev_u = ts.segment_ids[ts.at(ts.mi_row - 1, ts.mi_col)]
    if ts.avail_l:
        prev_l = ts.segment_ids[ts.at(ts.mi_row, ts.mi_col - 1)]
    var pred: Int
    if prev_u == -1:
        pred = 0 if prev_l == -1 else prev_l
    elif prev_l == -1:
        pred = prev_u
    else:
        pred = prev_u if prev_ul == prev_u else prev_l
    if ts.skip:
        ts.segment_id = pred
        return
    var ctx = 0
    if prev_ul < 0:
        ctx = 0
    elif prev_ul == prev_u and prev_ul == prev_l:
        ctx = 2
    elif prev_ul == prev_u or prev_ul == prev_l or prev_u == prev_l:
        ctx = 1
    var s = ts.rd(ts.cb.segment_id + ctx * 9, 8)
    ts.segment_id = clip3(0, ts.last_active_seg_id, neg_deinterleave(s, pred, ts.last_active_seg_id + 1))


def neg_deinterleave(diff: Int, rf: Int, maximum: Int) -> Int:
    if rf == 0:
        return diff
    if rf >= maximum - 1:
        return maximum - diff - 1
    if 2 * rf < maximum:
        if diff <= 2 * rf:
            if (diff & 1) == 1:
                return rf + ((diff + 1) >> 1)
            return rf - (diff >> 1)
        return diff
    if diff <= 2 * (maximum - rf - 1):
        if (diff & 1) == 1:
            return rf + ((diff + 1) >> 1)
        return rf - (diff >> 1)
    return maximum - (diff + 1)


def read_skip(mut ts: TileState) raises:
    if ts.seg_id_pre_skip and ts.seg_feature_active(SEG_LVL_SKIP):
        ts.skip = True
        return
    var ctx = 0
    if ts.avail_u:
        ctx += ts.skips[ts.at(ts.mi_row - 1, ts.mi_col)]
    if ts.avail_l:
        ctx += ts.skips[ts.at(ts.mi_row, ts.mi_col - 1)]
    ts.skip = ts.rd(ts.cb.skip + ctx * 3, 2) == 1


def read_cdef(mut ts: TileState) raises:
    if ts.skip or ts.coded_lossless or not ts.seq.enable_cdef or ts.frame.allow_intrabc:
        return
    var r = ts.mi_row & ~15
    var c = ts.mi_col & ~15
    if ts.cdef_idx[ts.at(r, c)] == -1:
        var v = ts.lit(ts.frame.cdef_bits)
        ts.cdef_idx[ts.at(r, c)] = v
        var w4 = global_constant[NUM_4X4_WIDE]()[ts.mi_size]
        var h4 = global_constant[NUM_4X4_HIGH]()[ts.mi_size]
        for i in range(r, r + h4, 16):
            for j in range(c, c + w4, 16):
                ts.cdef_idx[ts.at(i, j)] = v


def read_delta_value(mut ts: TileState, off: Int, small: Int) raises -> Int:
    """delta_q_abs / delta_lf_abs with the escape code; the sign is read when nonzero. Returns the signed value."""
    var a = ts.rd(off, 4)
    if a == small:
        var n = ts.lit(3) + 1
        a = ts.lit(n) + (1 << n) + 1
    if a != 0:
        if ts.lit(1) == 1:
            return -a
    return a


def read_delta_qindex(mut ts: TileState) raises:
    var sb = BLOCK_128X128 if ts.seq.use_128x128_superblock else BLOCK_64X64
    if ts.mi_size == sb and ts.skip:
        return
    if ts.read_deltas:
        var d = read_delta_value(ts, ts.cb.delta_q, DELTA_Q_SMALL)
        if d != 0:
            ts.current_qindex = clip3(1, 255, ts.current_qindex + (d << ts.frame.delta_q_res))


def read_delta_lf(mut ts: TileState) raises:
    var sb = BLOCK_128X128 if ts.seq.use_128x128_superblock else BLOCK_64X64
    if ts.mi_size == sb and ts.skip:
        return
    if ts.read_deltas and ts.frame.delta_lf_present:
        var count = 1
        if ts.frame.delta_lf_multi:
            count = FRAME_LF_COUNT if ts.num_planes > 1 else FRAME_LF_COUNT - 2
        for i in range(count):
            var off = ts.cb.delta_lf_multi + i * 5 if ts.frame.delta_lf_multi else ts.cb.delta_lf
            var d = read_delta_value(ts, off, DELTA_LF_SMALL)
            if d != 0:
                ts.delta_lf[i] = clip3(-MAX_LOOP_FILTER, MAX_LOOP_FILTER, ts.delta_lf[i] + (d << ts.frame.delta_lf_res))


def intra_angle_info_y(mut ts: TileState) raises:
    ts.angle_delta_y = 0
    if ts.mi_size >= BLOCK_8X8 and is_directional_mode(ts.y_mode):
        ts.angle_delta_y = ts.rd(ts.cb.angle_delta + (ts.y_mode - V_PRED) * 8, 7) - 3


def intra_angle_info_uv(mut ts: TileState) raises:
    ts.angle_delta_uv = 0
    if ts.mi_size >= BLOCK_8X8 and is_directional_mode(ts.uv_mode):
        ts.angle_delta_uv = ts.rd(ts.cb.angle_delta + (ts.uv_mode - V_PRED) * 8, 7) - 3


def read_cfl_alphas(mut ts: TileState) raises:
    var signs = ts.rd(ts.cb.cfl_sign, 8)
    var sign_u = (signs + 1) // 3
    var sign_v = (signs + 1) % 3
    ts.cfl_alpha_u = 0
    ts.cfl_alpha_v = 0
    if sign_u != CFL_SIGN_ZERO:
        ts.cfl_alpha_u = 1 + ts.rd(ts.cb.cfl_alpha + ((sign_u - 1) * 3 + sign_v) * 17, 16)
        if sign_u == CFL_SIGN_NEG:
            ts.cfl_alpha_u = -ts.cfl_alpha_u
    if sign_v != CFL_SIGN_ZERO:
        ts.cfl_alpha_v = 1 + ts.rd(ts.cb.cfl_alpha + ((sign_v - 1) * 3 + sign_u) * 17, 16)
        if sign_v == CFL_SIGN_NEG:
            ts.cfl_alpha_v = -ts.cfl_alpha_v


# ---- palette ----
def read_palette_colors(mut ts: TileState, size: Int, plane: Int) raises -> List[Int]:
    """The y (plane 0) or u (plane 1) half of palette_mode_info."""
    var colors = List[Int]()
    var cache = get_palette_cache(ts, plane)
    var bd = ts.seq.bit_depth
    var i = 0
    while i < len(cache) and len(colors) < size:
        if ts.lit(1) == 1:
            colors.append(cache[i])
        i += 1
    if len(colors) < size:
        colors.append(ts.lit(bd))
    var palette_bits = 0
    if len(colors) < size:
        palette_bits = bd - 3 + ts.lit(2)
    while len(colors) < size:
        var delta = ts.lit(palette_bits)
        if plane == 0:
            delta += 1
        var v = clip3(0, (1 << bd) - 1, colors[len(colors) - 1] + delta)
        colors.append(v)
        var rng = (1 << bd) - v - (1 if plane == 0 else 0)
        palette_bits = min(palette_bits, ceil_log2(rng))
    sort_ints(colors)
    return colors^


def palette_mode_info(mut ts: TileState) raises:
    var bsize_ctx = global_constant[MI_WIDTH_LOG2]()[ts.mi_size] + global_constant[MI_HEIGHT_LOG2]()[ts.mi_size] - 2
    var bd = ts.seq.bit_depth
    var total = ts.stride * (ts.mi_rows + PAD)
    if ts.y_mode == DC_PRED:
        var ctx = 0
        if ts.avail_u and ts.palette_sizes[ts.at(ts.mi_row - 1, ts.mi_col)] > 0:
            ctx += 1
        if ts.avail_l and ts.palette_sizes[ts.at(ts.mi_row, ts.mi_col - 1)] > 0:
            ctx += 1
        if ts.rd(ts.cb.palette_y_mode + (bsize_ctx * 3 + ctx) * 3, 2) == 1:
            ts.palette_size_y = ts.rd(ts.cb.palette_y_size + bsize_ctx * 8, 7) + 2
            ts.palette_colors_y = read_palette_colors(ts, ts.palette_size_y, 0)
    if ts.has_chroma and ts.uv_mode == DC_PRED:
        var ctx = 1 if ts.palette_size_y > 0 else 0
        if ts.rd(ts.cb.palette_uv_mode + ctx * 3, 2) == 1:
            ts.palette_size_uv = ts.rd(ts.cb.palette_uv_size + bsize_ctx * 8, 7) + 2
            ts.palette_colors_u = read_palette_colors(ts, ts.palette_size_uv, 1)
            ts.palette_colors_v = List[Int]()
            if ts.lit(1) == 1:
                var palette_bits = bd - 4 + ts.lit(2)
                var max_val = 1 << bd
                ts.palette_colors_v.append(ts.lit(bd))
                for idx in range(1, ts.palette_size_uv):
                    var delta = ts.lit(palette_bits)
                    if delta != 0 and ts.lit(1) == 1:
                        delta = -delta
                    var val = ts.palette_colors_v[idx - 1] + delta
                    if val < 0:
                        val += max_val
                    if val >= max_val:
                        val -= max_val
                    ts.palette_colors_v.append(clip3(0, max_val - 1, val))
            else:
                for _ in range(ts.palette_size_uv):
                    ts.palette_colors_v.append(ts.lit(bd))


def get_palette_cache(ts: TileState, plane: Int) -> List[Int]:
    var total = ts.stride * (ts.mi_rows + PAD)
    var above_n = 0
    var ai = ts.at(ts.mi_row - 1, ts.mi_col)
    var li = ts.at(ts.mi_row, ts.mi_col - 1)
    if ((ts.mi_row * MI_SIZE) % 64) != 0:
        above_n = ts.palette_sizes[plane * total + ai]
    var left_n = 0
    if ts.avail_l:
        left_n = ts.palette_sizes[plane * total + li]
    var a = 0
    var l = 0
    var cache = List[Int]()
    while a < above_n and l < left_n:
        var above_c = Int(ts.palette_colors[(plane * total + ai) * 8 + a])
        var left_c = Int(ts.palette_colors[(plane * total + li) * 8 + l])
        if left_c < above_c:
            if len(cache) == 0 or left_c != cache[len(cache) - 1]:
                cache.append(left_c)
            l += 1
        else:
            if len(cache) == 0 or above_c != cache[len(cache) - 1]:
                cache.append(above_c)
            a += 1
            if left_c == above_c:
                l += 1
    while a < above_n:
        var v = Int(ts.palette_colors[(plane * total + ai) * 8 + a])
        a += 1
        if len(cache) == 0 or v != cache[len(cache) - 1]:
            cache.append(v)
    while l < left_n:
        var v = Int(ts.palette_colors[(plane * total + li) * 8 + l])
        l += 1
        if len(cache) == 0 or v != cache[len(cache) - 1]:
            cache.append(v)
    return cache^


def sort_ints(mut a: List[Int]):
    for i in range(1, len(a)):
        var v = a[i]
        var j = i - 1
        while j >= 0 and a[j] > v:
            a[j + 1] = a[j]
            j -= 1
        a[j + 1] = v


def read_ns(mut ts: TileState, n: Int) raises -> Int:
    """NS(n) coded with literal bits (4.10.10)."""
    var w = 0
    while (1 << (w + 1)) <= n:
        w += 1
    w += 1
    var m = (1 << w) - n
    var v = ts.lit(w - 1)
    if v < m:
        return v
    return (v << 1) - m + ts.lit(1)


def read_color_map(mut ts: TileState, size: Int, uv: Bool, bw0: Int, bh0: Int, on_w0: Int, on_h0: Int) raises -> List[UInt8]:
    """One ColorMap of palette_tokens: its first index, the wavefront of palette_color_idx symbols, then the edge fill."""
    var bw = bw0
    var bh = bh0
    var on_w = on_w0
    var on_h = on_h0
    var first = read_ns(ts, size)
    if uv:
        bw = bw >> ts.sub_x
        bh = bh >> ts.sub_y
        on_w = on_w >> ts.sub_x
        on_h = on_h >> ts.sub_y
        if bw < 4:
            bw += 2
            on_w += 2
        if bh < 4:
            bh += 2
            on_h += 2
    var m = List[UInt8](length=bw * bh, fill=0)
    m[0] = UInt8(first)
    var base = ts.cb.palette_uv_color[size] if uv else ts.cb.palette_y_color[size]
    for i in range(1, on_h + on_w - 1):
        var j = min(i, on_w - 1)
        while j >= max(0, i - on_h + 1):
            var rr = i - j
            var scores = List[Int](length=PALETTE_COLORS, fill=0)
            var order = List[Int](length=PALETTE_COLORS, fill=0)
            for k in range(PALETTE_COLORS):
                order[k] = k
            if j > 0:
                scores[Int(m[rr * bw + j - 1])] += 2
            if rr > 0 and j > 0:
                scores[Int(m[(rr - 1) * bw + j - 1])] += 1
            if rr > 0:
                scores[Int(m[(rr - 1) * bw + j])] += 2
            for k in range(PALETTE_NUM_NEIGHBORS):
                var max_score = scores[k]
                var max_idx = k
                for q in range(k + 1, size):
                    if scores[q] > max_score:
                        max_score = scores[q]
                        max_idx = q
                if max_idx != k:
                    var max_order = order[max_idx]
                    for q in range(max_idx, k, -1):
                        scores[q] = scores[q - 1]
                        order[q] = order[q - 1]
                    scores[k] = max_score
                    order[k] = max_order
            var hash = 0
            for k in range(PALETTE_NUM_NEIGHBORS):
                hash += scores[k] * global_constant[PALETTE_COLOR_HASH_MULTIPLIERS]()[k]
            var ctx = global_constant[PALETTE_COLOR_CONTEXT]()[hash]
            var idx = ts.rd(base + ctx * (size + 1), size)
            m[rr * bw + j] = UInt8(order[idx])
            j -= 1
    for i in range(on_h):
        for j in range(on_w, bw):
            m[i * bw + j] = m[i * bw + on_w - 1]
    for i in range(on_h, bh):
        for j in range(bw):
            m[i * bw + j] = m[(on_h - 1) * bw + j]
    ts.map_uv_stride = bw if uv else ts.map_uv_stride
    return m^


def palette_tokens(mut ts: TileState) raises:
    ts.map_y_off = -1
    ts.map_uv_off = -1
    var bh = global_constant[BLOCK_HEIGHT]()[ts.mi_size]
    var bw = global_constant[BLOCK_WIDTH]()[ts.mi_size]
    var on_h = min(bh, (ts.mi_rows - ts.mi_row) * MI_SIZE)
    var on_w = min(bw, (ts.mi_cols - ts.mi_col) * MI_SIZE)
    if ts.palette_size_y > 0:
        var m = read_color_map(ts, ts.palette_size_y, False, bw, bh, on_w, on_h)
        ts.map_y_off = len(ts.color_maps)
        for i in range(len(m)):
            ts.color_maps.append(m[i])
    if ts.palette_size_uv > 0:
        var m = read_color_map(ts, ts.palette_size_uv, True, bw, bh, on_w, on_h)
        ts.map_uv_off = len(ts.color_maps)
        for i in range(len(m)):
            ts.color_maps.append(m[i])


# ---- transform size ----
def get_above_tx_width(ts: TileState, row: Int, col: Int) -> Int:
    if row == ts.mi_row:
        if not ts.avail_u:
            return 64
        if ts.skips[ts.at(row - 1, col)] == 1 and ts.is_inters[ts.at(row - 1, col)] == 1:
            return global_constant[BLOCK_WIDTH]()[ts.mi_sizes[ts.at(row - 1, col)]]
    return global_constant[TX_WIDTH]()[ts.inter_tx_sizes[ts.at(row - 1, col)]]


def get_left_tx_height(ts: TileState, row: Int, col: Int) -> Int:
    if col == ts.mi_col:
        if not ts.avail_l:
            return 64
        if ts.skips[ts.at(row, col - 1)] == 1 and ts.is_inters[ts.at(row, col - 1)] == 1:
            return global_constant[BLOCK_HEIGHT]()[ts.mi_sizes[ts.at(row, col - 1)]]
    return global_constant[TX_HEIGHT]()[ts.inter_tx_sizes[ts.at(row, col - 1)]]


def read_tx_size(mut ts: TileState, allow_select: Bool) raises:
    if ts.lossless:
        ts.tx_size = TX_4X4
        return
    var max_rect = global_constant[MAX_TX_SIZE_RECT]()[ts.mi_size]
    var max_depth = global_constant[MAX_TX_DEPTH_TABLE]()[ts.mi_size]
    ts.tx_size = max_rect
    if ts.mi_size > BLOCK_4X4 and allow_select and ts.tx_mode == TX_MODE_SELECT:
        var above_w = 0
        if ts.avail_u:
            var ai = ts.at(ts.mi_row - 1, ts.mi_col)
            above_w = global_constant[BLOCK_WIDTH]()[ts.mi_sizes[ai]] if ts.is_inters[ai] == 1 else get_above_tx_width(ts, ts.mi_row, ts.mi_col)
        var left_h = 0
        if ts.avail_l:
            var li = ts.at(ts.mi_row, ts.mi_col - 1)
            left_h = global_constant[BLOCK_HEIGHT]()[ts.mi_sizes[li]] if ts.is_inters[li] == 1 else get_left_tx_height(ts, ts.mi_row, ts.mi_col)
        var ctx = (1 if above_w >= global_constant[TX_WIDTH]()[max_rect] else 0) + (1 if left_h >= global_constant[TX_HEIGHT]()[max_rect] else 0)
        var depth: Int
        if max_depth == 4:
            depth = ts.rd(ts.cb.tx_64x64 + ctx * 4, 3)
        elif max_depth == 3:
            depth = ts.rd(ts.cb.tx_32x32 + ctx * 4, 3)
        elif max_depth == 2:
            depth = ts.rd(ts.cb.tx_16x16 + ctx * 4, 3)
        else:
            depth = ts.rd(ts.cb.tx_8x8 + ctx * 3, 2)
        for _ in range(depth):
            ts.tx_size = global_constant[SPLIT_TX_SIZE]()[ts.tx_size]


def read_var_tx_size(mut ts: TileState, row: Int, col: Int, tx_sz: Int, depth: Int) raises:
    if row >= ts.mi_rows or col >= ts.mi_cols:
        return
    var split = False
    if tx_sz != TX_4X4 and depth != MAX_VARTX_DEPTH:
        var above = 1 if get_above_tx_width(ts, row, col) < global_constant[TX_WIDTH]()[tx_sz] else 0
        var left = 1 if get_left_tx_height(ts, row, col) < global_constant[TX_HEIGHT]()[tx_sz] else 0
        var size = min(64, max(global_constant[BLOCK_WIDTH]()[ts.mi_size], global_constant[BLOCK_HEIGHT]()[ts.mi_size]))
        var max_tx = find_tx_size(size, size)
        var ctx = (3 if global_constant[TX_SIZE_SQR_UP]()[tx_sz] != max_tx else 0) + (5 - 1 - max_tx) * 6 + above + left
        split = ts.rd(ts.cb.txfm_split + ctx * 3, 2) == 1
    var w4 = global_constant[TX_WIDTH]()[tx_sz] // MI_SIZE
    var h4 = global_constant[TX_HEIGHT]()[tx_sz] // MI_SIZE
    if split:
        ts.stats.vartx_split += 1
        var sub = global_constant[SPLIT_TX_SIZE]()[tx_sz]
        var step_w = global_constant[TX_WIDTH]()[sub] // MI_SIZE
        var step_h = global_constant[TX_HEIGHT]()[sub] // MI_SIZE
        for i in range(0, h4, step_h):
            for j in range(0, w4, step_w):
                read_var_tx_size(ts, row + i, col + j, sub, depth + 1)
    else:
        for i in range(h4):
            for j in range(w4):
                ts.inter_tx_sizes[ts.at(row + i, col + j)] = tx_sz
        ts.tx_size = tx_sz


def read_block_tx_size(mut ts: TileState) raises:
    var bw4 = global_constant[NUM_4X4_WIDE]()[ts.mi_size]
    var bh4 = global_constant[NUM_4X4_HIGH]()[ts.mi_size]
    if ts.tx_mode == TX_MODE_SELECT and ts.mi_size > BLOCK_4X4 and ts.is_inter and not ts.skip and not ts.lossless:
        var max_tx = global_constant[MAX_TX_SIZE_RECT]()[ts.mi_size]
        var tx_w4 = global_constant[TX_WIDTH]()[max_tx] // MI_SIZE
        var tx_h4 = global_constant[TX_HEIGHT]()[max_tx] // MI_SIZE
        for row in range(ts.mi_row, ts.mi_row + bh4, tx_h4):
            for col in range(ts.mi_col, ts.mi_col + bw4, tx_w4):
                read_var_tx_size(ts, row, col, max_tx, 0)
    else:
        read_tx_size(ts, (not ts.skip) or (not ts.is_inter))
        for row in range(ts.mi_row, ts.mi_row + bh4):
            for col in range(ts.mi_col, ts.mi_col + bw4):
                ts.inter_tx_sizes[ts.at(row, col)] = ts.tx_size


# ---- motion vector (intrabc only: force_integer_mv = 1, allow_high_precision_mv = 0 on intra frames) ----
def read_mv_component(mut ts: TileState, ctx: Int, comp: Int) raises -> Int:
    var cc = ctx * 2 + comp
    var sign = ts.rd(ts.cb.mv_sign + cc * 3, 2)
    var mv_class = ts.rd(ts.cb.mv_class + cc * 12, 11)
    var mag: Int
    if mv_class == 0:
        var bit = ts.rd(ts.cb.mv_class0_bit + cc * 3, 2)
        mag = ((bit << 3) | (3 << 1) | 1) + 1
    else:
        var d = 0
        for i in range(mv_class):
            d |= ts.rd(ts.cb.mv_bit + (cc * 10 + i) * 3, 2) << i
        mag = CLASS0_SIZE << (mv_class + 2)
        mag += ((d << 3) | (3 << 1) | 1) + 1
    return -mag if sign == 1 else mag


def read_mv_diff(mut ts: TileState) raises -> Tuple[Int, Int]:
    """read_mv(0) with MvCtx = MV_INTRABC_CONTEXT: the (row, col) difference to PredMv."""
    var ctx = MV_INTRABC_CONTEXT
    var joint = ts.rd(ts.cb.mv_joint + ctx * 5, 4)
    var d0 = 0
    var d1 = 0
    if joint == MV_JOINT_HZVNZ or joint == MV_JOINT_HNZVNZ:
        d0 = read_mv_component(ts, ctx, 0)
    if joint == MV_JOINT_HNZVZ or joint == MV_JOINT_HNZVNZ:
        d1 = read_mv_component(ts, ctx, 1)
    return (d0, d1)


# ---- loop restoration units ----
def inverse_recenter(r: Int, v: Int) -> Int:
    if v > 2 * r:
        return v
    if (v & 1) == 1:
        return r - ((v + 1) >> 1)
    return r + (v >> 1)


def decode_subexp_bool(mut ts: TileState, num_syms: Int, k: Int) raises -> Int:
    var i = 0
    var mk = 0
    while True:
        var b2 = k + i - 1 if i > 0 else k
        var a = 1 << b2
        if num_syms <= mk + 3 * a:
            return read_ns(ts, num_syms - mk) + mk
        if ts.lit(1) == 1:
            i += 1
            mk += a
        else:
            return ts.lit(b2) + mk


def decode_signed_subexp_with_ref_bool(mut ts: TileState, low: Int, high: Int, k: Int, r: Int) raises -> Int:
    var mx = high - low
    var rr = r - low
    var v = decode_subexp_bool(ts, mx, k)
    if (rr << 1) <= mx:
        return inverse_recenter(rr, v) + low
    return mx - 1 - inverse_recenter(mx - 1 - rr, v) + low


def read_lr(mut ts: TileState, r: Int, c: Int, bsize: Int) raises:
    if ts.frame.allow_intrabc:
        return
    var w = global_constant[NUM_4X4_WIDE]()[bsize]
    var h = global_constant[NUM_4X4_HIGH]()[bsize]
    for plane in range(ts.num_planes):
        if ts.frame.frame_restoration_type[plane] != RESTORE_NONE:
            var sx = ts.sub_x if plane > 0 else 0
            var sy = ts.sub_y if plane > 0 else 0
            var unit_size = ts.frame.loop_restoration_size[plane]
            var unit_rows = ts.lr_unit_rows[plane]
            var unit_cols = ts.lr_unit_cols[plane]
            var row_start = (r * (MI_SIZE >> sy) + unit_size - 1) // unit_size
            var row_end = min(unit_rows, ((r + h) * (MI_SIZE >> sy) + unit_size - 1) // unit_size)
            # with superres the columns are counted in the upscaled frame (SuperresDenom / SUPERRES_NUM)
            var numerator = (MI_SIZE >> sx) * ts.frame.superres_denom
            var denominator = unit_size * SUPERRES_NUM
            var col_start = (c * numerator + denominator - 1) // denominator
            var col_end = min(unit_cols, ((c + w) * numerator + denominator - 1) // denominator)
            for unit_row in range(row_start, row_end):
                for unit_col in range(col_start, col_end):
                    read_lr_unit(ts, plane, unit_row, unit_col)


def read_lr_unit(mut ts: TileState, plane: Int, unit_row: Int, unit_col: Int) raises:
    var frt = ts.frame.frame_restoration_type[plane]
    var rtype: Int
    if frt == RESTORE_WIENER:
        rtype = RESTORE_WIENER if ts.rd(ts.cb.use_wiener, 2) == 1 else RESTORE_NONE
    elif frt == RESTORE_SGRPROJ:
        rtype = RESTORE_SGRPROJ if ts.rd(ts.cb.use_sgrproj, 2) == 1 else RESTORE_NONE
    else:
        rtype = ts.rd(ts.cb.restoration_type, 3)
    var u = ts.lr_base[plane] + unit_row * ts.lr_unit_cols[plane] + unit_col
    ts.lr_type[u] = rtype
    if rtype == RESTORE_WIENER:
        ts.stats.wiener += 1
        for pass_i in range(2):
            var first = 0
            if plane > 0:
                first = 1
                ts.lr_wiener[u * 6 + pass_i * 3] = 0
            for j in range(first, 3):
                var ref_i = (plane * 2 + pass_i) * 3 + j
                var v = decode_signed_subexp_with_ref_bool(
                    ts, global_constant[WIENER_TAPS_MIN]()[j], global_constant[WIENER_TAPS_MAX]()[j] + 1, global_constant[WIENER_TAPS_K]()[j], ts.ref_lr_wiener[ref_i]
                )
                ts.lr_wiener[u * 6 + pass_i * 3 + j] = v
                ts.ref_lr_wiener[ref_i] = v
    elif rtype == RESTORE_SGRPROJ:
        ts.stats.sgrproj += 1
        var sgr_set = ts.lit(SGRPROJ_PARAMS_BITS)
        ts.lr_sgr_set[u] = sgr_set
        for i in range(2):
            var radius = ts.sgr_params[sgr_set * 4 + i * 2]
            var mn = global_constant[SGRPROJ_XQD_MIN]()[i]
            var mx = global_constant[SGRPROJ_XQD_MAX]()[i]
            var v = 0
            if radius != 0:
                v = decode_signed_subexp_with_ref_bool(ts, mn, mx + 1, SGRPROJ_PRJ_SUBEXP_K, ts.ref_sgr_xqd[plane * 2 + i])
            elif i == 1:
                v = clip3(mn, mx, (1 << SGRPROJ_PRJ_BITS) - ts.ref_sgr_xqd[plane * 2])
            ts.lr_sgr_xqd[u * 2 + i] = v
            ts.ref_sgr_xqd[plane * 2 + i] = v
