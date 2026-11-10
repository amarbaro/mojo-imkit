"""AV1 reconstruction: dequantization, inverse transforms and add-to-frame (spec 7.12, 7.13)."""
from std.collections import List
from imkit.av1frame import Frame
from imkit.av1tab import Tables
from imkit.av1state import (
    MAX_SEGMENTS, SEG_LVL_MAX, SEG_LVL_ALT_Q,
    TX_SIZES_ALL, TX_4X4, TX_32X32, TX_16X32, TX_32X16, TX_16X64, TX_64X16,
    TX_64X64, TX_32X64, TX_64X32,
)

comptime QM_TOTAL_SIZE = 3344
comptime IDTX = 9

comptime DCT_DCT = 0
comptime ADST_DCT = 1
comptime DCT_ADST = 2
comptime ADST_ADST = 3
comptime FLIPADST_DCT = 4
comptime DCT_FLIPADST = 5
comptime FLIPADST_FLIPADST = 6
comptime ADST_FLIPADST = 7
comptime FLIPADST_ADST = 8
comptime V_DCT = 10
comptime H_DCT = 11
comptime V_ADST = 12
comptime H_ADST = 13
comptime V_FLIPADST = 14
comptime H_FLIPADST = 15

comptime SINPI_1_9 = 1321
comptime SINPI_2_9 = 2482
comptime SINPI_3_9 = 3344
comptime SINPI_4_9 = 3803

# 7.13.2.1
def brev(num_bits: Int, x: Int) -> Int:
    var t = 0
    for i in range(num_bits):
        var bit = (x >> i) & 1
        t += bit << (num_bits - 1 - i)
    return t

def round2(x: Int, n: Int) -> Int:
    if n <= 0:
        return x
    return (x + (Int(1) << (n - 1))) >> n

def clip3(lo: Int, hi: Int, v: Int) -> Int:
    if v < lo:
        return lo
    if v > hi:
        return hi
    return v

def clip3_64(lo: Int, hi: Int, v: Int) -> Int:
    if v < lo:
        return lo
    if v > hi:
        return hi
    return v

# 7.12.2
def dc_q(tables: Tables, bit_depth: Int, q: Int) -> Int:
    var b = (bit_depth - 8) >> 1
    var idx = b * 256 + clip3(0, 255, q)
    if idx < 0 or idx >= len(tables.dc_qlookup):
        return 4
    return Int(tables.dc_qlookup[idx])

def ac_q(tables: Tables, bit_depth: Int, q: Int) -> Int:
    var b = (bit_depth - 8) >> 1
    var idx = b * 256 + clip3(0, 255, q)
    if idx < 0 or idx >= len(tables.ac_qlookup):
        return 4
    return Int(tables.ac_qlookup[idx])

# 7.13.2.1
def cos128(tables: Tables, angle: Int) -> Int:
    var a = angle & 255
    var idx = 0
    var neg = False
    if a <= 64:
        idx = a
    elif a <= 128:
        idx = 128 - a
        neg = True
    elif a <= 192:
        idx = a - 128
        neg = True
    else:
        idx = 256 - a
    if idx < 0 or idx >= len(tables.cos128_lookup):
        return 0
    var v = Int(tables.cos128_lookup[idx])
    return -v if neg else v

def butterfly(mut t: List[Int], a: Int, b: Int, angle: Int, flip: Int, r: Int, tables: Tables):
    var ca = cos128(tables, angle)
    var sa = cos128(tables, angle - 64)
    var ta = t[a]
    var tb = t[b]
    var x = ta * ca - tb * sa
    var y = ta * sa + tb * ca
    t[a] = round2(x, 12)
    t[b] = round2(y, 12)
    if flip != 0:
        var tmp = t[a]
        t[a] = t[b]
        t[b] = tmp

