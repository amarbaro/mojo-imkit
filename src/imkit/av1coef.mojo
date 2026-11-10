"""AV1 residual syntax (spec 5.11.34 to 5.11.39, CDF selection of 8.3): residual, transform_tree, transform_block, coeffs.

Parsing only. Every transform block visited is recorded in `ts.txs` (decode order) with its dequantisation input
(`Quant[]`, tw * th entries in `ts.quant_pool`), so reconstruction can replay prediction and inverse transforms after
the tile is parsed: nothing here depends on a reconstructed pixel."""
from std.builtin.globals import global_constant
from imkit.av1state import (
    TileState, TxRec, BLOCK_64X64, BLOCK_INVALID, TX_4X4, TX_32X32, TX_64X64, TX_16X32, TX_32X16, TX_16X64, TX_64X16,
    TX_16X16, TX_SIZES_ALL, UV_CFL_PRED, DC_PRED, MI_SIZE_LOG2, TX_CLASS_2D, TX_CLASS_HORIZ, TX_CLASS_VERT, DCT_DCT,
    IDTX, V_DCT, V_ADST, V_FLIPADST, H_DCT, H_ADST, H_FLIPADST, BDSZ,
    BLOCK_WIDTH, BLOCK_HEIGHT, NUM_4X4_WIDE, NUM_4X4_HIGH, MAX_TX_SIZE_RECT, TX_WIDTH, TX_HEIGHT, TX_WIDTH_LOG2,
    TX_HEIGHT_LOG2, TX_SIZE_SQR, TX_SIZE_SQR_UP, ADJUSTED_TX_SIZE, MODE_TO_TXFM, TX_TYPE_IN_SET_INTRA,
    TX_TYPE_IN_SET_INTER, TX_TYPE_INTRA_INV_SET1, TX_TYPE_INTRA_INV_SET2, TX_TYPE_INTER_INV_SET1,
    TX_TYPE_INTER_INV_SET2, TX_TYPE_INTER_INV_SET3, FILTER_INTRA_MODE_TO_INTRA_DIR, PAD,
    subsampled_size, find_tx_size, get_tx_class,
)

comptime TX_SET_DCTONLY = 0
comptime SIG_COEF_CONTEXTS = 42


def a_idx(ts: TileState, plane: Int, x4: Int) -> Int:
    return plane * ts.stride + x4


def l_idx(ts: TileState, plane: Int, y4: Int) -> Int:
    return plane * (ts.mi_rows + PAD) + y4


def plane_residual_size(ts: TileState, bsize: Int, plane: Int) raises -> Int:
    var sx = ts.sub_x if plane > 0 else 0
    var sy = ts.sub_y if plane > 0 else 0
    var r = subsampled_size(bsize, sx, sy)
    if r == BLOCK_INVALID:
        raise Error("av1coef: no residual size for block " + String(bsize))
    return r


def get_tx_size(ts: TileState, plane: Int, tx_sz: Int) raises -> Int:
    if plane == 0:
        return tx_sz
    var uv_tx = global_constant[MAX_TX_SIZE_RECT]()[plane_residual_size(ts, ts.mi_size, plane)]
    if global_constant[TX_WIDTH]()[uv_tx] == 64 or global_constant[TX_HEIGHT]()[uv_tx] == 64:
        if global_constant[TX_WIDTH]()[uv_tx] == 16:
            return TX_16X32
        if global_constant[TX_HEIGHT]()[uv_tx] == 16:
            return TX_32X16
        return TX_32X32
    return uv_tx


