"""Film grain checks. No arguments: the random number generator against hand-worked values, the scaling table, and synthesis on four
configurations pinned by checksum from tools/av1_grain_oracle.py. `FILE.obu BITOFF`: parse film_grain_params() of the first frame
OBU of an OBU stream starting at payload bit BITOFF and print `name=value` lines in the order ffmpeg trace_headers shows them
(tests/av1grain_test.sh compares them)."""
from std.sys import argv
from imkit.av1frame import Frame
from imkit.av1obu import Bits
from imkit.av1tab import Tables
from imkit.av1grain import FilmGrainParams, parse_film_grain_params, apply_film_grain, get_random_number


def show(v: List[Int]) -> String:
    var s = String("")
    for x in v:
        s += String(x) + " "
    return s^


def check(name: String, got: List[Int], want: List[Int], mut failures: Int):
    if got != want:
        failures += 1
        print("FAIL", name, "got", show(got), "want", show(want))


def coefs(n: Int, a: Int, m: Int, c: Int) -> List[Int]:
    var r = List[Int](length=25, fill=128)
    for i in range(n):
        r[i] = 128 + ((i * a) % m) - c
    return r^


def set_points(mut vals: List[Int], mut scal: List[Int], pts: List[Int]):
    for i in range(len(pts) // 2):
        vals[i] = pts[2 * i]
        scal[i] = pts[2 * i + 1]


def synth(kind: Int, t: Tables) raises -> List[Int]:
    """Configs A to D of tools/av1_grain_oracle.py."""
    var p = FilmGrainParams()
    p.apply_grain = True
    var bd = 8
    var sx = 1
    var sy = 1
    var w = 75
    var h = 71
    var mc = 2
    var planes = 3
    if kind == 0:
        p.grain_seed = 0xBDE4
        p.num_y_points = 3
        set_points(p.point_y_value, p.point_y_scaling, [16, 0, 100, 90, 200, 120])
        p.num_cb_points = 2
        set_points(p.point_cb_value, p.point_cb_scaling, [16, 20, 128, 100])
        p.num_cr_points = 2
        set_points(p.point_cr_value, p.point_cr_scaling, [50, 60, 240, 30])
        p.grain_scaling_minus_8 = 2
        p.ar_coeff_lag = 2
        p.ar_coeffs_y_plus_128 = coefs(12, 7, 11, 5)
        p.ar_coeffs_cb_plus_128 = coefs(13, 5, 9, 4)
        p.ar_coeffs_cr_plus_128 = coefs(13, 3, 7, 3)
        p.ar_coeff_shift_minus_6 = 1
        p.cb_mult = 140
        p.cb_luma_mult = 100
        p.cb_offset = 300
        p.cr_mult = 120
        p.cr_luma_mult = 150
        p.cr_offset = 200
        p.overlap_flag = True
    elif kind == 1:
        bd = 10
        sx = 0
        sy = 0
        w = 70
        h = 40
        mc = 0
        p.grain_seed = 777
        p.num_y_points = 2
        set_points(p.point_y_value, p.point_y_scaling, [0, 40, 255, 60])
        p.chroma_scaling_from_luma = True
        p.grain_scaling_minus_8 = 1
        p.ar_coeff_lag = 1
        p.ar_coeffs_y_plus_128 = coefs(4, 7, 11, 5)
        p.ar_coeffs_cb_plus_128 = coefs(5, 5, 9, 4)
        p.ar_coeffs_cr_plus_128 = coefs(5, 3, 7, 3)
        p.grain_scale_shift = 1
        p.clip_to_restricted_range = True
    elif kind == 2:
        sy = 0
        w = 64
        h = 33
        p.grain_seed = 4242
        p.num_y_points = 1
        set_points(p.point_y_value, p.point_y_scaling, [30, 50])
        p.num_cb_points = 1
        set_points(p.point_cb_value, p.point_cb_scaling, [60, 80])
        p.grain_scaling_minus_8 = 3
        p.ar_coeff_lag = 3
        p.ar_coeffs_y_plus_128 = coefs(24, 7, 11, 5)
        p.ar_coeffs_cb_plus_128 = coefs(25, 5, 9, 4)
        p.ar_coeffs_cr_plus_128 = coefs(25, 3, 7, 3)
        p.ar_coeff_shift_minus_6 = 2
        p.grain_scale_shift = 2
        p.cb_mult = 128
        p.cb_luma_mult = 128
        p.cb_offset = 256
        p.overlap_flag = True
        p.clip_to_restricted_range = True
    else:
        planes = 1
        w = 40
        h = 36
        p.grain_seed = 31337
        p.num_y_points = 2
        set_points(p.point_y_value, p.point_y_scaling, [0, 20, 255, 70])
        p.overlap_flag = True
    var f = Frame(w, h, bd, sx, sy, planes)
    for pl in range(planes):
        for y in range(f.planes[pl].h):
            for x in range(f.planes[pl].w):
                var v = (x * 17 + y * 29 + ((x * y) % 7) * 23 + pl * 45) % 256
                f.planes[pl].set(x, y, v if bd == 8 else v * 4 + x % 4)
    var o = apply_film_grain(f, p, t, mc)
    var r = List[Int]()
    for pl in range(planes):
        var cs = 0
        for y in range(o.planes[pl].h):
            for x in range(o.planes[pl].w):
                cs = (cs + o.planes[pl].get(x, y) * (y * o.planes[pl].w + x + 1)) % 4294967296
        r.append(cs)
    return r^


def dump(name: String, v: Int):
    print(name + "=" + String(v))


def dump_params(p: FilmGrainParams, mono: Bool):
    dump("apply_grain", 1 if p.apply_grain else 0)
    if not p.apply_grain:
        return
    dump("grain_seed", p.grain_seed)
    dump("num_y_points", p.num_y_points)
    for i in range(p.num_y_points):
        dump("point_y_value[" + String(i) + "]", p.point_y_value[i])
        dump("point_y_scaling[" + String(i) + "]", p.point_y_scaling[i])
    if not mono:
        dump("chroma_scaling_from_luma", 1 if p.chroma_scaling_from_luma else 0)
    # num_cb_points / num_cr_points are only coded when chroma is not derived from luma
    var coded = not (mono or p.chroma_scaling_from_luma)
    if coded:
        dump("num_cb_points", p.num_cb_points)
        for i in range(p.num_cb_points):
            dump("point_cb_value[" + String(i) + "]", p.point_cb_value[i])
            dump("point_cb_scaling[" + String(i) + "]", p.point_cb_scaling[i])
        dump("num_cr_points", p.num_cr_points)
        for i in range(p.num_cr_points):
            dump("point_cr_value[" + String(i) + "]", p.point_cr_value[i])
            dump("point_cr_scaling[" + String(i) + "]", p.point_cr_scaling[i])
    dump("grain_scaling_minus_8", p.grain_scaling_minus_8)
    dump("ar_coeff_lag", p.ar_coeff_lag)
    var n = 2 * p.ar_coeff_lag * (p.ar_coeff_lag + 1)
    var nc = n + 1 if p.num_y_points > 0 else n
    if p.num_y_points > 0:
        for i in range(n):
            dump("ar_coeffs_y_plus_128[" + String(i) + "]", p.ar_coeffs_y_plus_128[i])
    if p.chroma_scaling_from_luma or p.num_cb_points > 0:
        for i in range(nc):
            dump("ar_coeffs_cb_plus_128[" + String(i) + "]", p.ar_coeffs_cb_plus_128[i])
    if p.chroma_scaling_from_luma or p.num_cr_points > 0:
        for i in range(nc):
            dump("ar_coeffs_cr_plus_128[" + String(i) + "]", p.ar_coeffs_cr_plus_128[i])
    dump("ar_coeff_shift_minus_6", p.ar_coeff_shift_minus_6)
    dump("grain_scale_shift", p.grain_scale_shift)
    if p.num_cb_points > 0:
        dump("cb_mult", p.cb_mult)
        dump("cb_luma_mult", p.cb_luma_mult)
        dump("cb_offset", p.cb_offset)
    if p.num_cr_points > 0:
        dump("cr_mult", p.cr_mult)
        dump("cr_luma_mult", p.cr_luma_mult)
        dump("cr_offset", p.cr_offset)
    dump("overlap_flag", 1 if p.overlap_flag else 0)
    dump("clip_to_restricted_range", 1 if p.clip_to_restricted_range else 0)


def parse_mode() raises:
    var d: List[UInt8]
    with open(argv()[1], "r") as f:
        d = f.read_bytes()
    var bitoff = Int(argv()[2])
    var mono = len(argv()) > 3 and argv()[3] == "mono"
    var pos = 0
    while pos < len(d):  # walk OBUs to the first OBU_FRAME (type 6)
        var hdr = Int(d[pos])
        var typ = (hdr >> 3) & 15
        pos += 1
        if (hdr >> 2) & 1 == 1:
            pos += 1
        var size = 0
        var shift = 0
        while True:
            var bb = Int(d[pos])
            pos += 1
            size |= (bb & 127) << shift
            shift += 7
            if bb < 128:
                break
        if typ == 6:
            var b = Bits(d, pos, pos + size)
            var skip = bitoff
            while skip > 0:  # f(n) takes at most 32 bits
                var n = min(skip, 32)
                _ = b.f(n)
                skip -= n
            dump_params(parse_film_grain_params(b, mono, True, True), mono)
            return
        pos += size
    raise Error("no OBU_FRAME")


def main() raises:
    if len(argv()) > 2:
        parse_mode()
        return
    var failures = 0
    # RandomRegister = 1: bit = 1 -> 0x8000; then the register shifts right until bit 12 or bit 3 or bit 0 is set (hand worked)
    var reg = 1
    var got = List[Int]()
    for _ in range(8):
        got.append(get_random_number(reg, 16))
    check("rng 16 bits", got, [0x8000, 0x4000, 0x2000, 0x1000, 0x8800, 0x4400, 0x2200, 0x1100], failures)
    reg = 1
    got = List[Int]()
    for _ in range(8):
        got.append(get_random_number(reg, 11))
    check("rng 11 bits", got, [1024, 512, 256, 128, 1088, 544, 272, 136], failures)
    reg = 1
    got = List[Int]()
    for _ in range(8):
        got.append(get_random_number(reg, 8))
    check("rng 8 bits", got, [128, 64, 32, 16, 136, 68, 34, 17], failures)
    var t = Tables()
    check("config A 420 8-bit overlap lag 2", synth(0, t), [1804635665, 118683625, 119708820], failures)
    check("config B 444 10-bit cfl restricted identity", synth(1, t), [1996758607, 1993850570, 2008515053], failures)
    check("config C 422 lag 3 restricted", synth(2, t), [285199563, 70796583, 71023969], failures)
    check("config D mono", synth(3, t), [132737761], failures)
    if failures == 0:
        print("PASS av1grain")
    else:
        print("FAIL av1grain:", failures, "checks")
