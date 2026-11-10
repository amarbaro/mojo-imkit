"""AV1 tile syntax state: spec constants, frame-wide mode-info arrays, per-tile symbol state, block and transform records."""
from std.builtin.globals import global_constant
from std.collections import List
from imkit.av1sym import SymbolDecoder
from imkit.av1tab import Cdfs, Scans, Tables
from imkit.av1obu import Av1Stream, SequenceHeader, FrameHeader

# ---- spec symbolic constants (section 3, section 6) ----
comptime BLOCK_4X4 = 0
comptime BLOCK_4X8 = 1
comptime BLOCK_8X4 = 2
comptime BLOCK_8X8 = 3
comptime BLOCK_8X16 = 4
comptime BLOCK_16X8 = 5
comptime BLOCK_16X16 = 6
comptime BLOCK_16X32 = 7
comptime BLOCK_32X16 = 8
comptime BLOCK_32X32 = 9
comptime BLOCK_32X64 = 10
comptime BLOCK_64X32 = 11
comptime BLOCK_64X64 = 12
comptime BLOCK_64X128 = 13
comptime BLOCK_128X64 = 14
comptime BLOCK_128X128 = 15
comptime BLOCK_4X16 = 16
comptime BLOCK_16X4 = 17
comptime BLOCK_8X32 = 18
comptime BLOCK_32X8 = 19
comptime BLOCK_16X64 = 20
comptime BLOCK_64X16 = 21
comptime BLOCK_INVALID = 22
comptime BLOCK_SIZES = 22

comptime PARTITION_NONE = 0
comptime PARTITION_HORZ = 1
comptime PARTITION_VERT = 2
comptime PARTITION_SPLIT = 3
comptime PARTITION_HORZ_A = 4
comptime PARTITION_HORZ_B = 5
comptime PARTITION_VERT_A = 6
comptime PARTITION_VERT_B = 7
comptime PARTITION_HORZ_4 = 8
comptime PARTITION_VERT_4 = 9

comptime TX_4X4 = 0
comptime TX_8X8 = 1
comptime TX_16X16 = 2
comptime TX_32X32 = 3
comptime TX_64X64 = 4
comptime TX_4X8 = 5
comptime TX_8X4 = 6
comptime TX_8X16 = 7
comptime TX_16X8 = 8
comptime TX_16X32 = 9
comptime TX_32X16 = 10
comptime TX_32X64 = 11
comptime TX_64X32 = 12
comptime TX_4X16 = 13
comptime TX_16X4 = 14
comptime TX_8X32 = 15
comptime TX_32X8 = 16
comptime TX_16X64 = 17
comptime TX_64X16 = 18
comptime TX_SIZES_ALL = 19

comptime DC_PRED = 0
comptime V_PRED = 1
comptime H_PRED = 2
comptime D45_PRED = 3
comptime D135_PRED = 4
comptime D113_PRED = 5
comptime D157_PRED = 6
comptime D203_PRED = 7
comptime D67_PRED = 8
comptime SMOOTH_PRED = 9
comptime SMOOTH_V_PRED = 10
comptime SMOOTH_H_PRED = 11
comptime PAETH_PRED = 12
comptime UV_CFL_PRED = 13
comptime INTRA_MODES = 13

comptime INTRA_FRAME = 0
comptime NONE_FRAME = -1

comptime SEG_LVL_ALT_Q = 0
comptime SEG_LVL_ALT_LF_Y_V = 1
comptime SEG_LVL_ALT_LF_Y_H = 2
comptime SEG_LVL_ALT_LF_U = 3
comptime SEG_LVL_ALT_LF_V = 4
comptime SEG_LVL_REF_FRAME = 5
comptime SEG_LVL_SKIP = 6
comptime SEG_LVL_GLOBALMV = 7
comptime SEG_LVL_MAX = 8

comptime RESTORE_NONE = 0
comptime RESTORE_WIENER = 1
comptime RESTORE_SGRPROJ = 2
comptime RESTORE_SWITCHABLE = 3

comptime TX_MODE_ONLY_4X4 = 0
comptime TX_MODE_LARGEST = 1
comptime TX_MODE_SELECT = 2

comptime MAX_VARTX_DEPTH = 2
comptime MAX_TX_DEPTH = 2
comptime MI_SIZE = 4
comptime MI_SIZE_LOG2 = 2
comptime MAX_SEGMENTS = 8
comptime FRAME_LF_COUNT = 4
comptime MAX_LOOP_FILTER = 63
comptime DELTA_Q_SMALL = 3
comptime DELTA_LF_SMALL = 3
comptime PALETTE_COLORS = 8
comptime PALETTE_NUM_NEIGHBORS = 3
comptime PALETTE_COLOR_CONTEXTS = 5
comptime PALETTE_MAX_COLOR_CONTEXT_HASH = 8
comptime CFL_ALPHABET_SIZE = 16
comptime CFL_JOINT_SIGNS = 8
comptime CFL_SIGN_ZERO = 0
comptime CFL_SIGN_NEG = 1
comptime CFL_SIGN_POS = 2
comptime MV_JOINT_HZVNZ = 0
comptime MV_JOINT_HNZVZ = 1
comptime MV_JOINT_HZVNZ_HNZVZ = 2
comptime MV_CLASS_0 = 0
comptime CLASS0_SIZE = 2
comptime MV_INTRABC_CONTEXT = 1
comptime INTRABC_DELAY_PIXELS = 256
comptime MAX_TILE_WIDTH = 4096
comptime MAX_TILE_AREA = 4096 * 2304
comptime MAX_TILE_COLS = 64
comptime MAX_TILE_ROWS = 64
comptime SUPERRES_NUM = 8
comptime SGRPROJ_PARAMS_BITS = 4
comptime SGRPROJ_PRJ_SUBEXP_K = 4
comptime SGRPROJ_PRJ_BITS = 7
comptime SGRPROJ_XQD_MID0 = -32
comptime SGRPROJ_XQD_MID1 = 31
comptime WIENER_TAPS_MID0 = 3
comptime WIENER_TAPS_MID1 = -7
comptime WIENER_TAPS_MID2 = 15

