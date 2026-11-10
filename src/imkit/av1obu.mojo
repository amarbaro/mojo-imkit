"""AV1 OBU parsing for the AVIF still-image path (stage 2, no symbol decoding).

Covers the bit reader (section 5.3), the OBU framing (section 5.3.2 / 5.3.3),
the sequence header (section 5.5), the uncompressed frame header (section 5.9)
with tile info (5.9.15), quantization (5.9.17), segmentation (5.9.18),
delta q / delta lf (5.9.19 / 5.9.20), loop filter (5.9.21), CDEF (5.9.22),
loop restoration (5.9.23), tx mode (5.9.24) and the tile group (section 5.10).

The entropy-coded tile payloads are only located, not decoded: stage 3.
Every read is bounds-checked and a truncated stream raises.
"""

comptime OBU_SEQUENCE_HEADER = 1
comptime OBU_TEMPORAL_DELIMITER = 2
comptime OBU_FRAME_HEADER = 3
comptime OBU_TILE_GROUP = 4
comptime OBU_METADATA = 5
comptime OBU_FRAME = 6
comptime OBU_REDUNDANT_FRAME_HEADER = 7
comptime OBU_PADDING = 15

comptime PRIMARY_REF_NONE = 7
comptime SELECT_SCREEN_CONTENT_TOOLS = 2
comptime SELECT_INTEGER_MV = 2
comptime NUM_REF_FRAMES = 8
comptime TOTAL_REFS_PER_FRAME = 8
comptime MAX_SEGMENTS = 8
comptime SEG_LVL_MAX = 8

comptime MAX_TILE_WIDTH = 4096
comptime MAX_TILE_AREA = 4096 * 2304
comptime MAX_TILE_COLS = 64
comptime MAX_TILE_ROWS = 64

comptime SEG_FEATURE_BITS = [8, 6, 6, 6, 6, 3, 0, 0]
comptime SEG_FEATURE_SIGNED = [True, True, True, True, True, False, False, False]
comptime RESTORATION_TILESIZE_MAX = 256
comptime REMAP_LR_TYPE = [0, 3, 1, 2]  # Remap_Lr_Type: NONE, SWITCHABLE, WIENER, SGRPROJ (RESTORE_* values 0 NONE, 1 WIENER, 2 SGRPROJ, 3 SWITCHABLE)
comptime SEG_FEATURE_MAX = [255, 63, 63, 63, 63, 7, 0, 0]  # Segmentation_Feature_Max


struct Bits(Movable):
    """MSB-first bit reader over d[start:end] (section 5.3.4 f(n), uvlc, le, su, ns)."""

    var d: List[UInt8]
    var start: Int
    var pos: Int  # next byte to load
    var end: Int
    var cur: Int  # current byte value
    var left: Int  # unread bits in cur (0..7), 0 = load on demand

    def __init__(out self, d: List[UInt8], start: Int, end: Int):
        self.d = d.copy()
        self.start = start
        self.pos = start
        self.end = end
        self.cur = 0
        self.left = 0

    def byte_pos(self) -> Int:
        if self.left == 0:
            return self.pos
        return self.pos - 1

    def bits_read(self) -> Int:
        return (self.pos - self.start) * 8 - self.left

    def f(mut self, n: Int) raises -> Int:
        """f(n): n bits, MSB first."""
        if n == 0:
            return 0
        if n < 0 or n > 32:
            raise Error("av1: bad bit count")
        var v = 0
        for _ in range(n):
            if self.left == 0:
                if self.pos >= self.end:
                    raise Error("av1: bitstream overrun")
                self.cur = Int(self.d[self.pos])
                self.pos += 1
                self.left = 8
            v = (v << 1) | ((self.cur >> (self.left - 1)) & 1)
            self.left -= 1
        return v

    def uvlc(mut self) raises -> Int:
        """uvlc(): unsigned variable length code."""
        var lz = 0
        while True:
            if lz >= 32:
                return (1 << 32) - 1
            if self.f(1) == 1:
                break
            lz += 1
        if lz == 0:
            return 0
        var v = self.f(lz)
        return v + (1 << lz) - 1

    def le(mut self, n: Int) raises -> Int:
        """le(n): n bytes, little endian (tile sizes)."""
        var v = 0
        for i in range(n):
            v |= self.f(8) << (8 * i)
        return v

    def su(mut self, n: Int) raises -> Int:
        """su(n) (section 4.10.6): n bits, two's complement, the first bit read is the sign."""
        var v = self.f(n)
        var sign_mask = 1 << (n - 1)
        if v & sign_mask != 0:
            v -= 2 * sign_mask
        return v

    def ns(mut self, n: Int) raises -> Int:
        """ns(n): non-symmetric unsigned value in [0, n)."""
        if n <= 0:
            return 0
        var w = 0
        while (1 << (w + 1)) <= n:
            w += 1
        var m = (1 << (w + 1)) - n
        var v = self.f(w)
        if v < m:
            return v
        var extra = self.f(1)
        return (v << 1) - m + extra

    def leb128(mut self) raises -> Int:
        """leb128(): OBU size field."""
        var v = 0
        var shift = 0
        while True:
            var b = self.f(8)
            v |= (b & 127) << shift
            if (b & 128) == 0:
                break
            shift += 7
            if shift > 56:
                raise Error("av1: bad leb128 size")
        return v

    def align(mut self):
        """byte_alignment(): drop the remaining bits of the current byte."""
        while self.left != 0:
            self.left -= 1

    def trailing_bits(mut self) raises:
        """trailing_bits(): a one bit, then zeros to the byte boundary."""
        if self.f(1) != 1:
            raise Error("av1: bad trailing bits")
        while self.left != 0:
            if self.f(1) != 0:
                raise Error("av1: bad trailing bits")