def hadamard(mut t: List[Int], a: Int, b: Int, flip: Int, r: Int):
    if flip != 0:
        hadamard(t, b, a, 0, r)
        return
    var x = t[a]
    var y = t[b]
    var lo = -(Int(1) << (r - 1))
    var hi = (Int(1) << (r - 1)) - 1
    t[a] = clip3_64(lo, hi, x + y)
    t[b] = clip3_64(lo, hi, x - y)

# 7.13.2.2
def dct_permute(mut t: List[Int], n: Int):
    var n0 = 1 << n
    var copy = List[Int](length=n0, fill=0)
    for i in range(n0):
        copy[i] = t[i]
    for i in range(n0):
        t[i] = copy[brev(n, i)]

# 7.13.2.3
def inverse_dct(mut t: List[Int], n: Int, r: Int, tables: Tables):
    dct_permute(t, n)
    if n == 6:
        for i in range(16):
            butterfly(t, 32 + i, 63 - i, 63 - 4 * brev(4, i), 0, r, tables)
    if n >= 5:
        for i in range(8):
            butterfly(t, 16 + i, 31 - i, 6 + (brev(3, 7 - i) << 3), 0, r, tables)
    if n == 6:
        for i in range(16):
            hadamard(t, 32 + i * 2, 33 + i * 2, i & 1, r)
    if n >= 4:
        for i in range(4):
            butterfly(t, 8 + i, 15 - i, 12 + (brev(2, 3 - i) << 4), 0, r, tables)
    if n >= 5:
        for i in range(8):
            hadamard(t, 16 + 2 * i, 17 + 2 * i, i & 1, r)
    if n == 6:
        for i in range(4):
            for j in range(2):
                butterfly(t, 62 - i * 4 - j, 33 + i * 4 + j, 60 - 16 * brev(2, i) + 64 * j, 1, r, tables)
    if n >= 3:
        for i in range(2):
            butterfly(t, 4 + i, 7 - i, 56 - 32 * i, 0, r, tables)
    if n >= 4:
        for i in range(4):
            hadamard(t, 8 + 2 * i, 9 + 2 * i, i & 1, r)
    if n >= 5:
        for i in range(2):
            for j in range(2):
                butterfly(t, 30 - 4 * i - j, 17 + 4 * i + j, 24 + (j << 6) + ((1 - i) << 5), 1, r, tables)
    if n == 6:
        for i in range(8):
            for j in range(2):
                hadamard(t, 32 + i * 4 + j, 35 + i * 4 - j, i & 1, r)
    for i in range(2):
        butterfly(t, 2 * i, 2 * i + 1, 32 + 16 * i, 1 - i, r, tables)
    if n >= 3:
        for i in range(2):
            hadamard(t, 4 + 2 * i, 5 + 2 * i, i, r)
    if n >= 4:
        for i in range(2):
            butterfly(t, 14 - i, 9 + i, 48 + 64 * i, 1, r, tables)
    if n >= 5:
        for i in range(4):
            for j in range(2):
                hadamard(t, 16 + 4 * i + j, 19 + 4 * i - j, i & 1, r)
    if n == 6:
        for i in range(2):
            for j in range(4):
                butterfly(t, 61 - i * 8 - j, 34 + i * 8 + j, 56 - i * 32 + (j >> 1) * 64, 1, r, tables)
    for i in range(2):
        hadamard(t, i, 3 - i, 0, r)
    if n >= 3:
        butterfly(t, 6, 5, 32, 1, r, tables)
    if n >= 4:
        for i in range(2):
            for j in range(2):
                hadamard(t, 8 + 4 * i + j, 11 + 4 * i - j, i, r)
    if n >= 5:
        for i in range(4):
            butterfly(t, 29 - i, 18 + i, 48 + (i >> 1) * 64, 1, r, tables)
    if n == 6:
        for i in range(4):
            for j in range(4):
                hadamard(t, 32 + 8 * i + j, 39 + 8 * i - j, i & 1, r)
    if n >= 3:
        for i in range(4):
            hadamard(t, i, 7 - i, 0, r)
    if n >= 4:
        for i in range(2):
            butterfly(t, 13 - i, 10 + i, 32, 1, r, tables)
    if n >= 5:
        for i in range(2):
            for j in range(4):
                hadamard(t, 16 + i * 8 + j, 23 + i * 8 - j, i, r)
    if n == 6:
        for i in range(8):
            var ang = 48 if i < 4 else 112
            butterfly(t, 59 - i, 36 + i, ang, 1, r, tables)
    if n >= 4:
        for i in range(8):
            hadamard(t, i, 15 - i, 0, r)
    if n >= 5:
        for i in range(4):
            butterfly(t, 27 - i, 20 + i, 32, 1, r, tables)
    if n == 6:
        for i in range(8):
            hadamard(t, 32 + i, 47 - i, 0, r)
            hadamard(t, 48 + i, 63 - i, 1, r)
    if n >= 5:
        for i in range(16):
            hadamard(t, i, 31 - i, 0, r)
    if n == 6:
        for i in range(8):
            butterfly(t, 55 - i, 40 + i, 32, 1, r, tables)
    if n == 6:
        for i in range(32):
            hadamard(t, i, 63 - i, 0, r)

