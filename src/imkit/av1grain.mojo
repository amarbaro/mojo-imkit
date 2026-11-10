"""AV1 film grain: film_grain_params() parser (spec 5.9.30, key frames) and the synthesis process (spec 7.18.3).

`parse_film_grain_params` starts at the `apply_grain` bit: the caller has already checked film_grain_params_present and
show_frame / showable_frame. `apply_film_grain` returns a new Frame of the same geometry (the caller's frame is the OutY / OutU /
OutV of 7.18.2: cropped to UpscaledWidth x FrameHeight).
"""
from imkit.av1frame import Frame, Plane
from imkit.av1obu import Bits
from imkit.av1tab import Tables

comptime MC_IDENTITY = 0


struct FilmGrainParams(Copyable, Movable):
    var apply_grain: Bool
    var grain_seed: Int
    var update_grain: Bool
    var num_y_points: Int
    var point_y_value: List[Int]
    var point_y_scaling: List[Int]
    var chroma_scaling_from_luma: Bool
    var num_cb_points: Int
    var point_cb_value: List[Int]
    var point_cb_scaling: List[Int]
    var num_cr_points: Int
    var point_cr_value: List[Int]
    var point_cr_scaling: List[Int]
    var grain_scaling_minus_8: Int
    var ar_coeff_lag: Int
    var ar_coeffs_y_plus_128: List[Int]
    var ar_coeffs_cb_plus_128: List[Int]
    var ar_coeffs_cr_plus_128: List[Int]
    var ar_coeff_shift_minus_6: Int
    var grain_scale_shift: Int
    var cb_mult: Int
    var cb_luma_mult: Int
    var cb_offset: Int
    var cr_mult: Int
    var cr_luma_mult: Int
    var cr_offset: Int
    var overlap_flag: Bool
    var clip_to_restricted_range: Bool

    def __init__(out self):
        self.apply_grain = False
        self.grain_seed = 0
        self.update_grain = True
        self.num_y_points = 0
        self.point_y_value = List[Int](length=16, fill=0)
        self.point_y_scaling = List[Int](length=16, fill=0)
        self.chroma_scaling_from_luma = False
        self.num_cb_points = 0
        self.point_cb_value = List[Int](length=16, fill=0)
        self.point_cb_scaling = List[Int](length=16, fill=0)
        self.num_cr_points = 0
        self.point_cr_value = List[Int](length=16, fill=0)
        self.point_cr_scaling = List[Int](length=16, fill=0)
        self.grain_scaling_minus_8 = 0
        self.ar_coeff_lag = 0
        self.ar_coeffs_y_plus_128 = List[Int](length=25, fill=128)
        self.ar_coeffs_cb_plus_128 = List[Int](length=25, fill=128)
        self.ar_coeffs_cr_plus_128 = List[Int](length=25, fill=128)
        self.ar_coeff_shift_minus_6 = 0
        self.grain_scale_shift = 0
        self.cb_mult = 0
        self.cb_luma_mult = 0
        self.cb_offset = 0
        self.cr_mult = 0
        self.cr_luma_mult = 0
        self.cr_offset = 0
        self.overlap_flag = False
        self.clip_to_restricted_range = False