@fieldwise_init
struct TileInfo(Copyable, Movable):
    """Tile grid layout (section 5.9.15)."""

    var uniform: Bool
    var cols_log2: Int
    var rows_log2: Int
    var cols: Int
    var rows: Int
    var context_update_tile_id: Int
    var tile_size_bytes: Int
    var mi_col_starts: List[Int]  # MiColStarts, cols + 1 entries, the last one MiCols
    var mi_row_starts: List[Int]  # MiRowStarts, rows + 1 entries, the last one MiRows

    def __init__(out self):
        self.uniform = True
        self.cols_log2 = 0
        self.rows_log2 = 0
        self.cols = 1
        self.rows = 1
        self.context_update_tile_id = 0
        self.tile_size_bytes = 0
        self.mi_col_starts = List[Int]()
        self.mi_row_starts = List[Int]()


struct SequenceHeader(Copyable, Movable):
    """sequence_header_obu() (section 5.5) with color_config() (5.5.2)."""

    var profile: Int
    var still_picture: Bool
    var reduced_still_picture_header: Bool
    var timing_info_present_flag: Bool
    var equal_picture_interval: Bool
    var decoder_model_info_present_flag: Bool
    var buffer_removal_time_length: Int
    var frame_presentation_time_length: Int
    var initial_display_delay_present_flag: Bool
    var num_operating_points: Int
    var dec_model_present: List[Bool]
    var frame_width_bits: Int
    var frame_height_bits: Int
    var max_frame_width: Int
    var max_frame_height: Int
    var frame_id_numbers_present_flag: Bool
    var delta_frame_id_length_minus_2: Int
    var additional_frame_id_length_minus_1: Int
    var use_128x128_superblock: Bool
    var enable_filter_intra: Bool
    var enable_intra_edge_filter: Bool
    var enable_order_hint: Bool
    var enable_jnt_comp: Bool
    var enable_ref_frame_mvs: Bool
    var seq_force_screen_content_tools: Int
    var seq_force_integer_mv: Int
    var order_hint_bits: Int
    var enable_superres: Bool
    var enable_cdef: Bool
    var enable_restoration: Bool
    var high_bitdepth: Bool
    var twelve_bit: Bool
    var bit_depth: Int
    var mono_chrome: Bool
    var num_planes: Int
    var color_description_present: Bool
    var color_primaries: Int
    var transfer_characteristics: Int
    var matrix_coefficients: Int
    var color_range: Bool
    var subsampling_x: Bool
    var subsampling_y: Bool
    var chroma_sample_position: Int
    var separate_uv_delta_q: Bool
    var film_grain_params_present: Bool

    def __init__(out self):
        self.profile = 0
        self.still_picture = False
        self.reduced_still_picture_header = False
        self.timing_info_present_flag = False
        self.equal_picture_interval = False
        self.decoder_model_info_present_flag = False
        self.buffer_removal_time_length = 0
        self.frame_presentation_time_length = 0
        self.initial_display_delay_present_flag = False
        self.num_operating_points = 1
        self.dec_model_present = List[Bool]()
        self.frame_width_bits = 1
        self.frame_height_bits = 1
        self.max_frame_width = 1
        self.max_frame_height = 1
        self.frame_id_numbers_present_flag = False
        self.delta_frame_id_length_minus_2 = 0
        self.additional_frame_id_length_minus_1 = 0
        self.use_128x128_superblock = False
        self.enable_filter_intra = False
        self.enable_intra_edge_filter = False
        self.enable_order_hint = False
        self.enable_jnt_comp = False
        self.enable_ref_frame_mvs = False
        self.seq_force_screen_content_tools = 0
        self.seq_force_integer_mv = 0
        self.order_hint_bits = 0
        self.enable_superres = False
        self.enable_cdef = False
        self.enable_restoration = False
        self.high_bitdepth = False
        self.twelve_bit = False
        self.bit_depth = 8
        self.mono_chrome = False
        self.num_planes = 3
        self.color_description_present = False
        self.color_primaries = 2
        self.transfer_characteristics = 2
        self.matrix_coefficients = 2
        self.color_range = False
        self.subsampling_x = True
        self.subsampling_y = True
        self.chroma_sample_position = 0
        self.separate_uv_delta_q = False
        self.film_grain_params_present = False