# 7.13.2.4
def adst_input_permute(mut t: List[Int], n: Int):
    var n0 = 1 << n
    var copy = List[Int](length=n0, fill=0)
    for i in range(n0):
        copy[i] = t[i]
    for i in range(n0):
        var idx = (i - 1) if (i & 1) != 0 else (n0 - i - 1)
        t[i] = copy[idx]

# 7.13.2.5
def adst_output_permute(mut t: List[Int], n: Int):
    var n0 = 1 << n
    var copy = List[Int](length=n0, fill=0)
    for i in range(n0):
        copy[i] = t[i]
    for i in range(n0):
        var a = (i >> 3) & 1
        var b = ((i >> 2) & 1) ^ ((i >> 3) & 1)
        var c = ((i >> 1) & 1) ^ ((i >> 2) & 1)
        var d = (i & 1) ^ ((i >> 1) & 1)
        var idx = ((d << 3) | (c << 2) | (b << 1) | a) >> (4 - n)
        t[i] = -copy[idx] if (i & 1) != 0 else copy[idx]

# 7.13.2.6
def inverse_adst4(mut t: List[Int], r: Int):
    var s = List[Int](length=7, fill=0)
    var x = List[Int](length=4, fill=0)
    s[0] = Int(SINPI_1_9) * t[0]
    s[1] = Int(SINPI_2_9) * t[0]
    s[2] = Int(SINPI_3_9) * t[1]
    s[3] = Int(SINPI_4_9) * t[2]
    s[4] = Int(SINPI_1_9) * t[2]
    s[5] = Int(SINPI_2_9) * t[3]
    s[6] = Int(SINPI_4_9) * t[3]
    var a7 = t[0] - t[2]
    var b7 = a7 + t[3]
    s[0] = s[0] + s[3]
    s[1] = s[1] - s[4]
    s[3] = s[2]
    s[2] = Int(SINPI_3_9) * b7
    s[0] = s[0] + s[5]
    s[1] = s[1] - s[6]
    x[0] = s[0] + s[3]
    x[1] = s[1] + s[3]
    x[2] = s[2]
    x[3] = s[0] + s[1]
    x[3] = x[3] - s[3]
    t[0] = round2(x[0], 12)
    t[1] = round2(x[1], 12)
    t[2] = round2(x[2], 12)
    t[3] = round2(x[3], 12)