# ---- section 9.3 conversion tables ----
comptime BLOCK_WIDTH = [4, 4, 8, 8, 8, 16, 16, 16, 32, 32, 32, 64, 64, 64, 128, 128, 4, 16, 8, 32, 16, 64]
comptime BLOCK_HEIGHT = [4, 8, 4, 8, 16, 8, 16, 32, 16, 32, 64, 32, 64, 128, 64, 128, 16, 4, 32, 8, 64, 16]
comptime MI_WIDTH_LOG2 = [0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5, 5, 0, 2, 1, 3, 2, 4]
comptime MI_HEIGHT_LOG2 = [0, 1, 0, 1, 2, 1, 2, 3, 2, 3, 4, 3, 4, 5, 4, 5, 2, 0, 3, 1, 4, 2]
comptime NUM_4X4_WIDE = [1, 1, 2, 2, 2, 4, 4, 4, 8, 8, 8, 16, 16, 16, 32, 32, 1, 4, 2, 8, 4, 16]
comptime NUM_4X4_HIGH = [1, 2, 1, 2, 4, 2, 4, 8, 4, 8, 16, 8, 16, 32, 16, 32, 4, 1, 8, 2, 16, 4]
comptime SIZE_GROUP = [0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 0, 0, 1, 1, 2, 2]

comptime MAX_TX_SIZE_RECT = [
    TX_4X4, TX_4X8, TX_8X4, TX_8X8, TX_8X16, TX_16X8, TX_16X16,
    TX_16X32, TX_32X16, TX_32X32, TX_32X64, TX_64X32, TX_64X64,
    TX_64X64, TX_64X64, TX_64X64, TX_4X16, TX_16X4, TX_8X32,
    TX_32X8, TX_16X64, TX_64X16,
]
comptime MAX_TX_DEPTH_TABLE = [0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4, 4, 4, 4, 2, 2, 3, 3, 4, 4]

comptime SPLIT_TX_SIZE = [
    TX_4X4, TX_4X4, TX_8X8, TX_16X16, TX_32X32,
    TX_4X4, TX_4X4, TX_8X8, TX_8X8, TX_16X16,
    TX_16X16, TX_32X32, TX_32X32, TX_4X8, TX_8X4,
    TX_8X16, TX_16X8, TX_16X32, TX_32X16,
]
comptime TX_WIDTH = [4, 8, 16, 32, 64, 4, 8, 8, 16, 16, 32, 32, 64, 4, 16, 8, 32, 16, 64]
comptime TX_HEIGHT = [4, 8, 16, 32, 64, 8, 4, 16, 8, 32, 16, 64, 32, 16, 4, 32, 8, 64, 16]
comptime TX_WIDTH_LOG2 = [2, 3, 4, 5, 6, 2, 3, 3, 4, 4, 5, 5, 6, 2, 4, 3, 5, 4, 6]
comptime TX_HEIGHT_LOG2 = [2, 3, 4, 5, 6, 3, 2, 4, 3, 5, 4, 6, 5, 4, 2, 5, 3, 6, 4]
comptime TX_SIZE_SQR = [
    TX_4X4, TX_8X8, TX_16X16, TX_32X32, TX_64X64,
    TX_4X4, TX_4X4, TX_8X8, TX_8X8, TX_16X16,
    TX_16X16, TX_32X32, TX_32X32, TX_4X4, TX_4X4,
    TX_8X8, TX_8X8, TX_16X16, TX_16X16,
]
comptime TX_SIZE_SQR_UP = [
    TX_4X4, TX_8X8, TX_16X16, TX_32X32, TX_64X64,
    TX_8X8, TX_8X8, TX_16X16, TX_16X16, TX_32X32,
    TX_32X32, TX_64X64, TX_64X64, TX_16X16, TX_16X16,
    TX_32X32, TX_32X32, TX_64X64, TX_64X64,
]
comptime ADJUSTED_TX_SIZE = [
    TX_4X4, TX_8X8, TX_16X16, TX_32X32, TX_32X32,
    TX_4X8, TX_8X4, TX_8X16, TX_16X8, TX_16X32,
    TX_32X16, TX_32X32, TX_32X32, TX_4X16, TX_16X4,
    TX_8X32, TX_32X8, TX_16X32, TX_32X16,
]
comptime INTRA_MODE_CONTEXT = [0, 1, 2, 3, 4, 4, 4, 4, 3, 0, 1, 2, 0]
comptime PALETTE_COLOR_HASH_MULTIPLIERS = [1, 2, 2]
comptime PALETTE_COLOR_CONTEXT = [-1, -1, 0, -1, -1, 4, 3, 2, 1]

comptime WIENER_TAPS_MIN = [-5, -23, -17]
comptime WIENER_TAPS_MAX = [10, 8, 46]
comptime WIENER_TAPS_K = [1, 2, 3]
comptime SGRPROJ_XQD_MIN = [-96, -32]
comptime SGRPROJ_XQD_MAX = [31, 95]


comptime BDSZ = 35  # BlockDecoded side: -1 .. 33 for a 32x32 (4x4 units) superblock
comptime PAD = 32  # mode-info grids are padded by one 128x128 superblock: blocks may overhang the frame edge
comptime TX_CLASS_2D = 0
comptime TX_CLASS_HORIZ = 1
comptime TX_CLASS_VERT = 2
comptime DCT_DCT = 0
comptime IDTX = 9
comptime V_DCT = 10
comptime H_DCT = 11
comptime V_ADST = 12
comptime H_ADST = 13
comptime V_FLIPADST = 14
comptime H_FLIPADST = 15

# small spec tables absent from av1tab (copied from the spec text, section 5.11.47 / 5.11.40 / 8.3)
comptime MODE_TO_TXFM = [0, 1, 2, 0, 3, 1, 2, 2, 1, 3, 1, 2, 3, 0]
comptime TX_TYPE_IN_SET_INTRA = [
    1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0,
    1, 1, 1, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0,
]
comptime TX_TYPE_IN_SET_INTER = [
    1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0,
    1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0,
]
comptime TX_TYPE_INTRA_INV_SET1 = [9, 0, 10, 11, 3, 1, 2]
comptime TX_TYPE_INTRA_INV_SET2 = [9, 0, 3, 1, 2]
comptime TX_TYPE_INTER_INV_SET1 = [9, 10, 11, 12, 13, 14, 15, 0, 1, 2, 4, 5, 3, 6, 7, 8]
comptime TX_TYPE_INTER_INV_SET2 = [9, 10, 11, 0, 1, 2, 4, 5, 3, 6, 7, 8]
comptime TX_TYPE_INTER_INV_SET3 = [9, 0]
comptime FILTER_INTRA_MODE_TO_INTRA_DIR = [0, 1, 2, 6, 0]