def parse_film_grain_params(mut b: Bits, mono_chrome: Bool, subsampling_x: Bool, subsampling_y: Bool) raises -> FilmGrainParams:
    """5.9.30 for a KEY_FRAME (update_grain is 1 without a bit)."""
    var p = FilmGrainParams()
    p.apply_grain = b.f(1) == 1
    if not p.apply_grain:
        return p^
    p.grain_seed = b.f(16)
    p.num_y_points = b.f(4)
    if p.num_y_points > 14:
        raise Error("grain: num_y_points " + String(p.num_y_points) + " > 14")
    for i in range(p.num_y_points):
        p.point_y_value[i] = b.f(8)
        p.point_y_scaling[i] = b.f(8)
    p.chroma_scaling_from_luma = False if mono_chrome else b.f(1) == 1
    if mono_chrome or p.chroma_scaling_from_luma or (subsampling_x and subsampling_y and p.num_y_points == 0):
        p.num_cb_points = 0
        p.num_cr_points = 0
    else:
        p.num_cb_points = b.f(4)
        if p.num_cb_points > 10:
            raise Error("grain: num_cb_points " + String(p.num_cb_points) + " > 10")
        for i in range(p.num_cb_points):
            p.point_cb_value[i] = b.f(8)
            p.point_cb_scaling[i] = b.f(8)
        p.num_cr_points = b.f(4)
        if p.num_cr_points > 10:
            raise Error("grain: num_cr_points " + String(p.num_cr_points) + " > 10")
        for i in range(p.num_cr_points):
            p.point_cr_value[i] = b.f(8)
            p.point_cr_scaling[i] = b.f(8)
    p.grain_scaling_minus_8 = b.f(2)
    p.ar_coeff_lag = b.f(2)
    var num_pos_luma = 2 * p.ar_coeff_lag * (p.ar_coeff_lag + 1)
    var num_pos_chroma = num_pos_luma
    if p.num_y_points > 0:
        num_pos_chroma = num_pos_luma + 1
        for i in range(num_pos_luma):
            p.ar_coeffs_y_plus_128[i] = b.f(8)
    if p.chroma_scaling_from_luma or p.num_cb_points > 0:
        for i in range(num_pos_chroma):
            p.ar_coeffs_cb_plus_128[i] = b.f(8)
    if p.chroma_scaling_from_luma or p.num_cr_points > 0:
        for i in range(num_pos_chroma):
            p.ar_coeffs_cr_plus_128[i] = b.f(8)
    p.ar_coeff_shift_minus_6 = b.f(2)
    p.grain_scale_shift = b.f(2)
    if p.num_cb_points > 0:
        p.cb_mult = b.f(8)
        p.cb_luma_mult = b.f(8)
        p.cb_offset = b.f(9)
    if p.num_cr_points > 0:
        p.cr_mult = b.f(8)
        p.cr_luma_mult = b.f(8)
        p.cr_offset = b.f(9)
    p.overlap_flag = b.f(1) == 1
    p.clip_to_restricted_range = b.f(1) == 1
    return p^


def _round2(x: Int, n: Int) -> Int:
    return (x + ((1 << n) >> 1)) >> n if n > 0 else x


def _clip3(lo: Int, hi: Int, v: Int) -> Int:
    return lo if v < lo else (hi if v > hi else v)


def get_random_number(mut reg: Int, bits: Int) -> Int:
    """7.18.3.2: one step of the 16-bit LFSR; returns the top `bits` bits of the new state."""
    var r = reg
    var bit = ((r >> 0) ^ (r >> 1) ^ (r >> 3) ^ (r >> 12)) & 1
    r = (r >> 1) | (bit << 15)
    reg = r
    return (r >> (16 - bits)) & ((1 << bits) - 1)


def _white_noise(mut reg: Int, t: Tables, w: Int, h: Int, enabled: Bool, shift: Int) -> List[Int]:
    var g = List[Int](length=w * h, fill=0)
    for i in range(w * h):
        if enabled:
            g[i] = _round2(Int(t.gaussian_sequence[get_random_number(reg, 11)]), shift)
    return g^