# 7.13.2.7
def inverse_adst8(mut t: List[Int], r: Int, tables: Tables):
    adst_input_permute(t, 3)
    for i in range(4):
        butterfly(t, 2 * i, 2 * i + 1, 60 - 16 * i, 1, r, tables)
    for i in range(4):
        hadamard(t, i, 4 + i, 0, r)
    for i in range(2):
        butterfly(t, 4 + 3 * i, 5 + i, 48 - 32 * i, 1, r, tables)
    for i in range(2):
        for j in range(2):
            hadamard(t, 4 * j + i, 2 + 4 * j + i, 0, r)
    for i in range(2):
        butterfly(t, 2 + 4 * i, 3 + 4 * i, 32, 1, r, tables)
    adst_output_permute(t, 3)

# 7.13.2.8
def inverse_adst16(mut t: List[Int], r: Int, tables: Tables):
    adst_input_permute(t, 4)
    for i in range(8):
        butterfly(t, 2 * i, 2 * i + 1, 62 - 8 * i, 1, r, tables)
    for i in range(8):
        hadamard(t, i, 8 + i, 0, r)
    for i in range(2):
        butterfly(t, 8 + 2 * i, 9 + 2 * i, 56 - 32 * i, 1, r, tables)
        butterfly(t, 13 + 2 * i, 12 + 2 * i, 8 + 32 * i, 1, r, tables)
    for i in range(4):
        for j in range(2):
            hadamard(t, 8 * j + i, 4 + 8 * j + i, 0, r)
    for i in range(2):
        for j in range(2):
            butterfly(t, 4 + 8 * j + 3 * i, 5 + 8 * j + i, 48 - 32 * i, 1, r, tables)
    for i in range(2):
        for j in range(4):
            hadamard(t, 4 * j + i, 2 + 4 * j + i, 0, r)
    for i in range(4):
        butterfly(t, 2 + 4 * i, 3 + 4 * i, 32, 1, r, tables)
    adst_output_permute(t, 4)

# 7.13.2.9
def inverse_adst(mut t: List[Int], n: Int, r: Int, tables: Tables):
    if n == 2:
        inverse_adst4(t, r)
    elif n == 3:
        inverse_adst8(t, r, tables)
    elif n == 4:
        inverse_adst16(t, r, tables)

# 7.13.2.10
def inverse_wht(mut t: List[Int], shift: Int):
    var a = t[0] >> shift
    var c = t[1] >> shift
    var d = t[2] >> shift
    var b = t[3] >> shift
    a += c
    d -= b
    var e = (a - d) >> 1
    b = e - b
    c = e - c
    a -= b
    d += c
    t[0] = a
    t[1] = b
    t[2] = c
    t[3] = d

# 7.13.2.11-7.13.2.15
def inverse_identity(mut t: List[Int], n: Int):
    var n0 = 1 << n
    if n == 2:
        for i in range(n0):
            t[i] = round2(t[i] * 5793, 12)
    elif n == 3:
        for i in range(n0):
            t[i] = t[i] * 2
    elif n == 4:
        for i in range(n0):
            t[i] = round2(t[i] * 11586, 12)
    elif n == 5:
        for i in range(n0):
            t[i] = t[i] * 4

def row_is_dct(tx_type: Int) -> Bool:
    return tx_type == DCT_DCT or tx_type == ADST_DCT or tx_type == FLIPADST_DCT or tx_type == H_DCT

def row_is_adst(tx_type: Int) -> Bool:
    return (
        tx_type == DCT_ADST or tx_type == ADST_ADST or tx_type == DCT_FLIPADST
        or tx_type == FLIPADST_FLIPADST or tx_type == ADST_FLIPADST
        or tx_type == FLIPADST_ADST or tx_type == H_ADST or tx_type == H_FLIPADST
    )

def col_is_dct(tx_type: Int) -> Bool:
    return tx_type == DCT_DCT or tx_type == DCT_ADST or tx_type == DCT_FLIPADST or tx_type == V_DCT

def col_is_adst(tx_type: Int) -> Bool:
    return (
        tx_type == ADST_DCT or tx_type == ADST_ADST or tx_type == FLIPADST_DCT
        or tx_type == FLIPADST_FLIPADST or tx_type == ADST_FLIPADST
        or tx_type == FLIPADST_ADST or tx_type == V_ADST or tx_type == V_FLIPADST
    )