struct FrameHeader(Copyable, Movable):
    """uncompressed_header() (section 5.9.2) for an intra still picture."""

    var frame_type: Int
    var show_frame: Bool
    var error_resilient: Bool
    var disable_cdf_update: Bool
    var disable_frame_end_update_cdf: Bool
    var allow_screen_content_tools: Bool
    var allow_intrabc: Bool
    var width: Int
    var height: Int
    var upscaled_width: Int
    var superres_denom: Int  # SuperresDenom, SUPERRES_NUM (8) without superres
    var render_width: Int
    var render_height: Int
    var base_q_idx: Int
    var delta_q_y_dc: Int
    var delta_q_u_dc: Int
    var delta_q_u_ac: Int
    var delta_q_v_dc: Int
    var delta_q_v_ac: Int
    var diff_uv_delta: Bool
    var using_qmatrix: Bool
    var qm_y: Int
    var qm_u: Int
    var qm_v: Int
    var coded_lossless: Bool
    var all_lossless: Bool
    var segmentation_enabled: Bool
    var seg_feature_enabled: List[Bool]
    var seg_feature_data: List[Int]
    var delta_q_present: Bool
    var delta_q_res: Int
    var delta_lf_present: Bool
    var delta_lf_res: Int
    var delta_lf_multi: Bool
    var loop_filter_level0: Int
    var loop_filter_level2: Int  # U
    var loop_filter_level3: Int  # V
    var loop_filter_delta_enabled: Bool
    var loop_filter_ref_deltas: List[Int]  # 8, spec defaults 1 0 0 0 -1 0 -1 -1
    var loop_filter_mode_deltas: List[Int]  # 2
    var cdef_y_pri_strength: List[Int]  # 8 entries
    var cdef_y_sec_strength: List[Int]  # secondary 3 already turned into 4
    var cdef_uv_pri_strength: List[Int]
    var cdef_uv_sec_strength: List[Int]
    var film_grain_pos: Int  # absolute bit position of the apply_grain bit when it was 1, else -1
    var loop_filter_level1: Int
    var loop_filter_sharpness: Int
    var cdef_damping: Int
    var cdef_bits: Int
    var frame_restoration_type: List[Int]
    var uses_lr: Bool
    var loop_restoration_size: List[Int]  # LoopRestorationSize per plane
    var tx_mode_select: Bool
    var reduced_tx_set: Bool
    var apply_grain: Bool
    var tile_info: TileInfo

    def __init__(out self):
        self.frame_type = 0
        self.show_frame = False
        self.error_resilient = False
        self.disable_cdf_update = False
        self.disable_frame_end_update_cdf = False
        self.allow_screen_content_tools = False
        self.allow_intrabc = False
        self.width = 0
        self.height = 0
        self.upscaled_width = 0
        self.superres_denom = 8
        self.render_width = 0
        self.render_height = 0
        self.base_q_idx = 0
        self.delta_q_y_dc = 0
        self.delta_q_u_dc = 0
        self.delta_q_u_ac = 0
        self.delta_q_v_dc = 0
        self.delta_q_v_ac = 0
        self.diff_uv_delta = False
        self.using_qmatrix = False
        self.qm_y = 0
        self.qm_u = 0
        self.qm_v = 0
        self.coded_lossless = False
        self.all_lossless = False
        self.segmentation_enabled = False
        self.seg_feature_enabled = List[Bool](length=64, fill=False)
        self.seg_feature_data = List[Int](length=64, fill=0)
        self.delta_q_present = False
        self.delta_q_res = 0
        self.delta_lf_present = False
        self.delta_lf_res = 0
        self.delta_lf_multi = False
        self.loop_filter_level0 = 0
        self.loop_filter_level2 = 0
        self.loop_filter_level3 = 0
        self.loop_filter_delta_enabled = False
        self.loop_filter_ref_deltas = [1, 0, 0, 0, -1, 0, -1, -1]
        self.loop_filter_mode_deltas = List[Int](length=2, fill=0)
        self.cdef_y_pri_strength = List[Int](length=8, fill=0)
        self.cdef_y_sec_strength = List[Int](length=8, fill=0)
        self.cdef_uv_pri_strength = List[Int](length=8, fill=0)
        self.cdef_uv_sec_strength = List[Int](length=8, fill=0)
        self.film_grain_pos = -1
        self.loop_filter_level1 = 0
        self.loop_filter_sharpness = 0
        self.cdef_damping = 3
        self.cdef_bits = 0
        self.frame_restoration_type = List[Int](length=3, fill=0)
        self.uses_lr = False
        self.loop_restoration_size = [256, 256, 256]
        self.tx_mode_select = False
        self.reduced_tx_set = False
        self.apply_grain = False
        self.tile_info = TileInfo()


struct Av1Stream(Movable):
    """The parsed headers, the item's bytes and each tile's byte range inside them."""

    var seq: SequenceHeader
    var frame: FrameHeader
    var data: List[UInt8]
    var tile_offs: List[Int]
    var tile_sizes: List[Int]

    def __init__(out self):
        self.seq = SequenceHeader()
        self.frame = FrameHeader()
        self.data = List[UInt8]()
        self.tile_offs = List[Int]()
        self.tile_sizes = List[Int]()


# ---- 5.5 sequence header ----

def parse_color_config(mut b: Bits, mut s: SequenceHeader) raises:
    """color_config() (section 5.5.2)."""
    s.high_bitdepth = b.f(1) == 1
    if s.profile == 2 and s.high_bitdepth:
        s.twelve_bit = b.f(1) == 1
        if s.twelve_bit:
            s.bit_depth = 12
        else:
            s.bit_depth = 10
    else:
        if s.high_bitdepth:
            s.bit_depth = 10
        else:
            s.bit_depth = 8
    s.mono_chrome = False
    if s.profile != 1:
        s.mono_chrome = b.f(1) == 1
    if s.mono_chrome:
        s.num_planes = 1
    else:
        s.num_planes = 3
    if b.f(1) == 1:
        s.color_description_present = True
        s.color_primaries = b.f(8)
        s.transfer_characteristics = b.f(8)
        s.matrix_coefficients = b.f(8)
    if s.mono_chrome:
        s.color_range = b.f(1) == 1
        s.subsampling_x = True
        s.subsampling_y = True
        s.separate_uv_delta_q = False
        return
    if s.color_primaries == 1 and s.transfer_characteristics == 13 and s.matrix_coefficients == 0:
        s.color_range = True
        s.subsampling_x = False
        s.subsampling_y = False
    else:
        s.color_range = b.f(1) == 1
        if s.profile == 0:
            s.subsampling_x = True
            s.subsampling_y = True
        elif s.profile == 1:
            s.subsampling_x = False
            s.subsampling_y = False
        else:
            if s.bit_depth == 12:
                s.subsampling_x = b.f(1) == 1
                if s.subsampling_x:
                    s.subsampling_y = b.f(1) == 1
                else:
                    s.subsampling_y = False
            else:
                s.subsampling_x = True
                s.subsampling_y = False
        if s.subsampling_x and s.subsampling_y:
            s.chroma_sample_position = b.f(2)
    s.separate_uv_delta_q = b.f(1) == 1