def zeros(n: Int) -> List[Int]:
    return List[Int](length=n, fill=0)


def fill_ints(n: Int, v: Int) -> List[Int]:
    return List[Int](length=n, fill=v)


def block_width(b: Int) -> Int:
    return global_constant[BLOCK_WIDTH]()[b]


def block_height(b: Int) -> Int:
    return global_constant[BLOCK_HEIGHT]()[b]


def num_4x4_wide(b: Int) -> Int:
    return global_constant[NUM_4X4_WIDE]()[b]


def num_4x4_high(b: Int) -> Int:
    return global_constant[NUM_4X4_HIGH]()[b]


def tx_width(t: Int) -> Int:
    return global_constant[TX_WIDTH]()[t]


def tx_height(t: Int) -> Int:
    return global_constant[TX_HEIGHT]()[t]


def block_from_dims(w: Int, h: Int) -> Int:
    for b in range(BLOCK_SIZES):
        if global_constant[BLOCK_WIDTH]()[b] == w and global_constant[BLOCK_HEIGHT]()[b] == h:
            return b
    return BLOCK_INVALID


def find_tx_size(w: Int, h: Int) -> Int:
    for t in range(TX_SIZES_ALL):
        if global_constant[TX_WIDTH]()[t] == w and global_constant[TX_HEIGHT]()[t] == h:
            return t
    return TX_SIZES_ALL


def partition_subsize(partition: Int, bsize: Int) -> Int:
    """Partition_Subsize[partition][bsize] (section 9.3), BLOCK_INVALID where the spec has none."""
    var w = global_constant[BLOCK_WIDTH]()[bsize]
    var h = global_constant[BLOCK_HEIGHT]()[bsize]
    if partition == PARTITION_NONE:
        return bsize
    if partition == PARTITION_HORZ and w == h and w >= 8:
        return block_from_dims(w, h >> 1)
    if partition == PARTITION_VERT and w == h and w >= 8:
        return block_from_dims(w >> 1, h)
    if partition == PARTITION_SPLIT and w == h and w >= 8:
        return block_from_dims(w >> 1, h >> 1)
    if (partition == PARTITION_HORZ_A or partition == PARTITION_HORZ_B) and w == h and w >= 16:
        return block_from_dims(w, h >> 1)
    if (partition == PARTITION_VERT_A or partition == PARTITION_VERT_B) and w == h and w >= 16:
        return block_from_dims(w >> 1, h)
    if partition == PARTITION_HORZ_4 and w == h and w >= 16 and w <= 64:
        return block_from_dims(w, h >> 2)
    if partition == PARTITION_VERT_4 and w == h and w >= 16 and w <= 64:
        return block_from_dims(w >> 2, h)
    return BLOCK_INVALID


def subsampled_size(bsize: Int, sub_x: Int, sub_y: Int) -> Int:
    """Subsampled_Size[bsize][sub_x][sub_y]: the halved block, or BLOCK_INVALID where the spec table has it (a tall block
    in 4:2:2, a wide block with only vertical subsampling)."""
    var w = global_constant[BLOCK_WIDTH]()[bsize]
    var h = global_constant[BLOCK_HEIGHT]()[bsize]
    if (sub_x == 1 and sub_y == 0 and h > w) or (sub_x == 0 and sub_y == 1 and w > h):
        return BLOCK_INVALID
    return block_from_dims(max(global_constant[BLOCK_WIDTH]()[bsize] >> sub_x, 4), max(global_constant[BLOCK_HEIGHT]()[bsize] >> sub_y, 4))


def is_directional_mode(mode: Int) -> Bool:
    return mode >= V_PRED and mode <= D67_PRED


def get_tx_class(tx_type: Int) -> Int:
    if tx_type == V_DCT or tx_type == V_ADST or tx_type == V_FLIPADST:
        return TX_CLASS_VERT
    if tx_type == H_DCT or tx_type == H_ADST or tx_type == H_FLIPADST:
        return TX_CLASS_HORIZ
    return TX_CLASS_2D


def ceil_log2(x: Int) -> Int:
    if x < 2:
        return 0
    var n = 0
    var v = 1
    while v < x:
        v <<= 1
        n += 1
    return n


def clip3(lo: Int, hi: Int, v: Int) -> Int:
    return lo if v < lo else (hi if v > hi else v)


def add_cdf(mut pool: List[UInt16], t: List[UInt16], copies: Int = 1) -> Int:
    """Append `copies` copies of a default table to the pool; return the offset of the first."""
    var base = len(pool)
    for _ in range(copies):
        for i in range(len(t)):
            pool.append(t[i])
    return base


