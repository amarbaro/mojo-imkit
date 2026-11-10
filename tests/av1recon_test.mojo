"""Lane B gate for src/imkit/av1recon.mojo (spec 7.12 dequantization, 7.13 inverse transforms).

(1) Exact hand-computed cases: DC-only DCT at 4, 8, 16, 32, 64 (spec integer math worked by hand), identity 4x4, WHT, dqDenom,
    the 0xFFFFFF mask, the dequant clip, quantizer matrix, get_qindex with segments and delta q, eob 0, bad inputs raising.
(2) A float oracle of the spec's unnormalized transforms over all 19 sizes and every legal tx type, random sparse blocks:
    the integer pipeline must stay within a small rounding tolerance of the float one (catches wrong permutations,
    angles, shifts, flips, the 2:1 rectangular scaling). Run through tests/av1recon_test.sh."""
from std.math import cos, sin, sqrt
from imkit.av1frame import Frame
from imkit.av1tab import Tables
from imkit.av1recon import ReconInput, reconstruct, inverse_transform_2d


comptime PI = 3.141592653589793

def check(name: String, ok: Bool, detail: String = "") raises:
    if not ok:
        print("FAIL", name, detail)
        raise Error("av1recon_test: " + name)


struct Rng(Movable):
    var s: UInt64

    def __init__(out self, seed: UInt64):
        self.s = seed * 0x9E3779B97F4A7C15 + 1

    def below(mut self, n: Int) -> Int:
        self.s ^= self.s << 13
        self.s ^= self.s >> 7
        self.s ^= self.s << 17
        return Int(self.s % UInt64(n))


def flat_frame(w: Int, h: Int, bd: Int, v: Int) -> Frame:
    var f = Frame(w, h, bd, 0, 0, 1)
    for y in range(h):
        for x in range(w):
            f.planes[0].set(x, y, v)
    return f^


def inp_for(bd: Int, qidx: Int) -> ReconInput:
    var i = ReconInput()
    i.bit_depth = bd
    i.base_q_idx = qidx
    return i^


def dc_block(tables: Tables, inp: ReconInput, tx: Int, w: Int, h: Int, v: Int, base: Int) raises -> Frame:
    var f = flat_frame(w, h, inp.bit_depth, base)
    var q = List[Int32](length=min(w, 32) * min(h, 32), fill=0)
    q[0] = Int32(v)
    reconstruct(f, tables, inp, 0, 0, 0, tx, 0, q, 1)
    return f^


def all_equal(f: Frame, w: Int, h: Int, v: Int) -> Bool:
    for y in range(h):
        for x in range(w):
            if f.planes[0].get(x, y) != v:
                return False
    return True


# ---- float oracle -------------------------------------------------------------------------------------------

def f_dct(x: List[Float64], n: Int) -> List[Float64]:
    var o = List[Float64](length=n, fill=0.0)
    for i in range(n):
        var a = 0.0
        for k in range(n):
            var c = cos(PI * Float64((2 * i + 1) * k) / Float64(2 * n))
            a += x[k] * (c / sqrt(2.0) if k == 0 else c)
        o[i] = a
    return o^


def f_adst(x: List[Float64], n: Int) -> List[Float64]:
    var o = List[Float64](length=n, fill=0.0)
    for i in range(n):
        var a = 0.0
        for k in range(n):
            if n == 4:
                a += x[k] * (2.0 * sqrt(2.0) / 3.0) * sin(PI * Float64((i + 1) * (2 * k + 1)) / 9.0)
            else:
                a += x[k] * sin(PI * Float64((2 * i + 1) * (2 * k + 1)) / Float64(4 * n))
        o[i] = a
    return o^


def f_id(x: List[Float64], n: Int) -> List[Float64]:
    var g = sqrt(2.0) if n == 4 else (2.0 if n == 8 else (2.0 * sqrt(2.0) if n == 16 else 4.0))
    var o = List[Float64](length=n, fill=0.0)
    for i in range(n):
        o[i] = x[i] * g
    return o^


def f_1d(x: List[Float64], n: Int, kind: Int) -> List[Float64]:
    # kind: 0 DCT, 1 ADST, 2 flipped ADST (flip is applied at the write), 3 identity
    if kind == 0:
        return f_dct(x, n)
    if kind == 3:
        return f_id(x, n)
    return f_adst(x, n)