def flip_ud(tx_type: Int) -> Bool:
    return (
        tx_type == FLIPADST_DCT or tx_type == FLIPADST_ADST
        or tx_type == V_FLIPADST or tx_type == FLIPADST_FLIPADST
    )

def flip_lr(tx_type: Int) -> Bool:
    return (
        tx_type == DCT_FLIPADST or tx_type == ADST_FLIPADST
        or tx_type == H_FLIPADST or tx_type == FLIPADST_FLIPADST
    )

# 7.13.3
def inverse_transform_2d(
    mut residual: List[Int32],
    dequant: List[Int],
    w: Int,
    h: Int,
    tx_size: Int,
    tx_type: Int,
    lossless: Bool,
    bit_depth: Int,
    tables: Tables,
) raises:
    var log2w = Int(tables.tx_width_log2[tx_size])
    var log2h = Int(tables.tx_height_log2[tx_size])
    var row_shift = 0 if lossless else Int(tables.transform_row_shift[tx_size])
    var col_shift = 0 if lossless else 4
    var row_clamp = bit_depth + 8
    var col_clamp = 16 if bit_depth + 6 < 16 else bit_depth + 6
    var col_lo = -(Int(1) << (col_clamp - 1))
    var col_hi = (Int(1) << (col_clamp - 1)) - 1
    var t = List[Int](length=64, fill=0)
    var row_id = not lossless and not row_is_dct(tx_type) and not row_is_adst(tx_type)
    var col_id = not lossless and not col_is_dct(tx_type) and not col_is_adst(tx_type)
    if (row_id and log2w > 5) or (col_id and log2h > 5):
        raise Error("av1recon: identity transform of size 64")

    for i in range(h):
        var any_nz = False
        for j in range(w):
            if i < 32 and j < 32:
                t[j] = dequant[i * w + j]
            else:
                t[j] = 0
            if t[j] != 0:
                any_nz = True
        if not any_nz:
            # every 1D transform maps an all-zero row to zeros
            for j in range(w):
                residual[i * w + j] = 0
            continue
        var diff = log2w - log2h
        if diff == 1 or diff == -1:
            for j in range(w):
                t[j] = round2(t[j] * 2896, 12)
        if lossless:
            inverse_wht(t, 2)
        elif row_is_dct(tx_type):
            inverse_dct(t, log2w, row_clamp, tables)
        elif row_is_adst(tx_type):
            inverse_adst(t, log2w, row_clamp, tables)
        else:
            inverse_identity(t, log2w)
        for j in range(w):
            residual[i * w + j] = Int32(
                clip3_64(col_lo, col_hi, round2(t[j], row_shift))
            )

    for j in range(w):
        for i in range(h):
            t[i] = Int(residual[i * w + j])
        if lossless:
            inverse_wht(t, 0)
        elif col_is_dct(tx_type):
            inverse_dct(t, log2h, col_clamp, tables)
        elif col_is_adst(tx_type):
            inverse_adst(t, log2h, col_clamp, tables)
        else:
            inverse_identity(t, log2h)
        for i in range(h):
            residual[i * w + j] = Int32(round2(t[i], col_shift))