struct CdfBase(Copyable, Movable):
    """Offset of every CDF table inside TileState.pool. Row layout of each table is the spec's dimensions, row stride n + 1.
    The per-context MV tables and DeltaLFMulti are replicated as init_non_coeff_cdfs says; coefficient tables keep the
    leading COEFF_CDF_Q_CTXS dimension."""

    var intra_frame_y_mode: Int
    var uv_mode_cfl_not_allowed: Int
    var uv_mode_cfl_allowed: Int
    var angle_delta: Int
    var intrabc: Int
    var partition_w8: Int
    var partition_w16: Int
    var partition_w32: Int
    var partition_w64: Int
    var partition_w128: Int
    var tx_8x8: Int
    var tx_16x16: Int
    var tx_32x32: Int
    var tx_64x64: Int
    var txfm_split: Int
    var filter_intra_mode: Int
    var filter_intra: Int
    var segment_id: Int
    var skip: Int
    var palette_y_mode: Int
    var palette_uv_mode: Int
    var palette_y_size: Int
    var palette_uv_size: Int
    var palette_y_color: List[Int]  # index = palette size
    var palette_uv_color: List[Int]
    var delta_q: Int
    var delta_lf: Int
    var delta_lf_multi: Int  # FRAME_LF_COUNT copies
    var intra_tx_set1: Int
    var intra_tx_set2: Int
    var inter_tx_set1: Int
    var inter_tx_set2: Int
    var inter_tx_set3: Int
    var cfl_sign: Int
    var cfl_alpha: Int
    var use_wiener: Int
    var use_sgrproj: Int
    var restoration_type: Int
    var txb_skip: Int
    var eob_pt_16: Int
    var eob_pt_32: Int
    var eob_pt_64: Int
    var eob_pt_128: Int
    var eob_pt_256: Int
    var eob_pt_512: Int
    var eob_pt_1024: Int
    var eob_extra: Int
    var dc_sign: Int
    var coeff_base_eob: Int
    var coeff_base: Int
    var coeff_br: Int
    var mv_joint: Int  # [ctx][5]
    var mv_class: Int  # [ctx][comp][12]
    var mv_class0_bit: Int  # [ctx][comp][3]
    var mv_fr: Int  # [ctx][comp][5]
    var mv_class0_fr: Int  # [ctx][comp][bit][5]
    var mv_class0_hp: Int  # [ctx][comp][3]
    var mv_hp: Int
    var mv_sign: Int
    var mv_bit: Int  # [ctx][comp][10][3]

    def __init__(out self, c: Cdfs, mut p: List[UInt16]):
        self.intra_frame_y_mode = add_cdf(p, c.intra_frame_y_mode)
        self.uv_mode_cfl_not_allowed = add_cdf(p, c.uv_mode_cfl_not_allowed)
        self.uv_mode_cfl_allowed = add_cdf(p, c.uv_mode_cfl_allowed)
        self.angle_delta = add_cdf(p, c.angle_delta)
        self.intrabc = add_cdf(p, c.intrabc)
        self.partition_w8 = add_cdf(p, c.partition_w8)
        self.partition_w16 = add_cdf(p, c.partition_w16)
        self.partition_w32 = add_cdf(p, c.partition_w32)
        self.partition_w64 = add_cdf(p, c.partition_w64)
        self.partition_w128 = add_cdf(p, c.partition_w128)
        self.tx_8x8 = add_cdf(p, c.tx_8x8)
        self.tx_16x16 = add_cdf(p, c.tx_16x16)
        self.tx_32x32 = add_cdf(p, c.tx_32x32)
        self.tx_64x64 = add_cdf(p, c.tx_64x64)
        self.txfm_split = add_cdf(p, c.txfm_split)
        self.filter_intra_mode = add_cdf(p, c.filter_intra_mode)
        self.filter_intra = add_cdf(p, c.filter_intra)
        self.segment_id = add_cdf(p, c.segment_id)
        self.skip = add_cdf(p, c.skip)
        self.palette_y_mode = add_cdf(p, c.palette_y_mode)
        self.palette_uv_mode = add_cdf(p, c.palette_uv_mode)
        self.palette_y_size = add_cdf(p, c.palette_y_size)
        self.palette_uv_size = add_cdf(p, c.palette_uv_size)
        self.palette_y_color = List[Int](length=9, fill=0)
        self.palette_uv_color = List[Int](length=9, fill=0)
        self.palette_y_color[2] = add_cdf(p, c.palette_size_2_y_color)
        self.palette_y_color[3] = add_cdf(p, c.palette_size_3_y_color)
        self.palette_y_color[4] = add_cdf(p, c.palette_size_4_y_color)
        self.palette_y_color[5] = add_cdf(p, c.palette_size_5_y_color)
        self.palette_y_color[6] = add_cdf(p, c.palette_size_6_y_color)
        self.palette_y_color[7] = add_cdf(p, c.palette_size_7_y_color)
        self.palette_y_color[8] = add_cdf(p, c.palette_size_8_y_color)
        self.palette_uv_color[2] = add_cdf(p, c.palette_size_2_uv_color)
        self.palette_uv_color[3] = add_cdf(p, c.palette_size_3_uv_color)
        self.palette_uv_color[4] = add_cdf(p, c.palette_size_4_uv_color)
        self.palette_uv_color[5] = add_cdf(p, c.palette_size_5_uv_color)
        self.palette_uv_color[6] = add_cdf(p, c.palette_size_6_uv_color)
        self.palette_uv_color[7] = add_cdf(p, c.palette_size_7_uv_color)
        self.palette_uv_color[8] = add_cdf(p, c.palette_size_8_uv_color)
        self.delta_q = add_cdf(p, c.delta_q)
        self.delta_lf = add_cdf(p, c.delta_lf)
        self.delta_lf_multi = add_cdf(p, c.delta_lf, FRAME_LF_COUNT)
        self.intra_tx_set1 = add_cdf(p, c.intra_tx_type_set1)
        self.intra_tx_set2 = add_cdf(p, c.intra_tx_type_set2)
        self.inter_tx_set1 = add_cdf(p, c.inter_tx_type_set1)
        self.inter_tx_set2 = add_cdf(p, c.inter_tx_type_set2)
        self.inter_tx_set3 = add_cdf(p, c.inter_tx_type_set3)
        self.cfl_sign = add_cdf(p, c.cfl_sign)
        self.cfl_alpha = add_cdf(p, c.cfl_alpha)
        self.use_wiener = add_cdf(p, c.use_wiener)
        self.use_sgrproj = add_cdf(p, c.use_sgrproj)
        self.restoration_type = add_cdf(p, c.restoration_type)
        self.txb_skip = add_cdf(p, c.txb_skip)
        self.eob_pt_16 = add_cdf(p, c.eob_pt_16)
        self.eob_pt_32 = add_cdf(p, c.eob_pt_32)
        self.eob_pt_64 = add_cdf(p, c.eob_pt_64)
        self.eob_pt_128 = add_cdf(p, c.eob_pt_128)
        self.eob_pt_256 = add_cdf(p, c.eob_pt_256)
        self.eob_pt_512 = add_cdf(p, c.eob_pt_512)
        self.eob_pt_1024 = add_cdf(p, c.eob_pt_1024)
        self.eob_extra = add_cdf(p, c.eob_extra)
        self.dc_sign = add_cdf(p, c.dc_sign)
        self.coeff_base_eob = add_cdf(p, c.coeff_base_eob)
        self.coeff_base = add_cdf(p, c.coeff_base)
        self.coeff_br = add_cdf(p, c.coeff_br)
        self.mv_joint = add_cdf(p, c.mv_joint, 2)
        self.mv_class = add_cdf(p, c.mv_class, 2)
        self.mv_class0_bit = add_cdf(p, c.mv_class0_bit, 4)
        self.mv_fr = add_cdf(p, c.mv_fr, 2)
        self.mv_class0_fr = add_cdf(p, c.mv_class0_fr, 2)
        self.mv_class0_hp = add_cdf(p, c.mv_class0_hp, 4)
        self.mv_hp = add_cdf(p, c.mv_hp, 4)
        self.mv_sign = add_cdf(p, c.mv_sign, 4)
        self.mv_bit = add_cdf(p, c.mv_bit, 4)