def _scaling_lut(pt_x: List[Int], pt_y: List[Int], n: Int) -> List[Int]:
    """7.18.3.4 for one plane: 256 entries."""
    var lut = List[Int](length=257, fill=0)  # one spare entry so scale_lut can read x + 1
    if n == 0:
        return lut^
    for x in range(pt_x[0]):
        lut[x] = pt_y[0]
    for i in range(n - 1):
        var delta_y = pt_y[i + 1] - pt_y[i]
        var delta_x = pt_x[i + 1] - pt_x[i]
        var delta = delta_y * ((65536 + (delta_x >> 1)) // delta_x)
        for x in range(delta_x):
            lut[pt_x[i] + x] = pt_y[i] + ((x * delta + 32768) >> 16)
    for x in range(pt_x[n - 1], 256):
        lut[x] = pt_y[n - 1]
    return lut^


def _scale_lut(lut: List[Int], index: Int, bd: Int) -> Int:
    var shift = bd - 8
    var x = index >> shift
    var rem = index - (x << shift)
    if bd == 8 or x == 255:
        return lut[x]
    return lut[x] + _round2((lut[x + 1] - lut[x]) * rem, shift)


def apply_film_grain(src: Frame, params: FilmGrainParams, tables: Tables, matrix_coefficients: Int) raises -> Frame:
    """7.18.3: grain synthesis on a copy of `src`."""
    var out = src.copy()
    if not params.apply_grain:
        return out^
    var bd = src.bit_depth
    var num_planes = len(src.planes)
    var sub_x = src.sub_x
    var sub_y = src.sub_y
    var w = src.planes[0].w
    var h = src.planes[0].h
    var mono = num_planes == 1
    var grain_center = 128 << (bd - 8)
    var grain_min = -grain_center
    var grain_max = (256 << (bd - 8)) - 1 - grain_center
    var lag = params.ar_coeff_lag
    var seed = params.grain_seed

    # 7.18.3.3 generate grain
    var wshift = 12 - bd + params.grain_scale_shift
    var reg = seed
    var luma_grain = _white_noise(reg, tables, 82, 73, params.num_y_points > 0, wshift)
    var ar_shift = params.ar_coeff_shift_minus_6 + 6
    for y in range(3, 73):
        for x in range(3, 82 - 3):
            var s = 0
            var pos = 0
            for dr in range(-lag, 1):
                for dc in range(-lag, lag + 1):
                    if dr == 0 and dc == 0:
                        break
                    s += luma_grain[(y + dr) * 82 + x + dc] * (params.ar_coeffs_y_plus_128[pos] - 128)
                    pos += 1
            luma_grain[y * 82 + x] = _clip3(grain_min, grain_max, luma_grain[y * 82 + x] + _round2(s, ar_shift))
    var chroma_w = 44 if sub_x == 1 else 82
    var chroma_h = 38 if sub_y == 1 else 73
    var cb_grain = List[Int]()
    var cr_grain = List[Int]()
    if not mono:
        reg = seed ^ 0xB524
        cb_grain = _white_noise(reg, tables, chroma_w, chroma_h, params.num_cb_points > 0 or params.chroma_scaling_from_luma, wshift)
        reg = seed ^ 0x49D8
        cr_grain = _white_noise(reg, tables, chroma_w, chroma_h, params.num_cr_points > 0 or params.chroma_scaling_from_luma, wshift)
        for y in range(3, chroma_h):
            for x in range(3, chroma_w - 3):
                var s0 = 0
                var s1 = 0
                var pos = 0
                for dr in range(-lag, 1):
                    for dc in range(-lag, lag + 1):
                        var c0 = params.ar_coeffs_cb_plus_128[pos] - 128
                        var c1 = params.ar_coeffs_cr_plus_128[pos] - 128
                        if dr == 0 and dc == 0:
                            if params.num_y_points > 0:
                                var luma = 0
                                var luma_x = ((x - 3) << sub_x) + 3
                                var luma_y = ((y - 3) << sub_y) + 3
                                for i in range(sub_y + 1):
                                    for j in range(sub_x + 1):
                                        luma += luma_grain[(luma_y + i) * 82 + luma_x + j]
                                luma = _round2(luma, sub_x + sub_y)
                                s0 += luma * c0
                                s1 += luma * c1
                            break
                        s0 += cb_grain[(y + dr) * chroma_w + x + dc] * c0
                        s1 += cr_grain[(y + dr) * chroma_w + x + dc] * c1
                        pos += 1
                cb_grain[y * chroma_w + x] = _clip3(grain_min, grain_max, cb_grain[y * chroma_w + x] + _round2(s0, ar_shift))
                cr_grain[y * chroma_w + x] = _clip3(grain_min, grain_max, cr_grain[y * chroma_w + x] + _round2(s1, ar_shift))

    # 7.18.3.4 scaling lookup
    var luts = List[List[Int]]()
    luts.append(_scaling_lut(params.point_y_value, params.point_y_scaling, params.num_y_points))
    if not mono:
        if params.chroma_scaling_from_luma:
            luts.append(luts[0].copy())
            luts.append(luts[0].copy())
        else:
            luts.append(_scaling_lut(params.point_cb_value, params.point_cb_scaling, params.num_cb_points))
            luts.append(_scaling_lut(params.point_cr_value, params.point_cr_scaling, params.num_cr_points))

    # 7.18.3.5 noise stripes (kept two at a time) blended into noise images
    var noise = List[List[Int16]]()  # noiseImage per plane
    var pw = List[Int]()
    var ph = List[Int]()
    for p in range(num_planes):
        var psx = 0 if p == 0 else sub_x
        var psy = 0 if p == 0 else sub_y
        pw.append((w + psx) >> psx)
        ph.append((h + psy) >> psy)
        noise.append(List[Int16](length=pw[p] * ph[p], fill=0))
    var stripe_w = w + 80
    var prev = List[List[Int]]()  # noiseStripe[lumaNum - 1][plane], rows * stripe_w
    var luma_num = 0
    var y0 = 0
    while y0 < (h + 1) // 2:
        reg = seed
        reg ^= ((luma_num * 37 + 178) & 255) << 8
        reg ^= (luma_num * 173 + 105) & 255
        var cur = List[List[Int]]()
        for p in range(num_planes):
            var psy = 0 if p == 0 else sub_y
            cur.append(List[Int](length=(34 >> psy) * stripe_w, fill=0))
        var x0 = 0
        while x0 < (w + 1) // 2:
            var rand = get_random_number(reg, 8)
            var offset_x = rand >> 4
            var offset_y = rand & 15
            for p in range(num_planes):
                var psx = 0 if p == 0 else sub_x
                var psy = 0 if p == 0 else sub_y
                var pox = 6 + offset_x if psx == 1 else 9 + offset_x * 2
                var poy = 6 + offset_y if psy == 1 else 9 + offset_y * 2
                var gw = 82 if (p == 0 or sub_x == 0) else 44
                for i in range(34 >> psy):
                    for j in range(34 >> psx):
                        var g: Int
                        if p == 0:
                            g = luma_grain[(poy + i) * 82 + pox + j]
                        elif p == 1:
                            g = cb_grain[(poy + i) * gw + pox + j]
                        else:
                            g = cr_grain[(poy + i) * gw + pox + j]
                        if psx == 0:
                            var col = x0 * 2 + j
                            if j < 2 and params.overlap_flag and x0 > 0:
                                var old = cur[p][i * stripe_w + col]
                                g = old * 27 + g * 17 if j == 0 else old * 17 + g * 27
                                g = _clip3(grain_min, grain_max, _round2(g, 5))
                            cur[p][i * stripe_w + col] = g
                        else:
                            var col = x0 + j
                            if j == 0 and params.overlap_flag and x0 > 0:
                                var old = cur[p][i * stripe_w + col]
                                g = _clip3(grain_min, grain_max, _round2(old * 23 + g * 22, 5))
                            cur[p][i * stripe_w + col] = g
            x0 += 16
        for p in range(num_planes):
            var psy = 0 if p == 0 else sub_y
            var rows = 32 >> psy
            for i in range(rows):
                var y = (luma_num << (5 - psy)) + i
                if y >= ph[p]:
                    break
                for x in range(pw[p]):
                    var g = cur[p][i * stripe_w + x]
                    if psy == 0:
                        if i < 2 and luma_num > 0 and params.overlap_flag:
                            var old = prev[p][(i + 32) * stripe_w + x]
                            g = old * 27 + g * 17 if i == 0 else old * 17 + g * 27
                            g = _clip3(grain_min, grain_max, _round2(g, 5))
                    else:
                        if i < 1 and luma_num > 0 and params.overlap_flag:
                            var old = prev[p][(i + 16) * stripe_w + x]
                            g = _clip3(grain_min, grain_max, _round2(old * 23 + g * 22, 5))
                    noise[p][y * pw[p] + x] = Int16(g)
        prev = cur^
        luma_num += 1
        y0 += 16

    # blend
    var min_value = 0
    var max_luma = (256 << (bd - 8)) - 1
    var max_chroma = max_luma
    if params.clip_to_restricted_range:
        min_value = 16 << (bd - 8)
        max_luma = 235 << (bd - 8)
        max_chroma = max_luma if matrix_coefficients == MC_IDENTITY else 240 << (bd - 8)
    var scaling_shift = params.grain_scaling_minus_8 + 8
    var pix_max = (1 << bd) - 1
    if not mono:
        for y in range(ph[1]):
            for x in range(pw[1]):
                var luma_x = x << sub_x
                var luma_y = y << sub_y
                var luma_next_x = min(luma_x + 1, w - 1)
                var avg = _round2(src.planes[0].get(luma_x, luma_y) + src.planes[0].get(luma_next_x, luma_y), 1) if sub_x == 1 else src.planes[0].get(luma_x, luma_y)
                for p in range(1, 3):
                    var npts = params.num_cb_points if p == 1 else params.num_cr_points
                    if npts > 0 or params.chroma_scaling_from_luma:
                        var orig = src.planes[p].get(x, y)
                        var merged: Int
                        if params.chroma_scaling_from_luma:
                            merged = avg
                        else:
                            var lm = params.cb_luma_mult if p == 1 else params.cr_luma_mult
                            var mu = params.cb_mult if p == 1 else params.cr_mult
                            var off = params.cb_offset if p == 1 else params.cr_offset
                            var combined = avg * (lm - 128) + orig * (mu - 128)
                            merged = _clip3(0, pix_max, (combined >> 6) + ((off - 256) << (bd - 8)))
                        var nz = _round2(_scale_lut(luts[p], merged, bd) * Int(noise[p][y * pw[p] + x]), scaling_shift)
                        out.planes[p].set(x, y, _clip3(min_value, max_chroma, orig + nz))
    if params.num_y_points > 0:
        for y in range(h):
            for x in range(w):
                var orig = src.planes[0].get(x, y)
                var nz = _round2(_scale_lut(luts[0], orig, bd) * Int(noise[0][y * w + x]), scaling_shift)
                out.planes[0].set(x, y, _clip3(min_value, max_luma, orig + nz))
    return out^