def parse_sequence_header(mut b: Bits) raises -> SequenceHeader:
    """sequence_header_obu() (section 5.5.1), timing and decoder model skipped by size."""
    var s = SequenceHeader()
    s.profile = b.f(3)
    if s.profile > 2:
        raise Error("av1: reserved seq_profile")
    s.still_picture = b.f(1) == 1
    s.reduced_still_picture_header = b.f(1) == 1
    if s.reduced_still_picture_header and not s.still_picture:
        raise Error("av1: reduced still picture header without still_picture")
    if s.reduced_still_picture_header:
        s.num_operating_points = 1
        s.dec_model_present.append(False)
        _ = b.f(5)  # seq_level_idx
    else:
        s.timing_info_present_flag = b.f(1) == 1
        if s.timing_info_present_flag:
            _ = b.f(32)  # num_units_in_display_tick
            _ = b.f(32)  # time_scale
            s.equal_picture_interval = b.f(1) == 1
            if s.equal_picture_interval:
                _ = b.uvlc()  # num_ticks_per_picture_minus_1
            s.decoder_model_info_present_flag = b.f(1) == 1
            if s.decoder_model_info_present_flag:
                var buffer_delay_length = b.f(5) + 1
                _ = b.f(32)  # num_units_in_decoding_tick
                s.buffer_removal_time_length = b.f(5) + 1
                s.frame_presentation_time_length = b.f(5) + 1
                # operating_parameters_info() is read per operating point below
                s.buffer_removal_time_length = s.buffer_removal_time_length
                _ = buffer_delay_length
        s.initial_display_delay_present_flag = b.f(1) == 1
        s.num_operating_points = b.f(5) + 1
        for _ in range(s.num_operating_points):
            _ = b.f(12)  # operating_point_idc
            var level = b.f(5)
            if level > 7:
                _ = b.f(1)  # seq_tier
            var has_model = False
            if s.decoder_model_info_present_flag:
                has_model = b.f(1) == 1
                if has_model:
                    _ = b.f(s.buffer_removal_time_length - 1)  # decoder_buffer_delay
                    _ = b.f(s.buffer_removal_time_length - 1)  # encoder_buffer_delay
                    _ = b.f(1)  # low_delay_mode_flag
            s.dec_model_present.append(has_model)
            if s.initial_display_delay_present_flag:
                if b.f(1) == 1:
                    _ = b.f(4)  # initial_display_delay_minus_1
    s.frame_width_bits = b.f(4) + 1
    s.frame_height_bits = b.f(4) + 1
    s.max_frame_width = b.f(s.frame_width_bits) + 1
    s.max_frame_height = b.f(s.frame_height_bits) + 1
    if s.reduced_still_picture_header:
        s.frame_id_numbers_present_flag = False
    else:
        s.frame_id_numbers_present_flag = b.f(1) == 1
    if s.frame_id_numbers_present_flag:
        s.delta_frame_id_length_minus_2 = b.f(4)
        s.additional_frame_id_length_minus_1 = b.f(3)
    s.use_128x128_superblock = b.f(1) == 1
    s.enable_filter_intra = b.f(1) == 1
    s.enable_intra_edge_filter = b.f(1) == 1
    if s.reduced_still_picture_header:
        s.seq_force_screen_content_tools = SELECT_SCREEN_CONTENT_TOOLS
        s.seq_force_integer_mv = SELECT_INTEGER_MV
        s.order_hint_bits = 0
    else:
        _ = b.f(1)  # enable_interintra_compound
        _ = b.f(1)  # enable_masked_compound
        _ = b.f(1)  # enable_warped_motion
        _ = b.f(1)  # enable_dual_filter
        s.enable_order_hint = b.f(1) == 1
        if s.enable_order_hint:
            s.enable_jnt_comp = b.f(1) == 1
            s.enable_ref_frame_mvs = b.f(1) == 1
        if b.f(1) == 1:  # seq_choose_screen_content_tools
            s.seq_force_screen_content_tools = SELECT_SCREEN_CONTENT_TOOLS
        else:
            s.seq_force_screen_content_tools = b.f(1)
        if s.seq_force_screen_content_tools > 0:
            if b.f(1) == 1:  # seq_choose_integer_mv
                s.seq_force_integer_mv = SELECT_INTEGER_MV
            else:
                s.seq_force_integer_mv = b.f(1)
        else:
            s.seq_force_integer_mv = SELECT_INTEGER_MV
        if s.enable_order_hint:
            s.order_hint_bits = b.f(3) + 1
        else:
            s.order_hint_bits = 0
    s.enable_superres = b.f(1) == 1
    s.enable_cdef = b.f(1) == 1
    s.enable_restoration = b.f(1) == 1
    parse_color_config(b, s)
    s.film_grain_params_present = b.f(1) == 1
    return s^


# ---- 5.9.15 tile info ----

def tile_log2(blk: Int, target: Int) -> Int:
    """tile_log2() (section 5.9.16): smallest k with blk << k >= target."""
    var k = 0
    while (blk << k) < target:
        k += 1
    return k