def scan_of(sc: Scans, tx: Int, kind: Int) -> List[UInt16]:
    """The scan table for a transform size and kind (0 default, 1 mrow, 2 mcol); empty where the spec never asks for it."""
    var e = List[UInt16]()
    if kind == 0:
        if tx == TX_4X4:
            return sc.default_scan_4x4.copy()
        if tx == TX_4X8:
            return sc.default_scan_4x8.copy()
        if tx == TX_8X4:
            return sc.default_scan_8x4.copy()
        if tx == TX_8X8:
            return sc.default_scan_8x8.copy()
        if tx == TX_8X16:
            return sc.default_scan_8x16.copy()
        if tx == TX_16X8:
            return sc.default_scan_16x8.copy()
        if tx == TX_16X16:
            return sc.default_scan_16x16.copy()
        if tx == TX_16X32 or tx == TX_16X64:
            return sc.default_scan_16x32.copy()
        if tx == TX_32X16 or tx == TX_64X16:
            return sc.default_scan_32x16.copy()
        if tx == TX_4X16:
            return sc.default_scan_4x16.copy()
        if tx == TX_16X4:
            return sc.default_scan_16x4.copy()
        if tx == TX_8X32:
            return sc.default_scan_8x32.copy()
        if tx == TX_32X8:
            return sc.default_scan_32x8.copy()
        return sc.default_scan_32x32.copy()
    if kind == 1:
        if tx == TX_4X4:
            return sc.mrow_scan_4x4.copy()
        if tx == TX_4X8:
            return sc.mrow_scan_4x8.copy()
        if tx == TX_8X4:
            return sc.mrow_scan_8x4.copy()
        if tx == TX_8X8:
            return sc.mrow_scan_8x8.copy()
        if tx == TX_8X16:
            return sc.mrow_scan_8x16.copy()
        if tx == TX_16X8:
            return sc.mrow_scan_16x8.copy()
        if tx == TX_16X16:
            return sc.mrow_scan_16x16.copy()
        if tx == TX_4X16:
            return sc.mrow_scan_4x16.copy()
        if tx == TX_16X4:
            return sc.mrow_scan_16x4.copy()
        return e^
    if tx == TX_4X4:
        return sc.mcol_scan_4x4.copy()
    if tx == TX_4X8:
        return sc.mcol_scan_4x8.copy()
    if tx == TX_8X4:
        return sc.mcol_scan_8x4.copy()
    if tx == TX_8X8:
        return sc.mcol_scan_8x8.copy()
    if tx == TX_8X16:
        return sc.mcol_scan_8x16.copy()
    if tx == TX_16X8:
        return sc.mcol_scan_16x8.copy()
    if tx == TX_16X16:
        return sc.mcol_scan_16x16.copy()
    if tx == TX_4X16:
        return sc.mcol_scan_4x16.copy()
    if tx == TX_16X4:
        return sc.mcol_scan_16x4.copy()
    return e^


@fieldwise_init
struct TileStats(Copyable, Movable):
    var blocks: Int
    var mi_covered: Int
    var mi_total: Int
    var tx_blocks: Int
    var nonzero: Int
    var skip: Int
    var intrabc: Int
    var palette: Int
    var cfl: Int
    var filter_intra: Int
    var golomb: Int
    var vartx_split: Int
    var wiener: Int
    var sgrproj: Int
    var segmented: Int

    def __init__(out self):
        self.blocks = 0
        self.mi_covered = 0
        self.mi_total = 0
        self.tx_blocks = 0
        self.nonzero = 0
        self.skip = 0
        self.intrabc = 0
        self.palette = 0
        self.cfl = 0
        self.filter_intra = 0
        self.golomb = 0
        self.vartx_split = 0
        self.wiener = 0
        self.sgrproj = 0
        self.segmented = 0


@fieldwise_init
struct TxRec(Copyable, Movable):
    """One transform block in decode order: everything reconstruction needs besides the block's mode info."""

    var block: Int  # index into TileState.blocks
    var plane: Int
    var start_x: Int
    var start_y: Int
    var x: Int  # 4x4 offset inside the block, in plane units (transform_block's x, y)
    var y: Int
    var tx_size: Int
    var tx_type: Int
    var eob: Int
    var quant_off: Int  # offset into TileState.quant_pool, -1 when eob == 0; tw * th entries, row-major, tw = min(32, w)
    var have_left: Bool
    var have_above: Bool
    var have_above_rt: Bool
    var have_below_lft: Bool


struct BlockInfo(Copyable, Movable):
    """Mode info of one decoded block, as reconstruction and the filters read it."""

    var mi_row: Int
    var mi_col: Int
    var mi_size: Int
    var has_chroma: Bool
    var avail_u: Bool
    var avail_l: Bool
    var avail_u_chroma: Bool
    var avail_l_chroma: Bool
    var segment_id: Int
    var skip: Bool
    var lossless: Bool
    var current_qindex: Int
    var is_inter: Bool
    var use_intrabc: Bool
    var mv_row: Int
    var mv_col: Int
    var y_mode: Int
    var uv_mode: Int
    var angle_delta_y: Int
    var angle_delta_uv: Int
    var cfl_alpha_u: Int
    var cfl_alpha_v: Int
    var use_filter_intra: Bool
    var filter_intra_mode: Int
    var palette_size_y: Int
    var palette_size_uv: Int
    var palette_y: List[Int]
    var palette_u: List[Int]
    var palette_v: List[Int]
    var map_y_off: Int  # offset into TileState.color_maps, block_width stride
    var map_uv_off: Int  # stride = the chroma block width as palette_tokens computes it
    var map_uv_stride: Int
    var tx_size: Int
    var tx_first: Int  # TxRec range [tx_first, tx_end)
    var tx_end: Int

    def __init__(out self):
        self.mi_row = 0
        self.mi_col = 0
        self.mi_size = 0
        self.has_chroma = False
        self.avail_u = False
        self.avail_l = False
        self.avail_u_chroma = False
        self.avail_l_chroma = False
        self.segment_id = 0
        self.skip = False
        self.lossless = False
        self.current_qindex = 0
        self.is_inter = False
        self.use_intrabc = False
        self.mv_row = 0
        self.mv_col = 0
        self.y_mode = 0
        self.uv_mode = 0
        self.angle_delta_y = 0
        self.angle_delta_uv = 0
        self.cfl_alpha_u = 0
        self.cfl_alpha_v = 0
        self.use_filter_intra = False
        self.filter_intra_mode = 0
        self.palette_size_y = 0
        self.palette_size_uv = 0
        self.palette_y = List[Int]()
        self.palette_u = List[Int]()
        self.palette_v = List[Int]()
        self.map_y_off = -1
        self.map_uv_off = -1
        self.map_uv_stride = 0
        self.tx_size = 0
        self.tx_first = 0
        self.tx_end = 0