def residual(mut ts: TileState) raises:
    var width_chunks = max(1, global_constant[BLOCK_WIDTH]()[ts.mi_size] >> 6)
    var height_chunks = max(1, global_constant[BLOCK_HEIGHT]()[ts.mi_size] >> 6)
    var mi_size_chunk = BLOCK_64X64 if (width_chunks > 1 or height_chunks > 1) else ts.mi_size
    for chunk_y in range(height_chunks):
        for chunk_x in range(width_chunks):
            var mi_row_chunk = ts.mi_row + (chunk_y << 4)
            var mi_col_chunk = ts.mi_col + (chunk_x << 4)
            for plane in range(1 + (2 if ts.has_chroma else 0)):
                var tx_sz = TX_4X4 if ts.lossless else get_tx_size(ts, plane, ts.tx_size)
                var step_x = global_constant[TX_WIDTH]()[tx_sz] >> 2
                var step_y = global_constant[TX_HEIGHT]()[tx_sz] >> 2
                var plane_sz = plane_residual_size(ts, mi_size_chunk, plane)
                var num4x4_w = global_constant[NUM_4X4_WIDE]()[plane_sz]
                var num4x4_h = global_constant[NUM_4X4_HIGH]()[plane_sz]
                var sx = ts.sub_x if plane > 0 else 0
                var sy = ts.sub_y if plane > 0 else 0
                var base_x = (mi_col_chunk >> sx) * 4
                var base_y = (mi_row_chunk >> sy) * 4
                if ts.is_inter and not ts.lossless and plane == 0:
                    transform_tree(ts, base_x, base_y, num4x4_w * 4, num4x4_h * 4)
                else:
                    var base_x_block = (ts.mi_col >> sx) * 4
                    var base_y_block = (ts.mi_row >> sy) * 4
                    for y in range(0, num4x4_h, step_y):
                        for x in range(0, num4x4_w, step_x):
                            transform_block(
                                ts, plane, base_x_block, base_y_block, tx_sz,
                                x + ((chunk_x << 4) >> sx), y + ((chunk_y << 4) >> sy),
                            )