struct ReconInput:
    """Block-level spec variables read by 7.12 reconstruction; lane A sets them per block before `reconstruct`.

    bit_depth: BitDepth (8, 10 or 12). lossless: LosslessArray[segment_id] (4x4 WHT path).
    segment_id: segment of the block. base_q_idx, delta_q_present, current_qindex: frame / block quantizer state.
    seg_feature_enabled / seg_feature_data: flat [segment * SEG_LVL_MAX + feature] (FeatureEnabled / FeatureData).
    delta_q_*: DeltaQYDc, DeltaQUDc, DeltaQVDc, DeltaQUAc, DeltaQVAc. using_qmatrix: using_qmatrix.
    seg_qm_level: flat [plane * MAX_SEGMENTS + segment] (SegQMLevel; 15 = flat matrix)."""
    var bit_depth: Int
    var lossless: Bool
    var segment_id: Int
    var base_q_idx: Int
    var delta_q_present: Bool
    var current_qindex: Int
    var seg_feature_enabled: List[Bool]
    var seg_feature_data: List[Int]
    var delta_q_y_dc: Int
    var delta_q_u_dc: Int
    var delta_q_v_dc: Int
    var delta_q_u_ac: Int
    var delta_q_v_ac: Int
    var using_qmatrix: Bool
    var seg_qm_level: List[Int]

    def __init__(out self):
        self.bit_depth = 8
        self.lossless = False
        self.segment_id = 0
        self.base_q_idx = 0
        self.delta_q_present = False
        self.current_qindex = 0
        self.seg_feature_enabled = List[Bool](length=MAX_SEGMENTS * SEG_LVL_MAX, fill=False)
        self.seg_feature_data = List[Int](length=MAX_SEGMENTS * SEG_LVL_MAX, fill=0)
        self.delta_q_y_dc = 0
        self.delta_q_u_dc = 0
        self.delta_q_v_dc = 0
        self.delta_q_u_ac = 0
        self.delta_q_v_ac = 0
        self.using_qmatrix = False
        self.seg_qm_level = List[Int](length=3 * MAX_SEGMENTS, fill=15)

    # 7.12.2
    def seg_feature_active_idx(self, seg: Int, feature: Int) -> Bool:
        if seg < 0 or seg >= MAX_SEGMENTS or feature < 0 or feature >= SEG_LVL_MAX:
            return False
        return self.seg_feature_enabled[seg * SEG_LVL_MAX + feature]

    def feature_data(self, seg: Int, feature: Int) -> Int:
        if seg < 0 or seg >= MAX_SEGMENTS or feature < 0 or feature >= SEG_LVL_MAX:
            return 0
        return self.seg_feature_data[seg * SEG_LVL_MAX + feature]

    def get_qindex(self, ignore_delta_q: Bool) -> Int:
        var seg = self.segment_id
        if self.seg_feature_active_idx(seg, SEG_LVL_ALT_Q):
            var data = self.feature_data(seg, SEG_LVL_ALT_Q)
            var qindex = self.base_q_idx + data
            if not ignore_delta_q and self.delta_q_present:
                qindex = self.current_qindex + data
            return clip3(0, 255, qindex)
        if not ignore_delta_q and self.delta_q_present:
            return self.current_qindex
        return self.base_q_idx

    def get_dc_quant(self, tables: Tables, plane: Int) -> Int:
        var q = self.get_qindex(False)
        if plane == 0:
            q += self.delta_q_y_dc
        elif plane == 1:
            q += self.delta_q_u_dc
        else:
            q += self.delta_q_v_dc
        return dc_q(tables, self.bit_depth, q)

    def get_ac_quant(self, tables: Tables, plane: Int) -> Int:
        var q = self.get_qindex(False)
        if plane == 1:
            q += self.delta_q_u_ac
        elif plane == 2:
            q += self.delta_q_v_ac
        return ac_q(tables, self.bit_depth, q)