def parse_tile_info(mut b: Bits, seq: SequenceHeader, width: Int, height: Int) raises -> TileInfo:
    """tile_info() (section 5.9.15), uniform and explicit spacing."""
    var ti = TileInfo()
    var mi_cols = 2 * ((width + 7) >> 3)
    var mi_rows = 2 * ((height + 7) >> 3)
    var sb_shift = 4
    if seq.use_128x128_superblock:
        sb_shift = 5
    var sb_size = sb_shift + 2
    var sb_cols = (mi_cols + (1 << sb_shift) - 1) >> sb_shift
    var sb_rows = (mi_rows + (1 << sb_shift) - 1) >> sb_shift
    var max_tile_width_sb = MAX_TILE_WIDTH >> sb_size
    var max_tile_area_sb = MAX_TILE_AREA >> (2 * sb_size)
    var min_log2_cols = tile_log2(max_tile_width_sb, sb_cols)
    var max_log2_cols = tile_log2(1, min(sb_cols, MAX_TILE_COLS))
    var max_log2_rows = tile_log2(1, min(sb_rows, MAX_TILE_ROWS))
    var min_log2_tiles = max(min_log2_cols, tile_log2(max_tile_area_sb, sb_rows * sb_cols))
    ti.uniform = b.f(1) == 1
    if ti.uniform:
        ti.cols_log2 = min_log2_cols
        while ti.cols_log2 < max_log2_cols:
            if b.f(1) == 0:
                break
            ti.cols_log2 += 1
        var tile_width_sb = (sb_cols + (1 << ti.cols_log2) - 1) >> ti.cols_log2
        var cols = 0
        var start = 0
        while start < sb_cols:
            ti.mi_col_starts.append(start << sb_shift)
            cols += 1
            start += tile_width_sb
        ti.cols = cols
        var min_log2_rows = max(min_log2_tiles - tile_log2(sb_cols, tile_width_sb), 0)
        ti.rows_log2 = min_log2_rows
        while ti.rows_log2 < max_log2_rows:
            if b.f(1) == 0:
                break
            ti.rows_log2 += 1
        var tile_height_sb = (sb_rows + (1 << ti.rows_log2) - 1) >> ti.rows_log2
        var rows = 0
        start = 0
        while start < sb_rows:
            ti.mi_row_starts.append(start << sb_shift)
            rows += 1
            start += tile_height_sb
        ti.rows = rows
    else:
        ti.cols_log2 = 0
        var start = 0
        var widest = 0
        var cols = 0
        for _ in range(MAX_TILE_COLS):
            if start >= sb_cols:
                break
            var max_w = min(sb_cols - start, max_tile_width_sb)
            ti.mi_col_starts.append(start << sb_shift)
            var size_sb = b.ns(max_w) + 1
            widest = max(widest, size_sb)
            start += size_sb
            cols += 1
        if cols == 0:
            raise Error("av1: empty tile column layout")
        ti.cols = cols
        ti.cols_log2 = tile_log2(1, cols)
        var area_sb = sb_rows * sb_cols
        if min_log2_tiles > 0:
            area_sb = (sb_rows * sb_cols) >> (min_log2_tiles + 1)
        var max_h_sb = max(area_sb / widest, 1)
        start = 0
        var rows = 0
        for _ in range(MAX_TILE_ROWS):
            if start >= sb_rows:
                break
            var max_h = min(sb_rows - start, max_h_sb)
            ti.mi_row_starts.append(start << sb_shift)
            var size_sb = b.ns(max_h) + 1
            start += size_sb
            rows += 1
        if rows == 0:
            raise Error("av1: empty tile row layout")
        ti.rows = rows
        ti.rows_log2 = tile_log2(1, rows)
    ti.mi_col_starts.append(mi_cols)
    ti.mi_row_starts.append(mi_rows)
    if ti.cols_log2 > 0 or ti.rows_log2 > 0:
        ti.context_update_tile_id = b.f(ti.rows_log2 + ti.cols_log2)
        ti.tile_size_bytes = b.f(2) + 1
    if ti.cols * ti.rows > MAX_TILE_COLS * MAX_TILE_ROWS:
        raise Error("av1: too many tiles")
    return ti^


# ---- 5.9.17 .. 5.9.24 frame header sub-structures ----

def read_delta_q(mut b: Bits) raises -> Int:
    """read_delta_q() (section 5.9.17)."""
    if b.f(1) == 1:
        return b.su(7)
    return 0


def parse_quantization(mut b: Bits, mut fh: FrameHeader, seq: SequenceHeader) raises:
    """quantization_params() (section 5.9.17)."""
    fh.base_q_idx = b.f(8)
    fh.delta_q_y_dc = read_delta_q(b)
    if seq.num_planes > 1:
        if seq.separate_uv_delta_q:
            fh.diff_uv_delta = b.f(1) == 1
        fh.delta_q_u_dc = read_delta_q(b)
        fh.delta_q_u_ac = read_delta_q(b)
        if fh.diff_uv_delta:
            fh.delta_q_v_dc = read_delta_q(b)
            fh.delta_q_v_ac = read_delta_q(b)
        else:
            fh.delta_q_v_dc = fh.delta_q_u_dc
            fh.delta_q_v_ac = fh.delta_q_u_ac
    if b.f(1) == 1:
        fh.using_qmatrix = True
        fh.qm_y = b.f(4)
        fh.qm_u = b.f(4)
        if seq.separate_uv_delta_q:
            fh.qm_v = b.f(4)
        else:
            fh.qm_v = fh.qm_u
    fh.coded_lossless = fh.base_q_idx == 0 and fh.delta_q_y_dc == 0 and fh.delta_q_u_dc == 0 and fh.delta_q_u_ac == 0 and fh.delta_q_v_dc == 0 and fh.delta_q_v_ac == 0