struct TileState(Movable):
    """Frame-wide mode-info grids plus the per-tile parse state. One instance serves every tile of a frame in turn
    (`start_tile`), so the grids that reconstruction and the filters need afterwards are already frame-wide."""

    # ---- frame constants ----
    var seq: SequenceHeader
    var frame: FrameHeader
    var mi_cols: Int
    var mi_rows: Int
    var stride: Int  # grid row stride = mi_cols + PAD
    var sub_x: Int
    var sub_y: Int
    var num_planes: Int
    var tx_mode: Int
    var qctx: Int
    var lossless_arr: List[Bool]
    var coded_lossless: Bool
    var seg_id_pre_skip: Bool
    var last_active_seg_id: Int
    var pool0: List[UInt16]  # default CDFs, frame start
    var cb: CdfBase
    var scan_pool: List[UInt16]
    var scan_off: List[Int]  # tx_size * 3 + kind
    var sig_ref: List[Int]  # Sig_Ref_Diff_Offset
    var mag_ref: List[Int]  # Mag_Ref_Offset_With_Tx_Class
    var cb_ctx_off: List[Int]  # Coeff_Base_Ctx_Offset
    var sgr_params: List[Int]  # Sgr_Params[16][4]

    # ---- per tile ----
    var sym: SymbolDecoder
    var pool: List[UInt16]
    var scratch: List[UInt16]
    var tile_index: Int
    var mi_col_start: Int
    var mi_col_end: Int
    var mi_row_start: Int
    var mi_row_end: Int
    var stats: TileStats
    var above_level: List[Int]  # [plane][x4]
    var above_dc: List[Int]
    var left_level: List[Int]  # [plane][y4]
    var left_dc: List[Int]
    var delta_lf: List[Int]
    var current_qindex: Int
    var ref_lr_wiener: List[Int]  # [plane][pass][3]
    var ref_sgr_xqd: List[Int]  # [plane][2]
    var read_deltas: Bool
    var block_decoded: List[Bool]  # [plane][y + 1][x + 1], BDSZ x BDSZ

    # ---- frame-wide grids, index row * stride + col ----
    var mi_sizes: List[Int]
    var y_modes: List[Int]
    var uv_modes: List[Int]
    var ref_frames: List[Int]  # two per mi
    var is_inters: List[Int]
    var skip_modes: List[Int]
    var skips: List[Int]
    var tx_sizes: List[Int]
    var inter_tx_sizes: List[Int]
    var segment_ids: List[Int]
    var palette_sizes: List[Int]  # [plane 0..1][mi]
    var palette_colors: List[UInt16]  # [(plane * mi + idx)][8]
    var delta_lfs: List[Int]  # four per mi
    var mvs: List[Int]  # two per mi (row, col)
    var tx_types: List[Int]
    var lf_tx_sizes: List[Int]  # [plane][mi], in plane 4x4 units
    var cdef_idx: List[Int]

    # ---- loop restoration units ----
    var lr_unit_rows: List[Int]
    var lr_unit_cols: List[Int]
    var lr_base: List[Int]  # per plane offset into the lr_* arrays
    var lr_type: List[Int]
    var lr_wiener: List[Int]  # six per unit: [pass][3]
    var lr_sgr_set: List[Int]
    var lr_sgr_xqd: List[Int]  # two per unit

    # ---- records for reconstruction ----
    var blocks: List[BlockInfo]
    var tile_stats: List[TileStats]
    var map_y_off: Int
    var map_uv_off: Int
    var map_uv_stride: Int
    var txs: List[TxRec]
    var quant_pool: List[Int32]
    var color_maps: List[UInt8]
    var quant: List[Int]  # Quant[] of the transform block being parsed

    # ---- the block being parsed (spec variable names) ----
    var mi_row: Int
    var mi_col: Int
    var mi_size: Int
    var has_chroma: Bool
    var avail_u: Bool
    var avail_l: Bool
    var avail_u_chroma: Bool
    var avail_l_chroma: Bool
    var y_mode: Int
    var uv_mode: Int
    var angle_delta_y: Int
    var angle_delta_uv: Int
    var cfl_alpha_u: Int
    var cfl_alpha_v: Int
    var use_filter_intra: Bool
    var filter_intra_mode: Int
    var palette_size_y: Int
    var palette_size_uv: Int
    var palette_colors_y: List[Int]
    var palette_colors_u: List[Int]
    var palette_colors_v: List[Int]
    var color_map_y: List[UInt8]
    var color_map_uv: List[UInt8]
    var segment_id: Int
    var lossless: Bool
    var skip: Bool
    var is_inter: Bool
    var use_intrabc: Bool
    var mv_row: Int
    var mv_col: Int
    var tx_size: Int
    var ref_stack_mv: List[Int]  # RefStackMv[idx][0] as (row, col), idx 0..1 for intrabc
    var num_mv_found: Int

    def __init__(out self, st: Av1Stream) raises:
        var ti = st.frame.tile_info.copy()
        var nc = len(ti.mi_col_starts)
        var nr = len(ti.mi_row_starts)
        if nc < 2 or nr < 2 or len(st.tile_offs) < 1 or len(st.tile_offs) != len(st.tile_sizes):
            raise Error("av1tile: bad tile grid")
        if st.frame.frame_type == 1 or st.frame.frame_type == 3:
            raise Error("av1tile: inter frames are not supported")
        self.seq = st.seq.copy()
        self.frame = st.frame.copy()
        self.mi_cols = ti.mi_col_starts[nc - 1]
        self.mi_rows = ti.mi_row_starts[nr - 1]
        self.stride = self.mi_cols + PAD
        self.sub_x = 1 if st.seq.subsampling_x else 0
        self.sub_y = 1 if st.seq.subsampling_y else 0
        self.num_planes = st.seq.num_planes
        self.coded_lossless = st.frame.coded_lossless
        self.tx_mode = TX_MODE_ONLY_4X4
        if not st.frame.coded_lossless:
            self.tx_mode = TX_MODE_SELECT if st.frame.tx_mode_select else TX_MODE_LARGEST
        var q = st.frame.base_q_idx
        self.qctx = 0 if q <= 20 else (1 if q <= 60 else (2 if q <= 120 else 3))

        self.pool0 = List[UInt16]()
        self.cb = CdfBase(Cdfs(), self.pool0)
        var sc = Scans()
        self.scan_pool = List[UInt16]()
        self.scan_off = List[Int]()
        for tx in range(TX_SIZES_ALL):
            for kind in range(3):
                var t = scan_of(sc, tx, kind)
                if len(t) == 0:
                    self.scan_off.append(-1)
                else:
                    self.scan_off.append(len(self.scan_pool))
                    for i in range(len(t)):
                        self.scan_pool.append(t[i])
        var tb = Tables()
        self.sig_ref = List[Int]()
        for i in range(len(tb.sig_ref_diff_offset)):
            self.sig_ref.append(Int(tb.sig_ref_diff_offset[i]))
        self.mag_ref = List[Int]()
        for i in range(len(tb.mag_ref_offset_with_tx_class)):
            self.mag_ref.append(Int(tb.mag_ref_offset_with_tx_class[i]))
        self.sgr_params = List[Int]()
        for i in range(len(tb.sgr_params)):
            self.sgr_params.append(Int(tb.sgr_params[i]))
        self.cb_ctx_off = List[Int]()
        for i in range(len(tb.coeff_base_ctx_offset)):
            self.cb_ctx_off.append(Int(tb.coeff_base_ctx_offset[i]))

        # LosslessArray, last_active_seg_id, seg_id_pre_skip (5.9.14, 7.12.2)
        self.lossless_arr = List[Bool](length=MAX_SEGMENTS, fill=False)
        self.seg_id_pre_skip = False
        self.last_active_seg_id = 0
        for s in range(MAX_SEGMENTS):
            var qi = st.frame.base_q_idx
            if st.frame.segmentation_enabled and st.frame.seg_feature_enabled[s * SEG_LVL_MAX + SEG_LVL_ALT_Q]:
                qi = clip3(0, 255, qi + st.frame.seg_feature_data[s * SEG_LVL_MAX + SEG_LVL_ALT_Q])
            self.lossless_arr[s] = (
                qi == 0 and st.frame.delta_q_y_dc == 0 and st.frame.delta_q_u_ac == 0 and st.frame.delta_q_u_dc == 0
                and st.frame.delta_q_v_ac == 0 and st.frame.delta_q_v_dc == 0
            )
            if st.frame.segmentation_enabled:
                for j in range(SEG_LVL_MAX):
                    if st.frame.seg_feature_enabled[s * SEG_LVL_MAX + j]:
                        self.last_active_seg_id = s
                        if j >= SEG_LVL_REF_FRAME:
                            self.seg_id_pre_skip = True

        var rows_alloc = self.mi_rows + PAD
        var total = rows_alloc * self.stride
        self.mi_sizes = zeros(total)
        self.y_modes = zeros(total)
        self.uv_modes = zeros(total)
        self.ref_frames = fill_ints(total * 2, -2)  # -2: not written yet in this frame
        self.is_inters = zeros(total)
        self.skip_modes = zeros(total)
        self.skips = zeros(total)
        self.tx_sizes = zeros(total)
        self.inter_tx_sizes = zeros(total)
        self.segment_ids = zeros(total)
        self.palette_sizes = zeros(total * 2)
        self.palette_colors = List[UInt16](length=total * 2 * PALETTE_COLORS, fill=0)
        self.delta_lfs = zeros(total * FRAME_LF_COUNT)
        self.mvs = zeros(total * 2)
        self.tx_types = zeros(total)
        self.lf_tx_sizes = zeros(total * 3)
        self.cdef_idx = fill_ints(total, -1)

        self.lr_unit_rows = zeros(3)
        self.lr_unit_cols = zeros(3)
        self.lr_base = zeros(3)
        var units = 0
        for p in range(self.num_planes):
            if st.frame.frame_restoration_type[p] != RESTORE_NONE:
                var sx = self.sub_x if p > 0 else 0
                var sy = self.sub_y if p > 0 else 0
                var us = st.frame.loop_restoration_size[p]
                self.lr_unit_rows[p] = count_units(us, (st.frame.height + sy) >> sy)
                self.lr_unit_cols[p] = count_units(us, (st.frame.upscaled_width + sx) >> sx)
                self.lr_base[p] = units
                units += self.lr_unit_rows[p] * self.lr_unit_cols[p]
        self.lr_type = zeros(units)
        self.lr_wiener = zeros(units * 6)
        self.lr_sgr_set = zeros(units)
        self.lr_sgr_xqd = zeros(units * 2)

        self.blocks = List[BlockInfo]()
        self.tile_stats = List[TileStats]()
        self.map_y_off = -1
        self.map_uv_off = -1
        self.map_uv_stride = 0
        self.txs = List[TxRec]()
        self.quant_pool = List[Int32]()
        self.color_maps = List[UInt8]()
        self.quant = zeros(1024)

        self.pool = self.pool0.copy()
        self.scratch = List[UInt16](length=20, fill=0)
        self.tile_index = 0
        self.mi_col_start = 0
        self.mi_col_end = 0
        self.mi_row_start = 0
        self.mi_row_end = 0
        self.stats = TileStats()
        self.above_level = zeros(3 * self.stride)
        self.above_dc = zeros(3 * self.stride)
        self.left_level = zeros(3 * rows_alloc)
        self.left_dc = zeros(3 * rows_alloc)
        self.delta_lf = zeros(FRAME_LF_COUNT)
        self.current_qindex = st.frame.base_q_idx
        self.ref_lr_wiener = zeros(3 * 2 * 3)
        self.ref_sgr_xqd = zeros(3 * 2)
        self.read_deltas = False
        self.block_decoded = List[Bool](length=3 * BDSZ * BDSZ, fill=False)

        self.mi_row = 0
        self.mi_col = 0
        self.mi_size = BLOCK_4X4
        self.has_chroma = False
        self.avail_u = False
        self.avail_l = False
        self.avail_u_chroma = False
        self.avail_l_chroma = False
        self.y_mode = DC_PRED
        self.uv_mode = DC_PRED
        self.angle_delta_y = 0
        self.angle_delta_uv = 0
        self.cfl_alpha_u = 0
        self.cfl_alpha_v = 0
        self.use_filter_intra = False
        self.filter_intra_mode = 0
        self.palette_size_y = 0
        self.palette_size_uv = 0
        self.palette_colors_y = List[Int]()
        self.palette_colors_u = List[Int]()
        self.palette_colors_v = List[Int]()
        self.color_map_y = List[UInt8]()
        self.color_map_uv = List[UInt8]()
        self.segment_id = 0
        self.lossless = False
        self.skip = False
        self.is_inter = False
        self.use_intrabc = False
        self.mv_row = 0
        self.mv_col = 0
        self.tx_size = TX_4X4
        self.ref_stack_mv = zeros(4)
        self.num_mv_found = 0
        self.sym = SymbolDecoder(Span(st.data), st.tile_offs[0], st.tile_offs[0] + max(st.tile_sizes[0], 0))
        self.start_tile(st, 0)

    def start_tile(mut self, st: Av1Stream, i: Int) raises:
        """Per-tile init of 5.11.1 / 8.2.2: bounds, symbol decoder, CDFs, contexts, CurrentQIndex."""
        var ti = st.frame.tile_info.copy()
        if i < 0 or i >= ti.cols * ti.rows or i >= len(st.tile_offs):
            raise Error("av1tile: bad tile index")
        if st.tile_offs[i] < 0 or st.tile_sizes[i] < 0 or st.tile_offs[i] + st.tile_sizes[i] > len(st.data):
            raise Error("av1tile: tile beyond data")
        self.tile_index = i
        self.mi_col_start = ti.mi_col_starts[i % ti.cols]
        self.mi_col_end = ti.mi_col_starts[(i % ti.cols) + 1]
        self.mi_row_start = ti.mi_row_starts[i // ti.cols]
        self.mi_row_end = ti.mi_row_starts[(i // ti.cols) + 1]
        self.sym = SymbolDecoder(Span(st.data), st.tile_offs[i], st.tile_offs[i] + st.tile_sizes[i])
        self.sym.disable_cdf_update = st.frame.disable_cdf_update
        self.pool = self.pool0.copy()
        self.stats = TileStats()
        self.stats.mi_total = (self.mi_col_end - self.mi_col_start) * (self.mi_row_end - self.mi_row_start)
        self.current_qindex = st.frame.base_q_idx
        for p in range(3):
            for pass_i in range(2):
                for j in range(3):
                    self.ref_lr_wiener[(p * 2 + pass_i) * 3 + j] = global_constant[WIENER_TAPS_MID]()[j]
                self.ref_sgr_xqd[p * 2 + pass_i] = global_constant[SGRPROJ_XQD_MID]()[pass_i]

    # ---- symbol reading from the pool ----
    def rd(mut self, off: Int, n: Int) raises -> Int:
        """read_symbol on the n-symbol CDF row stored at pool[off]; the row adapts in place."""
        for k in range(n + 1):
            self.scratch[k] = self.pool[off + k]
        var s = self.sym.read_symbol(self.scratch, n)
        for k in range(n + 1):
            self.pool[off + k] = self.scratch[k]
        return s

    def lit(mut self, n: Int) raises -> Int:
        return self.sym.read_literal(n)

    # ---- helpers ----
    def at(self, r: Int, c: Int) -> Int:
        return r * self.stride + c

    def is_inside(self, r: Int, c: Int) -> Bool:
        return r >= self.mi_row_start and r < self.mi_row_end and c >= self.mi_col_start and c < self.mi_col_end

    def seg_feature_active_idx(self, seg: Int, feature: Int) -> Bool:
        return self.frame.segmentation_enabled and self.frame.seg_feature_enabled[seg * SEG_LVL_MAX + feature]

    def seg_feature_active(self, feature: Int) -> Bool:
        return self.seg_feature_active_idx(self.segment_id, feature)

    def get_qindex(self, ignore_delta_q: Bool, seg: Int) -> Int:
        """7.12.2."""
        if self.seg_feature_active_idx(seg, SEG_LVL_ALT_Q):
            var data = self.frame.seg_feature_data[seg * SEG_LVL_MAX + SEG_LVL_ALT_Q]
            var qi = self.frame.base_q_idx + data
            if not ignore_delta_q and self.frame.delta_q_present:
                qi = self.current_qindex + data
            return clip3(0, 255, qi)
        if not ignore_delta_q and self.frame.delta_q_present:
            return self.current_qindex
        return self.frame.base_q_idx

    def bd(self, plane: Int, y: Int, x: Int) -> Bool:
        return self.block_decoded[plane * BDSZ * BDSZ + (y + 1) * BDSZ + (x + 1)]

    def clear_above_context(mut self):
        for i in range(len(self.above_level)):
            self.above_level[i] = 0
            self.above_dc[i] = 0

    def clear_left_context(mut self):
        for i in range(len(self.left_level)):
            self.left_level[i] = 0
            self.left_dc[i] = 0

    def clear_cdef(mut self, r: Int, c: Int):
        self.cdef_idx[self.at(r, c)] = -1
        if self.seq.use_128x128_superblock:
            self.cdef_idx[self.at(r, c + 16)] = -1
            self.cdef_idx[self.at(r + 16, c)] = -1
            self.cdef_idx[self.at(r + 16, c + 16)] = -1


comptime WIENER_TAPS_MID = [3, -7, 15]
comptime SGRPROJ_XQD_MID = [-32, 31]


def count_units(unit_size: Int, frame_size: Int) -> Int:
    return max((frame_size + (unit_size >> 1)) // unit_size, 1)