# 7.12.3
def reconstruct(
    mut frame: Frame,
    tables: Tables,
    inp: ReconInput,
    plane: Int,
    x: Int,
    y: Int,
    tx_size: Int,
    tx_type: Int,
    quant: Span[Int32, _],
    eob: Int,
) raises:
    if plane < 0 or plane >= len(frame.planes):
        raise Error("av1recon: plane out of range")
    if tx_size < 0 or tx_size >= TX_SIZES_ALL:
        raise Error("av1recon: tx_size out of range")
    if tx_type < 0 or tx_type >= 16:
        raise Error("av1recon: tx_type out of range")
    if inp.bit_depth != 8 and inp.bit_depth != 10 and inp.bit_depth != 12:
        raise Error("av1recon: bit_depth out of range")

    var w = Int(tables.tx_width[tx_size])
    var h = Int(tables.tx_height[tx_size])
    var pw = frame.planes[plane].w
    var ph = frame.planes[plane].h
    if x < 0 or y < 0 or x >= pw or y >= ph:
        raise Error("av1recon: block starts outside plane")
    var tw = 32 if w > 32 else w
    var th = 32 if h > 32 else h
    if len(quant) < tw * th:
        raise Error("av1recon: quant shorter than tw * th")
    if eob < 0 or eob > tw * th:
        raise Error("av1recon: eob out of range")
    if inp.lossless and tx_size != TX_4X4:
        raise Error("av1recon: lossless needs TX_4X4")
    if eob == 0:
        return  # all coefficients zero: Residual is zero for every transform

    var dq_denom = 1
    if (
        tx_size == TX_32X32 or tx_size == TX_16X32 or tx_size == TX_32X16
        or tx_size == TX_16X64 or tx_size == TX_64X16
    ):
        dq_denom = 2
    elif tx_size == TX_64X64 or tx_size == TX_32X64 or tx_size == TX_64X32:
        dq_denom = 4

    var dequant = List[Int](length=w * h, fill=0)
    var dcq = inp.get_dc_quant(tables, plane)
    var acq = inp.get_ac_quant(tables, plane)
    var qm_level = 15
    if inp.segment_id < 0 or inp.segment_id >= MAX_SEGMENTS:
        raise Error("av1recon: segment_id out of range")
    var qi = plane * MAX_SEGMENTS + inp.segment_id
    if qi < len(inp.seg_qm_level):
        qm_level = inp.seg_qm_level[qi]
    if qm_level < 0 or qm_level > 15:
        raise Error("av1recon: qm level out of range")
    var use_qm = inp.using_qmatrix and tx_type < IDTX and qm_level < 15
    var qm_base = ((qm_level * 2 + (1 if plane > 0 else 0)) * QM_TOTAL_SIZE + Int(tables.qm_offset[tx_size]))
    if use_qm and qm_base + tw * th > len(tables.quantizer_matrix):
        raise Error("av1recon: quantizer matrix index out of range")
    var dequant_lo = -(Int(1) << (7 + inp.bit_depth))
    var dequant_hi = (Int(1) << (7 + inp.bit_depth)) - 1

    for i in range(th):
        for j in range(tw):
            var qv = Int(quant[i * tw + j])
            if qv == 0:
                continue
            var q = Int(dcq if (i == 0 and j == 0) else acq)
            if use_qm:
                q = round2(q * Int(tables.quantizer_matrix[qm_base + i * tw + j]), 5)
            var dq = qv * q
            var sign: Int = -1 if dq < 0 else 1
            var masked = (dq if dq >= 0 else -dq) & 0xFFFFFF
            dequant[i * w + j] = clip3_64(dequant_lo, dequant_hi, sign * (masked // Int(dq_denom)))

    var residual = List[Int32](length=w * h, fill=0)
    inverse_transform_2d(
        residual, dequant, w, h, tx_size, tx_type, inp.lossless, inp.bit_depth, tables
    )

    var ud = flip_ud(tx_type)
    var lr = flip_lr(tx_type)
    var maxv = (1 << inp.bit_depth) - 1
    # Blocks may overhang the plane (the spec's CurrFrame is unbounded); samples outside are never read back,
    # so they are not stored. Lane A allocates planes of at least MiCols * 4 (resp. MiRows * 4) samples.
    for i in range(h):
        var yy = y + ((h - i - 1) if ud else i)
        if yy >= ph:
            continue
        for j in range(w):
            var xx = x + ((w - j - 1) if lr else j)
            if xx >= pw:
                continue
            var val = frame.planes[plane].get(xx, yy) + Int(residual[i * w + j])
            frame.planes[plane].set(xx, yy, clip3(0, maxv, val))