def parse_segmentation(mut b: Bits, mut fh: FrameHeader, primary_ref_frame: Int) raises:
    """segmentation_params() (section 5.9.18)."""
    fh.segmentation_enabled = b.f(1) == 1
    if not fh.segmentation_enabled:
        return
    if primary_ref_frame != PRIMARY_REF_NONE:
        var update_map = b.f(1) == 1
        if update_map:
            _ = b.f(1)  # segmentation_temporal_update
    var update_data = True
    if primary_ref_frame != PRIMARY_REF_NONE:
        update_data = b.f(1) == 1
    if update_data:
        for i in range(MAX_SEGMENTS):
            for j in range(SEG_LVL_MAX):
                var enabled = b.f(1) == 1
                fh.seg_feature_enabled[i * SEG_LVL_MAX + j] = enabled
                if enabled:
                    var bits = materialize[SEG_FEATURE_BITS]()[j]
                    var limit = materialize[SEG_FEATURE_MAX]()[j]
                    var v: Int
                    if materialize[SEG_FEATURE_SIGNED]()[j]:
                        v = max(-limit, min(limit, b.su(1 + bits)))
                    else:
                        v = min(limit, b.f(bits))
                    fh.seg_feature_data[i * SEG_LVL_MAX + j] = v


def parse_delta_q_params(mut b: Bits, mut fh: FrameHeader) raises:
    """delta_q_params() (section 5.9.19)."""
    if fh.base_q_idx > 0:
        fh.delta_q_present = b.f(1) == 1
    if fh.delta_q_present:
        fh.delta_q_res = b.f(2)


def parse_delta_lf_params(mut b: Bits, mut fh: FrameHeader) raises:
    """delta_lf_params() (section 5.9.20)."""
    if fh.delta_q_present:
        if not fh.allow_intrabc:
            fh.delta_lf_present = b.f(1) == 1
        if fh.delta_lf_present:
            fh.delta_lf_res = b.f(2)
            fh.delta_lf_multi = b.f(1) == 1


def parse_loop_filter(mut b: Bits, mut fh: FrameHeader, seq: SequenceHeader) raises:
    """loop_filter_params() (section 5.9.21)."""
    if fh.coded_lossless or fh.allow_intrabc:
        return
    fh.loop_filter_level0 = b.f(6)
    fh.loop_filter_level1 = b.f(6)
    if seq.num_planes > 1:
        if fh.loop_filter_level0 != 0 or fh.loop_filter_level1 != 0:
            fh.loop_filter_level2 = b.f(6)
            fh.loop_filter_level3 = b.f(6)
    fh.loop_filter_sharpness = b.f(3)
    fh.loop_filter_delta_enabled = b.f(1) == 1
    if fh.loop_filter_delta_enabled:
        if b.f(1) == 1:  # loop_filter_delta_update
            for i in range(TOTAL_REFS_PER_FRAME):
                if b.f(1) == 1:
                    fh.loop_filter_ref_deltas[i] = b.su(7)
            for i in range(2):
                if b.f(1) == 1:
                    fh.loop_filter_mode_deltas[i] = b.su(7)


def parse_cdef(mut b: Bits, mut fh: FrameHeader, seq: SequenceHeader) raises:
    """cdef_params() (section 5.9.22)."""
    if fh.coded_lossless or fh.allow_intrabc or not seq.enable_cdef:
        return
    fh.cdef_damping = b.f(2) + 3
    fh.cdef_bits = b.f(2)
    for i in range(1 << fh.cdef_bits):
        fh.cdef_y_pri_strength[i] = b.f(4)
        var ys = b.f(2)
        if ys == 3:
            ys += 1
        fh.cdef_y_sec_strength[i] = ys
        if seq.num_planes > 1:
            fh.cdef_uv_pri_strength[i] = b.f(4)
            var us = b.f(2)
            if us == 3:
                us += 1
            fh.cdef_uv_sec_strength[i] = us


def parse_lr(mut b: Bits, mut fh: FrameHeader, seq: SequenceHeader) raises:
    """lr_params() (section 5.9.23)."""
    if fh.all_lossless or fh.allow_intrabc or not seq.enable_restoration:
        return
    var uses = False
    var uses_chroma = False
    for i in range(seq.num_planes):
        var lr_type = b.f(2)
        fh.frame_restoration_type[i] = materialize[REMAP_LR_TYPE]()[lr_type]  # FrameRestorationType
        if lr_type != 0:
            uses = True
            if i > 0:
                uses_chroma = True
    fh.uses_lr = uses
    if uses:
        var shift: Int
        if seq.use_128x128_superblock:
            shift = b.f(1) + 1  # lr_unit_shift, then ++
        else:
            shift = b.f(1)  # lr_unit_shift
            if shift == 1:
                shift += b.f(1)  # lr_unit_extra_shift
        var uv_shift = 0
        if seq.subsampling_x and seq.subsampling_y and uses_chroma:
            uv_shift = b.f(1)  # lr_uv_shift
        fh.loop_restoration_size[0] = RESTORATION_TILESIZE_MAX >> (2 - shift)
        fh.loop_restoration_size[1] = fh.loop_restoration_size[0] >> uv_shift
        fh.loop_restoration_size[2] = fh.loop_restoration_size[0] >> uv_shift