# per tx type: (column kind, row kind)
comptime COL_KIND = [0, 1, 0, 1, 2, 0, 2, 1, 2, 3, 0, 3, 1, 3, 2, 3]
comptime ROW_KIND = [0, 0, 1, 1, 0, 2, 2, 2, 1, 3, 3, 0, 3, 1, 3, 2]


def legal(kind: Int, n: Int) -> Bool:
    if n == 64:
        return kind == 0
    if n == 32:
        return kind == 0 or kind == 3
    return True


def oracle_case(tables: Tables, tx: Int, ttype: Int, bd: Int, mut rng: Rng) raises -> Int:
    """Returns the max |integer - float| over the block; records failures through check."""
    var w = Int(tables.tx_width[tx])
    var h = Int(tables.tx_height[tx])
    var tw = min(w, 32)
    var th = min(h, 32)
    var base = 1 << (bd - 1)
    var f = flat_frame(w, h, bd, base)
    var inp = inp_for(bd, 0)  # q index 0: dc_q = ac_q = 4 at every depth
    var q = List[Int32](length=tw * th, fill=0)
    var coef = List[Float64](length=w * h, fill=0.0)
    var nz = 0
    for i in range(th):
        for j in range(tw):
            if i + j < 10 and rng.below(3) == 0:
                var v = rng.below(6001) - 3000
                q[i * tw + j] = Int32(v)
                if v != 0:
                    nz += 1
    q[0] = Int32(4000 + rng.below(2000))
    var denom = 1.0
    if tx == 3 or tx == 9 or tx == 10 or tx == 17 or tx == 18:
        denom = 2.0
    elif tx == 4 or tx == 11 or tx == 12:
        denom = 4.0
    for i in range(th):
        for j in range(tw):
            var d = Float64(Int(q[i * tw + j]) * 4)
            # integer division truncates toward zero
            coef[i * w + j] = Float64(Int(d / denom)) if d >= 0 else -Float64(Int(-d / denom))
    var lw = Int(tables.tx_width_log2[tx])
    var lh = Int(tables.tx_height_log2[tx])
    var rs = Int(tables.transform_row_shift[tx])
    var rect = (lw - lh == 1) or (lh - lw == 1)
    var ck = materialize[COL_KIND]()[ttype]
    var rk = materialize[ROW_KIND]()[ttype]
    var res = List[Float64](length=w * h, fill=0.0)
    for i in range(h):
        var row = List[Float64](length=w, fill=0.0)
        for j in range(w):
            row[j] = coef[i * w + j] * (sqrt(0.5) if rect else 1.0)
        var o = f_1d(row, w, rk)
        for j in range(w):
            res[i * w + j] = o[j] / Float64(1 << rs)
    for j in range(w):
        var col = List[Float64](length=h, fill=0.0)
        for i in range(h):
            col[i] = res[i * w + j]
        var o = f_1d(col, h, ck)
        for i in range(h):
            res[i * w + j] = o[i] / 16.0
    reconstruct(f, tables, inp, 0, 0, 0, tx, ttype, q, th * tw)
    var flip_ud = ck == 2
    var flip_lr = rk == 2
    var maxerr = 0
    var maxv = (1 << bd) - 1
    for i in range(h):
        for j in range(w):
            var yy = (h - i - 1) if flip_ud else i
            var xx = (w - j - 1) if flip_lr else j
            var e = Float64(base) + res[i * w + j]
            e = max(0.0, min(Float64(maxv), e))
            var got = f.planes[0].get(xx, yy)
            var err = abs(got - Int(e + 0.5))
            if err > maxerr:
                maxerr = err
    return maxerr