def transform_tree(mut ts: TileState, start_x: Int, start_y: Int, w: Int, h: Int) raises:
    if start_x >= ts.mi_cols * 4 or start_y >= ts.mi_rows * 4:
        return
    var luma_tx = ts.inter_tx_sizes[ts.at(start_y >> 2, start_x >> 2)]
    if w <= global_constant[TX_WIDTH]()[luma_tx] and h <= global_constant[TX_HEIGHT]()[luma_tx]:
        var tx_sz = find_tx_size(w, h)
        if tx_sz >= TX_SIZES_ALL:
            raise Error("av1coef: no transform of " + String(w) + "x" + String(h))
        transform_block(ts, 0, start_x, start_y, tx_sz, 0, 0)
    elif w > h:
        transform_tree(ts, start_x, start_y, w // 2, h)
        transform_tree(ts, start_x + w // 2, start_y, w // 2, h)
    elif w < h:
        transform_tree(ts, start_x, start_y, w, h // 2)
        transform_tree(ts, start_x, start_y + h // 2, w, h // 2)
    else:
        transform_tree(ts, start_x, start_y, w // 2, h // 2)
        transform_tree(ts, start_x + w // 2, start_y, w // 2, h // 2)
        transform_tree(ts, start_x, start_y + h // 2, w // 2, h // 2)
        transform_tree(ts, start_x + w // 2, start_y + h // 2, w // 2, h // 2)


def transform_block(mut ts: TileState, plane: Int, base_x: Int, base_y: Int, tx_sz: Int, x: Int, y: Int) raises:
    var start_x = base_x + 4 * x
    var start_y = base_y + 4 * y
    var sx = ts.sub_x if plane > 0 else 0
    var sy = ts.sub_y if plane > 0 else 0
    var row = (start_y << sy) >> MI_SIZE_LOG2
    var col = (start_x << sx) >> MI_SIZE_LOG2
    var sb_mask = 31 if ts.seq.use_128x128_superblock else 15
    var sub_row = row & sb_mask
    var sub_col = col & sb_mask
    var step_x = global_constant[TX_WIDTH]()[tx_sz] >> MI_SIZE_LOG2
    var step_y = global_constant[TX_HEIGHT]()[tx_sz] >> MI_SIZE_LOG2
    var max_x = (ts.mi_cols * 4) >> sx
    var max_y = (ts.mi_rows * 4) >> sy
    if start_x >= max_x or start_y >= max_y:
        return
    var rec = TxRec(
        len(ts.blocks), plane, start_x, start_y, x, y, tx_sz, DCT_DCT, 0, -1,
        (ts.avail_l if plane == 0 else ts.avail_l_chroma) or x > 0,
        (ts.avail_u if plane == 0 else ts.avail_u_chroma) or y > 0,
        ts.bd(plane, (sub_row >> sy) - 1, (sub_col >> sx) + step_x),
        ts.bd(plane, (sub_row >> sy) + step_y, (sub_col >> sx) - 1),
    )
    if not ts.skip:
        var eob = coeffs(ts, plane, start_x, start_y, tx_sz, rec)
        rec.eob = eob
        if eob > 0:
            var tw = min(32, global_constant[TX_WIDTH]()[tx_sz])
            var th = min(32, global_constant[TX_HEIGHT]()[tx_sz])
            rec.quant_off = len(ts.quant_pool)
            for i in range(tw * th):
                ts.quant_pool.append(Int32(ts.quant[i]))
            ts.stats.nonzero += 1
    ts.stats.tx_blocks += 1
    ts.txs.append(rec^)
    for i in range(step_y):
        for j in range(step_x):
            ts.lf_tx_sizes[plane * ts.stride * (ts.mi_rows + PAD) + ts.at((row >> sy) + i, (col >> sx) + j)] = tx_sz
            ts.block_decoded[plane * BDSZ * BDSZ + ((sub_row >> sy) + i + 1) * BDSZ + (sub_col >> sx) + j + 1] = True


def get_tx_set(ts: TileState, tx_sz: Int) -> Int:
    var sqr = global_constant[TX_SIZE_SQR]()[tx_sz]
    var sqr_up = global_constant[TX_SIZE_SQR_UP]()[tx_sz]
    if sqr_up > TX_32X32:
        return TX_SET_DCTONLY
    if ts.is_inter:
        if ts.frame.reduced_tx_set or sqr_up == TX_32X32:
            return 3
        if sqr == TX_16X16:
            return 2
        return 1
    if sqr_up == TX_32X32:
        return TX_SET_DCTONLY
    if ts.frame.reduced_tx_set or sqr == TX_16X16:
        return 2
    return 1


def is_tx_type_in_set(ts: TileState, tx_set: Int, tx_type: Int) -> Bool:
    if ts.is_inter:
        return global_constant[TX_TYPE_IN_SET_INTER]()[tx_set * 16 + tx_type] == 1
    return global_constant[TX_TYPE_IN_SET_INTRA]()[tx_set * 16 + tx_type] == 1


def compute_tx_type(ts: TileState, plane: Int, tx_sz: Int, block_x: Int, block_y: Int) -> Int:
    if ts.lossless or global_constant[TX_SIZE_SQR_UP]()[tx_sz] > TX_32X32:
        return DCT_DCT
    var tx_set = get_tx_set(ts, tx_sz)
    if plane == 0:
        return ts.tx_types[ts.at(block_y, block_x)]
    var tx_type: Int
    if ts.is_inter:
        var x4 = max(ts.mi_col, block_x << ts.sub_x)
        var y4 = max(ts.mi_row, block_y << ts.sub_y)
        tx_type = ts.tx_types[ts.at(y4, x4)]
    else:
        tx_type = global_constant[MODE_TO_TXFM]()[ts.uv_mode]
    if not is_tx_type_in_set(ts, tx_set, tx_type):
        return DCT_DCT
    return tx_type


def transform_type(mut ts: TileState, x4: Int, y4: Int, tx_sz: Int) raises:
    var tx_set = get_tx_set(ts, tx_sz)
    var qi = ts.get_qindex(True, ts.segment_id) if ts.frame.segmentation_enabled else ts.frame.base_q_idx
    var tx_type = DCT_DCT
    if tx_set > 0 and qi > 0:
        var sqr = global_constant[TX_SIZE_SQR]()[tx_sz]
        if ts.is_inter:
            if tx_set == 1:
                tx_type = global_constant[TX_TYPE_INTER_INV_SET1]()[ts.rd(ts.cb.inter_tx_set1 + sqr * 17, 16)]
            elif tx_set == 2:
                tx_type = global_constant[TX_TYPE_INTER_INV_SET2]()[ts.rd(ts.cb.inter_tx_set2, 12)]
            else:
                tx_type = global_constant[TX_TYPE_INTER_INV_SET3]()[ts.rd(ts.cb.inter_tx_set3 + sqr * 3, 2)]
        else:
            var intra_dir = ts.y_mode
            if ts.use_filter_intra:
                intra_dir = global_constant[FILTER_INTRA_MODE_TO_INTRA_DIR]()[ts.filter_intra_mode]
            if tx_set == 1:
                tx_type = global_constant[TX_TYPE_INTRA_INV_SET1]()[ts.rd(ts.cb.intra_tx_set1 + (sqr * 13 + intra_dir) * 8, 7)]
            else:
                tx_type = global_constant[TX_TYPE_INTRA_INV_SET2]()[ts.rd(ts.cb.intra_tx_set2 + (sqr * 13 + intra_dir) * 6, 5)]
    for i in range(global_constant[TX_WIDTH]()[tx_sz] >> 2):
        for j in range(global_constant[TX_HEIGHT]()[tx_sz] >> 2):
            ts.tx_types[ts.at(y4 + j, x4 + i)] = tx_type


def scan_offset(ts: TileState, tx_sz: Int, tx_type: Int) raises -> Int:
    """get_scan (5.11.41) as an offset into ts.scan_pool."""
    var kind = 0
    if tx_sz == TX_16X64 or tx_sz == TX_64X16 or global_constant[TX_SIZE_SQR_UP]()[tx_sz] == TX_64X64:
        kind = 0
    elif tx_type == IDTX:
        kind = 0
    elif tx_type == V_DCT or tx_type == V_ADST or tx_type == V_FLIPADST:
        kind = 1
    elif tx_type == H_DCT or tx_type == H_ADST or tx_type == H_FLIPADST:
        kind = 2
    var off = ts.scan_off[tx_sz * 3 + kind]
    if off < 0:
        raise Error("av1coef: no scan for tx " + String(tx_sz) + " type " + String(tx_type))
    return off


def coeff_base_ctx(ts: TileState, tx_sz: Int, tx_class: Int, pos: Int, c: Int, is_eob: Bool) -> Int:
    var adj = global_constant[ADJUSTED_TX_SIZE]()[tx_sz]
    var bwl = global_constant[TX_WIDTH_LOG2]()[adj]
    var width = 1 << bwl
    var height = global_constant[TX_HEIGHT]()[adj]
    if is_eob:
        if c == 0:
            return 0
        if c <= (height << bwl) // 8:
            return 1
        if c <= (height << bwl) // 4:
            return 2
        return 3
    var row = pos >> bwl
    var col = pos - (row << bwl)
    var mag = 0
    for idx in range(5):
        var ref_row = row + ts.sig_ref[(tx_class * 5 + idx) * 2]
        var ref_col = col + ts.sig_ref[(tx_class * 5 + idx) * 2 + 1]
        if ref_row >= 0 and ref_col >= 0 and ref_row < height and ref_col < width:
            mag += min(abs(ts.quant[(ref_row << bwl) + ref_col]), 3)
    var ctx = min((mag + 1) >> 1, 4)
    if tx_class == TX_CLASS_2D:
        if row == 0 and col == 0:
            return 0
        return ctx + ts.cb_ctx_off[tx_sz * 25 + min(row, 4) * 5 + min(col, 4)]
    var idx2 = row if tx_class == TX_CLASS_VERT else col
    return ctx + 26 + 5 * min(idx2, 2)


def coeff_br_ctx(ts: TileState, tx_sz: Int, tx_class: Int, pos: Int) -> Int:
    var adj = global_constant[ADJUSTED_TX_SIZE]()[tx_sz]
    var bwl = global_constant[TX_WIDTH_LOG2]()[adj]
    var txw = global_constant[TX_WIDTH]()[adj]
    var txh = global_constant[TX_HEIGHT]()[adj]
    var row = pos >> bwl
    var col = pos - (row << bwl)
    var mag = 0
    for idx in range(3):
        var ref_row = row + ts.mag_ref[(tx_class * 3 + idx) * 2]
        var ref_col = col + ts.mag_ref[(tx_class * 3 + idx) * 2 + 1]
        if ref_row >= 0 and ref_col >= 0 and ref_row < txh and ref_col < (1 << bwl):
            mag += min(ts.quant[ref_row * txw + ref_col], 15)
    mag = min((mag + 1) >> 1, 6)
    if pos == 0:
        return mag
    if tx_class == 0:
        return mag + 7 if (row < 2 and col < 2) else mag + 14
    if tx_class == 1:
        return mag + 7 if col == 0 else mag + 14
    return mag + 7 if row == 0 else mag + 14


def all_zero_ctx(ts: TileState, plane: Int, tx_sz: Int, x4: Int, y4: Int, w4: Int, h4: Int) raises -> Int:
    var max_x4 = ts.mi_cols
    var max_y4 = ts.mi_rows
    if plane > 0:
        max_x4 = max_x4 >> ts.sub_x
        max_y4 = max_y4 >> ts.sub_y
    var w = global_constant[TX_WIDTH]()[tx_sz]
    var h = global_constant[TX_HEIGHT]()[tx_sz]
    var bsize = plane_residual_size(ts, ts.mi_size, plane)
    var bw = global_constant[BLOCK_WIDTH]()[bsize]
    var bh = global_constant[BLOCK_HEIGHT]()[bsize]
    if plane == 0:
        var top = 0
        var left = 0
        for k in range(w4):
            if x4 + k < max_x4:
                top = max(top, ts.above_level[a_idx(ts, plane, x4 + k)])
        for k in range(h4):
            if y4 + k < max_y4:
                left = max(left, ts.left_level[l_idx(ts, plane, y4 + k)])
        top = min(top, 255)
        left = min(left, 255)
        if bw == w and bh == h:
            return 0
        if top == 0 and left == 0:
            return 1
        if top == 0 or left == 0:
            return 2 + (1 if max(top, left) > 3 else 0)
        if max(top, left) <= 3:
            return 4
        if min(top, left) <= 3:
            return 5
        return 6
    var above = 0
    var left = 0
    for i in range(w4):
        if x4 + i < max_x4:
            above |= ts.above_level[a_idx(ts, plane, x4 + i)]
            above |= ts.above_dc[a_idx(ts, plane, x4 + i)]
    for i in range(h4):
        if y4 + i < max_y4:
            left |= ts.left_level[l_idx(ts, plane, y4 + i)]
            left |= ts.left_dc[l_idx(ts, plane, y4 + i)]
    var ctx = (1 if above != 0 else 0) + (1 if left != 0 else 0)
    ctx += 7
    if bw * bh > w * h:
        ctx += 3
    return ctx


def dc_sign_ctx(ts: TileState, plane: Int, x4: Int, y4: Int, w4: Int, h4: Int) -> Int:
    var max_x4 = ts.mi_cols
    var max_y4 = ts.mi_rows
    if plane > 0:
        max_x4 = max_x4 >> ts.sub_x
        max_y4 = max_y4 >> ts.sub_y
    var dc_sign = 0
    for k in range(w4):
        if x4 + k < max_x4:
            var s = ts.above_dc[a_idx(ts, plane, x4 + k)]
            if s == 1:
                dc_sign -= 1
            elif s == 2:
                dc_sign += 1
    for k in range(h4):
        if y4 + k < max_y4:
            var s = ts.left_dc[l_idx(ts, plane, y4 + k)]
            if s == 1:
                dc_sign -= 1
            elif s == 2:
                dc_sign += 1
    return 1 if dc_sign < 0 else (2 if dc_sign > 0 else 0)


def read_eob_pt(mut ts: TileState, multi: Int, ptype: Int, ctx: Int) raises -> Int:
    var q = ts.qctx
    if multi == 0:
        return ts.rd(ts.cb.eob_pt_16 + ((q * 2 + ptype) * 2 + ctx) * 6, 5) + 1
    if multi == 1:
        return ts.rd(ts.cb.eob_pt_32 + ((q * 2 + ptype) * 2 + ctx) * 7, 6) + 1
    if multi == 2:
        return ts.rd(ts.cb.eob_pt_64 + ((q * 2 + ptype) * 2 + ctx) * 8, 7) + 1
    if multi == 3:
        return ts.rd(ts.cb.eob_pt_128 + ((q * 2 + ptype) * 2 + ctx) * 9, 8) + 1
    if multi == 4:
        return ts.rd(ts.cb.eob_pt_256 + ((q * 2 + ptype) * 2 + ctx) * 10, 9) + 1
    if multi == 5:
        return ts.rd(ts.cb.eob_pt_512 + (q * 2 + ptype) * 11, 10) + 1
    return ts.rd(ts.cb.eob_pt_1024 + (q * 2 + ptype) * 12, 11) + 1


def coeffs(mut ts: TileState, plane: Int, start_x: Int, start_y: Int, tx_sz: Int, mut rec: TxRec) raises -> Int:
    var x4 = start_x >> 2
    var y4 = start_y >> 2
    var w4 = global_constant[TX_WIDTH]()[tx_sz] >> 2
    var h4 = global_constant[TX_HEIGHT]()[tx_sz] >> 2
    var tx_sz_ctx = (global_constant[TX_SIZE_SQR]()[tx_sz] + global_constant[TX_SIZE_SQR_UP]()[tx_sz] + 1) >> 1
    var ptype = 1 if plane > 0 else 0
    var q = ts.qctx
    var seg_eob = 512 if (tx_sz == TX_16X64 or tx_sz == TX_64X16) else min(1024, global_constant[TX_WIDTH]()[tx_sz] * global_constant[TX_HEIGHT]()[tx_sz])
    for c in range(seg_eob):
        ts.quant[c] = 0
    var eob = 0
    var cul_level = 0
    var dc_category = 0
    var az_ctx = all_zero_ctx(ts, plane, tx_sz, x4, y4, w4, h4)
    var all_zero = ts.rd(ts.cb.txb_skip + ((q * 5 + tx_sz_ctx) * 13 + az_ctx) * 3, 2)
    if all_zero == 1:
        if plane == 0:
            for i in range(w4):
                for j in range(h4):
                    ts.tx_types[ts.at(y4 + j, x4 + i)] = DCT_DCT
    else:
        if plane == 0:
            transform_type(ts, x4, y4, tx_sz)
        var plane_tx_type = compute_tx_type(ts, plane, tx_sz, x4, y4)
        rec.tx_type = plane_tx_type
        var scan = scan_offset(ts, tx_sz, plane_tx_type)
        var tx_class = get_tx_class(plane_tx_type)
        var eob_multi = min(global_constant[TX_WIDTH_LOG2]()[tx_sz], 5) + min(global_constant[TX_HEIGHT_LOG2]()[tx_sz], 5) - 4
        var eob_ctx = 0 if tx_class == TX_CLASS_2D else 1
        var eob_pt = read_eob_pt(ts, eob_multi, ptype, eob_ctx)
        eob = eob_pt if eob_pt < 2 else ((1 << (eob_pt - 2)) + 1)
        var eob_shift = max(-1, eob_pt - 3)
        if eob_shift >= 0:
            var extra = ts.rd(ts.cb.eob_extra + (((q * 5 + tx_sz_ctx) * 2 + ptype) * 9 + (eob_pt - 3)) * 3, 2)
            if extra == 1:
                eob += 1 << eob_shift
            for i in range(1, max(0, eob_pt - 2)):
                eob_shift = max(0, eob_pt - 2) - 1 - i
                if ts.lit(1) == 1:
                    eob += 1 << eob_shift
        if eob > seg_eob:
            raise Error("av1coef: eob " + String(eob) + " beyond " + String(seg_eob))
        for c in range(eob - 1, -1, -1):
            var pos = Int(ts.scan_pool[scan + c])
            var level: Int
            if c == eob - 1:
                var ctx = coeff_base_ctx(ts, tx_sz, tx_class, pos, c, True)
                level = ts.rd(ts.cb.coeff_base_eob + (((q * 5 + tx_sz_ctx) * 2 + ptype) * 4 + ctx) * 4, 3) + 1
            else:
                var ctx = coeff_base_ctx(ts, tx_sz, tx_class, pos, c, False)
                level = ts.rd(ts.cb.coeff_base + (((q * 5 + tx_sz_ctx) * 2 + ptype) * 42 + ctx) * 5, 4)
            if level > 2:
                var br_ctx = coeff_br_ctx(ts, tx_sz, tx_class, pos)
                var br_off = ts.cb.coeff_br + (((q * 5 + min(tx_sz_ctx, 3)) * 2 + ptype) * 21 + br_ctx) * 5
                for _ in range(4):
                    var br = ts.rd(br_off, 4)
                    level += br
                    if br < 3:
                        break
            ts.quant[pos] = level
        for c in range(eob):
            var pos = Int(ts.scan_pool[scan + c])
            var sign = 0
            if ts.quant[pos] != 0:
                if c == 0:
                    var dctx = dc_sign_ctx(ts, plane, x4, y4, w4, h4)
                    sign = ts.rd(ts.cb.dc_sign + ((q * 2 + ptype) * 3 + dctx) * 3, 2)
                else:
                    sign = ts.lit(1)
            if ts.quant[pos] > 14:
                var length = 0
                var bit = 0
                while bit == 0:
                    length += 1
                    if length > 32:
                        raise Error("av1coef: golomb length beyond 32")
                    bit = ts.lit(1)
                var x = 1
                for _ in range(length - 1):
                    x = (x << 1) | ts.lit(1)
                ts.quant[pos] = x + 14
                ts.stats.golomb += 1
            if pos == 0 and ts.quant[pos] > 0:
                dc_category = 1 if sign == 1 else 2
            ts.quant[pos] = ts.quant[pos] & 0xFFFFF
            cul_level += ts.quant[pos]
            if sign == 1:
                ts.quant[pos] = -ts.quant[pos]
        cul_level = min(63, cul_level)
    for i in range(w4):
        ts.above_level[a_idx(ts, plane, x4 + i)] = cul_level
        ts.above_dc[a_idx(ts, plane, x4 + i)] = dc_category
    for i in range(h4):
        ts.left_level[l_idx(ts, plane, y4 + i)] = cul_level
        ts.left_dc[l_idx(ts, plane, y4 + i)] = dc_category
    return eob