def parse_film_grain(mut b: Bits, mut fh: FrameHeader, seq: SequenceHeader) raises:
    """film_grain_params() (section 5.9.30), values consumed but not kept."""
    if not seq.film_grain_params_present:
        return
    var gpos = b.start * 8 + b.bits_read()
    if b.f(1) == 0:
        return
    fh.apply_grain = True
    fh.film_grain_pos = gpos
    _ = b.f(16)  # grain_seed
    # frame_type is KEY_FRAME: update_grain is 1 without a bit
    var num_y = b.f(4)
    for _ in range(num_y):
        _ = b.f(8)  # point_y_value
        _ = b.f(8)  # point_y_scaling
    var chroma_from_luma = False
    if seq.num_planes > 1:
        chroma_from_luma = b.f(1) == 1
    var num_cb = 0
    var num_cr = 0
    var skip_chroma = seq.num_planes > 1 and (chroma_from_luma or (seq.subsampling_x and seq.subsampling_y and num_y == 0))
    if not skip_chroma:
        num_cb = b.f(4)
        for _ in range(num_cb):
            _ = b.f(8)
            _ = b.f(8)
        num_cr = b.f(4)
        for _ in range(num_cr):
            _ = b.f(8)
            _ = b.f(8)
    _ = b.f(2)  # grain_scaling_minus_8
    var ar_lag = b.f(2)
    var num_pos_luma = 2 * ar_lag * (ar_lag + 1)
    var num_pos_chroma = num_pos_luma + 1
    if num_y > 0:
        for _ in range(num_pos_luma):
            _ = b.f(8)
    if chroma_from_luma or num_cb > 0:
        for _ in range(num_pos_chroma):
            _ = b.f(8)
    if chroma_from_luma or num_cr > 0:
        for _ in range(num_pos_chroma):
            _ = b.f(8)
    _ = b.f(2)  # ar_coeff_shift_minus_6
    _ = b.f(2)  # grain_scale_shift
    if num_cb > 0:
        _ = b.f(8)
        _ = b.f(8)
        _ = b.f(9)
    if num_cr > 0:
        _ = b.f(8)
        _ = b.f(8)
        _ = b.f(9)
    _ = b.f(1)  # overlap_flag
    _ = b.f(1)  # clip_to_restricted_range


def parse_frame_header(mut b: Bits, seq: SequenceHeader) raises -> FrameHeader:
    """uncompressed_header() (section 5.9.2) for a KEY_FRAME or INTRA_ONLY frame."""
    var fh = FrameHeader()
    var id_len = 0
    if seq.frame_id_numbers_present_flag:
        id_len = seq.delta_frame_id_length_minus_2 + seq.additional_frame_id_length_minus_1 + 3
    if seq.reduced_still_picture_header:  # 5.9.2: nothing of this is coded, a shown key frame is implied
        fh.frame_type = 0
        fh.show_frame = True
    else:
        if b.f(1) == 1:  # show_existing_frame
            _ = b.f(3)  # frame_to_show_map_idx
            raise Error("av1: show_existing_frame is not a still image")
        fh.frame_type = b.f(2)
        if fh.frame_type == 1 or fh.frame_type == 3:
            raise Error("av1: inter or switch frame in an AVIF still image")
        fh.show_frame = b.f(1) == 1
        if fh.show_frame and seq.decoder_model_info_present_flag and not seq.equal_picture_interval:
            _ = b.f(seq.frame_presentation_time_length)  # temporal_point_info()
        if not fh.show_frame:
            _ = b.f(1)  # showable_frame
    if fh.frame_type == 0 and fh.show_frame:
        fh.error_resilient = True
    else:
        fh.error_resilient = b.f(1) == 1
    fh.disable_cdf_update = b.f(1) == 1
    if seq.seq_force_screen_content_tools == SELECT_SCREEN_CONTENT_TOOLS:
        fh.allow_screen_content_tools = b.f(1) == 1
    else:
        fh.allow_screen_content_tools = seq.seq_force_screen_content_tools == 1
    var force_integer_mv = False
    if fh.allow_screen_content_tools:
        if seq.seq_force_integer_mv == SELECT_INTEGER_MV:
            force_integer_mv = b.f(1) == 1
        else:
            force_integer_mv = seq.seq_force_integer_mv == 1
    if seq.frame_id_numbers_present_flag:
        _ = b.f(id_len)  # current_frame_id
    var frame_size_override = False
    if seq.reduced_still_picture_header:
        frame_size_override = False
    else:
        frame_size_override = b.f(1) == 1
    if seq.enable_order_hint:
        _ = b.f(seq.order_hint_bits)  # order_hint
    var primary_ref_frame = PRIMARY_REF_NONE
    if not fh.error_resilient:
        primary_ref_frame = b.f(3)
    if seq.decoder_model_info_present_flag:
        for i in range(seq.num_operating_points):
            if seq.dec_model_present[i]:
                _ = b.f(seq.buffer_removal_time_length)
    if fh.frame_type == 2:
        _ = b.f(8)  # refresh_frame_flags of an intra-only frame
    else:
        if not fh.show_frame:
            _ = b.f(8)  # refresh_frame_flags of a hidden key frame
    if frame_size_override:
        fh.width = b.f(seq.frame_width_bits) + 1
        fh.height = b.f(seq.frame_height_bits) + 1
    else:
        fh.width = seq.max_frame_width
        fh.height = seq.max_frame_height
    if fh.width > seq.max_frame_width or fh.height > seq.max_frame_height:
        raise Error("av1: frame larger than the sequence header maximum")
    fh.upscaled_width = fh.width
    if seq.enable_superres:
        if b.f(1) == 1:  # use_superres
            var denom = b.f(3) + 9  # coded_denom + SUPERRES_DENOM_MIN
            fh.superres_denom = denom
            fh.width = (fh.upscaled_width * 8 + (denom >> 1)) // denom
    if b.f(1) == 1:  # render_and_frame_size_different
        fh.render_width = b.f(16) + 1
        fh.render_height = b.f(16) + 1
    else:
        fh.render_width = fh.upscaled_width
        fh.render_height = fh.height
    if fh.allow_screen_content_tools and fh.upscaled_width == fh.width:
        fh.allow_intrabc = b.f(1) == 1
    if seq.reduced_still_picture_header or fh.disable_cdf_update:
        fh.disable_frame_end_update_cdf = True
    else:
        fh.disable_frame_end_update_cdf = b.f(1) == 1
    fh.tile_info = parse_tile_info(b, seq, fh.width, fh.height)
    parse_quantization(b, fh, seq)
    parse_segmentation(b, fh, primary_ref_frame)
    fh.all_lossless = fh.coded_lossless and not fh.segmentation_enabled
    parse_delta_q_params(b, fh)
    parse_delta_lf_params(b, fh)
    parse_loop_filter(b, fh, seq)
    parse_cdef(b, fh, seq)
    parse_lr(b, fh, seq)
    if not fh.coded_lossless:  # read_tx_mode()
        fh.tx_mode_select = b.f(1) == 1
    fh.reduced_tx_set = b.f(1) == 1
    # frame_reference_mode(), skip_mode_params() and global_motion_params()
    # read nothing for an intra frame (sections 5.9.26 .. 5.9.28).
    parse_film_grain(b, fh, seq)
    return fh^