def main() raises:
    var tables = Tables()

    # (1) hand-computed DC-only blocks (base 100, 8-bit, q index 0 so dc_q = 4): flat residual, see the spec math in the PR
    var inp8 = inp_for(8, 0)
    check("dc4x4", all_equal(dc_block(tables, inp8, 0, 4, 4, 64, 100), 4, 4, 108))
    check("dc8x8", all_equal(dc_block(tables, inp8, 1, 8, 8, 64, 100), 8, 8, 104))
    check("dc16x16", all_equal(dc_block(tables, inp8, 2, 16, 16, 64, 100), 16, 16, 102))
    check("dc32x32", all_equal(dc_block(tables, inp8, 3, 32, 32, 128, 100), 32, 32, 102))  # dqDenom 2
    check("dc64x64", all_equal(dc_block(tables, inp8, 4, 64, 64, 640, 100), 64, 64, 105))  # dqDenom 4, tw = 32

    # identity 4x4 (IDTX = 9): coefficient 100 -> only (0,0) changes, by 50
    var f = flat_frame(4, 4, 8, 100)
    var q4 = List[Int32](length=16, fill=0)
    q4[0] = 100
    reconstruct(f, tables, inp8, 0, 0, 0, 0, 9, q4, 1)
    var idok = f.planes[0].get(0, 0) == 150
    for i in range(1, 16):
        if f.planes[0].get(i % 4, i // 4) != 100:
            idok = False
    check("idtx4", idok)

    # lossless WHT, DC 5 (dq = 20): rows [2 1 1 1], then [1 1 1 1] x 3 (worked by hand from 7.13.2.10)
    var inpl = inp_for(8, 0)
    inpl.lossless = True
    f = flat_frame(4, 4, 8, 100)
    q4[0] = 5
    reconstruct(f, tables, inpl, 0, 0, 0, 0, 0, q4, 1)
    var wok = True
    for i in range(4):
        for j in range(4):
            var want = 102 if (i == 0 and j == 0) else 101
            if f.planes[0].get(j, i) != want:
                wok = False
    check("wht-dc5", wok)

    # clip to the sample range
    f = dc_block(tables, inp8, 0, 4, 4, 64, 252)
    check("clip-high", all_equal(f, 4, 4, 255))
    f = dc_block(tables, inp8, 0, 4, 4, -64, 3)
    check("clip-low", all_equal(f, 4, 4, 0))

    # 0xFFFFFF mask: dq = 0x1000000 + 40 wraps to 40 -> dq 40 / 1 at 4x4 DC: coefficient c with c * 4 = 16777256 -> c = 4194314
    # (dequant 40 instead of the clip value): equals coefficient 10
    f = dc_block(tables, inp8, 0, 4, 4, 4194314, 100)
    var g = dc_block(tables, inp8, 0, 4, 4, 10, 100)
    check("mask24", f.planes[0].get(0, 0) == g.planes[0].get(0, 0))
    # dequant clip: huge coefficient below the mask, 4 * 2^22 - 4 -> 16777212 clipped to 2^15 - 1 for 8 bit
    f = dc_block(tables, inp8, 0, 4, 4, 4194303, 128)
    g = dc_block(tables, inp8, 0, 4, 4, 8191, 128)  # 8191 * 4 = 32764: just under the clip, so (clip 32767) is within 1 step
    check("dequant-clip", abs(f.planes[0].get(0, 0) - g.planes[0].get(0, 0)) <= 1,
          String(f.planes[0].get(0, 0)) + " vs " + String(g.planes[0].get(0, 0)))

    # quantizer matrix level 5, plane 0: q2 = Round2(4 * QM, 5)
    var inpq = inp_for(8, 0)
    inpq.using_qmatrix = True
    inpq.seg_qm_level[0] = 5
    var qm = Int(tables.quantizer_matrix[(5 * 2 + 0) * 3344 + Int(tables.qm_offset[0]) + 0])
    var q2 = (4 * qm + 16) >> 5
    f = dc_block(tables, inpq, 0, 4, 4, 64, 100)
    var dq = 64 * q2
    var a = (dq * 2896 + 2048) >> 12
    var b = (a * 2896 + 2048) >> 12
    check("qmatrix", all_equal(f, 4, 4, 100 + ((b + 8) >> 4)), "qm=" + String(qm))
    # level 15 means flat even with using_qmatrix
    inpq.seg_qm_level[0] = 15
    f = dc_block(tables, inpq, 0, 4, 4, 64, 100)
    check("qmatrix-flat", all_equal(f, 4, 4, 108))

    # get_qindex / dc_q / ac_q
    var sg = ReconInput()
    sg.base_q_idx = 100
    sg.segment_id = 2
    sg.seg_feature_enabled[2 * 8 + 0] = True
    sg.seg_feature_data[2 * 8 + 0] = -10
    check("qindex-seg", sg.get_qindex(False) == 90)
    sg.delta_q_present = True
    sg.current_qindex = 140
    check("qindex-delta-seg", sg.get_qindex(False) == 130)
    check("qindex-ignore-delta", sg.get_qindex(True) == 90)
    sg.seg_feature_data[2 * 8 + 0] = -255
    check("qindex-clip0", sg.get_qindex(False) == 0)
    sg.segment_id = 0
    check("qindex-delta", sg.get_qindex(False) == 140)
    sg.delta_q_u_dc = 5
    sg.bit_depth = 10
    check("dcq-u-10bit", sg.get_dc_quant(tables, 1) == Int(tables.dc_qlookup[256 + 145]))
    sg.delta_q_v_ac = -200
    sg.bit_depth = 12
    check("acq-v-12bit-clip", sg.get_ac_quant(tables, 2) == Int(tables.ac_qlookup[512 + 0]))

    # eob 0 is a no-op; a skipped block leaves the frame untouched
    f = flat_frame(8, 8, 8, 77)
    var z = List[Int32](length=64, fill=0)
    reconstruct(f, tables, inp8, 0, 0, 0, 1, 0, z, 0)
    check("eob0", all_equal(f, 8, 8, 77))

    # overhang: an 8x8 block at (4, 4) of a 8x8 plane writes only the 4x4 inside
    f = flat_frame(8, 8, 8, 100)
    var q8 = List[Int32](length=64, fill=0)
    q8[0] = 64
    reconstruct(f, tables, inp8, 0, 4, 4, 1, 0, q8, 1)
    check("overhang", f.planes[0].get(7, 7) == 104 and f.planes[0].get(3, 3) == 100 and f.planes[0].get(4, 4) == 104)

    # bad inputs raise
    var raised = 0
    var attempts = 0
    for k in range(8):
        attempts += 1
        try:
            if k == 0:
                reconstruct(f, tables, inp8, 5, 0, 0, 0, 0, q4, 1)
            elif k == 1:
                reconstruct(f, tables, inp8, 0, 0, 0, 19, 0, q4, 1)
            elif k == 2:
                reconstruct(f, tables, inp8, 0, 0, 0, 0, 16, q4, 1)
            elif k == 3:
                reconstruct(f, tables, inp8, 0, 8, 0, 0, 0, q4, 1)
            elif k == 4:
                reconstruct(f, tables, inp8, 0, 0, 0, 1, 0, q4, 1)  # quant shorter than 64
            elif k == 5:
                reconstruct(f, tables, inp8, 0, 0, 0, 0, 0, q4, 17)  # eob > 16
            elif k == 6:
                var bad = inp_for(9, 0)
                reconstruct(f, tables, bad, 0, 0, 0, 0, 0, q4, 1)
            else:
                var qi = List[Int32](length=1024, fill=0)
                qi[0] = 1
                var fb = flat_frame(64, 64, 8, 0)
                reconstruct(fb, tables, inp8, 0, 0, 0, 4, 9, qi, 1)  # identity at size 64
        except e:
            raised += 1
    check("raises", raised == attempts, String(raised) + "/" + String(attempts))

    # identity 16x16 at 12 bit, coefficient 901 -> dq 3604, Python emulation of 7.13.2.13 and 7.13.3 gives 451
    var inp12 = inp_for(12, 0)
    f = flat_frame(16, 16, 12, 2048)
    var q16 = List[Int32](length=256, fill=0)
    q16[0] = 901  # dq 3604 -> 451 (the constant 11585 would give 450)
    reconstruct(f, tables, inp12, 0, 0, 0, 2, 9, q16, 1)
    check("idtx16", f.planes[0].get(0, 0) == 2048 + 451 and f.planes[0].get(1, 0) == 2048 and f.planes[0].get(0, 1) == 2048,
          String(f.planes[0].get(0, 0)))

    # chroma quantizer matrix uses the plane > 0 matrix: at an AC position where the two matrices differ, coefficient 4 m with
    # the matrix (dq = 4 m * Round2(4 QM, 5)) must equal coefficient m * Round2(4 QM, 5) with a flat quantizer (dq = 4 x that)
    var kpos = -1
    var qmc = 0
    for k in range(1, 16):
        var c1 = Int(tables.quantizer_matrix[(5 * 2 + 1) * 3344 + Int(tables.qm_offset[0]) + k])
        var c0 = Int(tables.quantizer_matrix[(5 * 2 + 0) * 3344 + Int(tables.qm_offset[0]) + k])
        if c1 != c0 and kpos < 0:
            kpos = k
            qmc = c1
    check("qm-planes-differ", kpos > 0)
    var inpc = inp_for(8, 0)
    inpc.using_qmatrix = True
    inpc.seg_qm_level[1 * 8 + 0] = 5
    var fm = Frame(4, 4, 8, 0, 0, 3)
    var ff = Frame(4, 4, 8, 0, 0, 3)
    for y in range(4):
        for x in range(4):
            fm.planes[1].set(x, y, 128)
            ff.planes[1].set(x, y, 128)
    var qa = List[Int32](length=16, fill=0)
    var qb = List[Int32](length=16, fill=0)
    qa[kpos] = 4 * 40
    qb[kpos] = Int32(40 * ((4 * qmc + 16) >> 5))
    reconstruct(fm, tables, inpc, 1, 0, 0, 0, 0, qa, 16)
    reconstruct(ff, tables, inp_for(8, 0), 1, 0, 0, 0, 0, qb, 16)
    var same = True
    var diff_from_base = False
    for y in range(4):
        for x in range(4):
            if fm.planes[1].get(x, y) != ff.planes[1].get(x, y):
                same = False
            if fm.planes[1].get(x, y) != 128:
                diff_from_base = True
    check("qm-chroma", same and diff_from_base)

    # saturation: dequantized 32764 entries drive the row Hadamard clip and the clamp between the stages. Expected blocks
    # come from an independent Python emulation of 7.13.2.3 (n = 2) and 7.13.3 for 8 bit (row range 16, column range 16).
    var dqv = List[Int](length=16, fill=0)
    var res = List[Int32](length=16, fill=0)
    dqv[0] = 32764
    dqv[1] = 32764
    dqv[4] = 32764
    inverse_transform_2d(res, dqv, 4, 4, 0, 0, False, 8, tables)
    var want1 = [2048, 2048, 1807, 1024, 2002, 2002, 1024, 240, 894, 894, -84, -868, 110, 110, -868, -1651]
    for k in range(16):
        check("sat1", Int(res[k]) == want1[k], "k=" + String(k) + " got " + String(res[k]))
    for k in range(16):
        dqv[k] = 32764
    inverse_transform_2d(res, dqv, 4, 4, 0, 0, False, 8, tables)
    var want2 = [2048, -2048, 2048, 600, -1108, 600, -600, -119, 1108, -600, 600, 119, 221, -119, 119, 24]
    for k in range(16):
        check("sat2", Int(res[k]) == want2[k], "k=" + String(k) + " got " + String(res[k]))
    for k in range(16):
        var sgn = 1 if ((k // 4) + (k % 4)) % 2 == 0 else -1
        dqv[k] = 0 if k >= 8 else -sgn * 32764
    # rows 0 and 1 of [-,+,-,+] / [+,-,+,-]
    inverse_transform_2d(res, dqv, 4, 4, 0, 0, False, 8, tables)
    var want3 = [48, 240, -240, 444, -72, -360, 360, -664, -240, -1208, 1208, -2048, -359, -1808, 1808, -2048]
    for k in range(16):
        check("sat3", Int(res[k]) == want3[k], "k=" + String(k) + " got " + String(res[k]))

    # identity 4x4, dq 32764: the row output 46338 is clamped to 32767 between the stages (column range 16), giving 2896;
    # without the clamp it would be 4096
    for k in range(16):
        dqv[k] = 0
    dqv[0] = 32764
    inverse_transform_2d(res, dqv, 4, 4, 0, 9, False, 8, tables)
    check("clamp-between-stages", Int(res[0]) == 2896, String(res[0]))

    # (2) float oracle over every size and legal type
    var rng = Rng(7)
    var worst = 0
    var cases = 0
    for tx in range(19):
        var lw = Int(tables.tx_width[tx])
        var lh = Int(tables.tx_height[tx])
        for ttype in range(16):
            if not legal(materialize[ROW_KIND]()[ttype], lw) or not legal(materialize[COL_KIND]()[ttype], lh):
                continue
            for rep in range(3):
                var e = oracle_case(tables, tx, ttype, 12, rng)
                cases += 1
                if e > worst:
                    worst = e
                if e > 2:
                    check("oracle", False, "tx=" + String(tx) + " type=" + String(ttype) + " maxerr=" + String(e))
    print("oracle cases", cases, "worst |int - float| =", worst)

    print("PASS av1recon")