# ---- 5.10 tile group ----

def parse_tile_group(mut b: Bits, ti: TileInfo, mut offs: List[Int]) raises -> List[Int]:
    """tile_group_obu() (section 5.10): locate each tile's byte range (start offsets appended to offs), no symbol decoding."""
    var num_tiles = ti.cols * ti.rows
    if num_tiles < 1:
        raise Error("av1: tile group without tiles")
    var tg_start = 0
    var tg_end = num_tiles - 1
    if num_tiles > 1:
        if b.f(1) == 1:  # tile_start_and_end_present_flag
            var bits = ti.cols_log2 + ti.rows_log2
            tg_start = b.f(bits)
            tg_end = b.f(bits)
    if tg_end < tg_start or tg_end >= num_tiles:
        raise Error("av1: bad tile group range")
    b.align()
    var sizes = List[Int]()
    for tile_num in range(tg_start, tg_end + 1):
        var size = 0
        if tile_num != tg_end:  # the last tile has no size field: it runs to the end of the OBU
            if ti.tile_size_bytes < 1:
                raise Error("av1: tile size field missing")
            size = b.le(ti.tile_size_bytes) + 1
        else:
            size = b.end - b.byte_pos()
        if size < 0 or b.byte_pos() + size > b.end:
            raise Error("av1: tile data overruns the tile group")
        sizes.append(size)
        offs.append(b.byte_pos())
        b.pos = b.byte_pos() + size
        b.left = 0
    return sizes^


# ---- OBU walk (section 5.3) ----

def parse_av1(d: Span[UInt8, _]) raises -> Av1Stream:
    """Walk the OBUs of an AVIF primary item and parse the sequence / frame headers."""
    var buf = List[UInt8]()
    buf.extend(d)
    var n = len(buf)
    var out = Av1Stream()
    var have_seq = False
    var have_frame = False
    var pos = 0
    while pos < n:
        var b = Bits(buf, pos, n)
        if b.f(1) != 0:
            raise Error("av1: OBU forbidden bit is set")
        var typ = b.f(4)
        var has_ext = b.f(1) == 1
        var has_size = b.f(1) == 1
        _ = b.f(1)  # obu_reserved_1bit
        if has_ext:
            _ = b.f(3)  # temporal_id
            _ = b.f(2)  # spatial_id
            _ = b.f(3)  # reserved
        var size = n - b.byte_pos()
        if has_size:
            size = b.leb128()
        var ps = b.byte_pos()
        if size < 0 or ps + size > n:
            raise Error("av1: OBU payload overruns the item data")
        var pe = ps + size
        if typ == OBU_SEQUENCE_HEADER:
            var pb = Bits(buf, ps, pe)
            out.seq = parse_sequence_header(pb)
            have_seq = True
        elif typ == OBU_FRAME:
            if not have_seq:
                raise Error("av1: frame OBU before the sequence header")
            var pb = Bits(buf, ps, pe)
            out.frame = parse_frame_header(pb, out.seq)
            have_frame = True
            pb.align()
            out.tile_sizes = parse_tile_group(pb, out.frame.tile_info, out.tile_offs)
        elif typ == OBU_FRAME_HEADER or typ == OBU_REDUNDANT_FRAME_HEADER:
            if not have_seq:
                raise Error("av1: frame header before the sequence header")
            var pb = Bits(buf, ps, pe)
            out.frame = parse_frame_header(pb, out.seq)
            have_frame = True
        elif typ == OBU_TILE_GROUP:
            if not have_frame:
                raise Error("av1: tile group before the frame header")
            var pb = Bits(buf, ps, pe)
            out.tile_sizes = parse_tile_group(pb, out.frame.tile_info, out.tile_offs)
        pos = pe
    if not have_seq:
        raise Error("av1: no sequence header OBU")
    if not have_frame:
        raise Error("av1: no frame header OBU")
    out.data = buf^
    return out^
