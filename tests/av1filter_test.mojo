"""Hand-computed checks of the AV1 post filters (spec 7.14 to 7.17). Expected rows come from the spec formulas worked by hand
(see tools/av1_wide_oracle.py for the wide filter); no pixel oracle until lane A integrates. Prints PASS or FAIL lines."""
from imkit.av1frame import Frame
from imkit.av1lf import LfInput, loop_filter
from imkit.av1cdef import CdefInput, cdef, cdef_direction
from imkit.av1tab import Tables
from imkit.av1lr import LrInput, loop_restoration

def show(v: List[Int]) -> String:
    var s = String("")
    for x in v:
        s += String(x) + " "
    return s^


def check(name: String, got: List[Int], want: List[Int], mut failures: Int):
    if got != want:
        failures += 1
        print("FAIL", name, "got", show(got), "want", show(want))


def row_of(frame: Frame, plane: Int, y: Int, x0: Int, n: Int) -> List[Int]:
    var r = List[Int]()
    for x in range(x0, x0 + n):
        r.append(frame.planes[plane].get(x, y))
    return r^


def step_frame(w: Int, h: Int, bd: Int, planes: Int, a: Int, b: Int, at: Int) -> Frame:
    """4:2:0 frame whose every row is `a` left of luma x = at and `b` from there (chroma: at >> 1)."""
    var f = Frame(w, h, bd, 1, 1, planes)
    for p in range(planes):
        var edge = at if p == 0 else at >> 1
        for y in range(f.planes[p].h):
            for x in range(f.planes[p].w):
                f.planes[p].set(x, y, a if x < edge else b)
    return f^


def lf_for(w: Int, h: Int, planes: Int, mi_size: Int, tx: Int, lvl: Int) -> LfInput:
    var inp = LfInput(2 * ((h + 7) >> 3), 2 * ((w + 7) >> 3), w, h, planes)
    for i in range(len(inp.mi_sizes)):
        inp.mi_sizes[i] = UInt8(mi_size)
    for p in range(planes):
        for i in range(len(inp.lf_tx_sizes[p])):
            inp.lf_tx_sizes[p][i] = UInt8(tx)
    for i in range(4):
        inp.loop_filter_level[i] = lvl
    return inp^


def cdef_px(p: Int, x: Int, y: Int, bd: Int, style: Int) -> Int:
    var v: Int
    if style == 0:
        v = (x * 37 + y * 23 + ((x * y) % 11) * 17 + p * 50) % 256
    else:  # horizontal stripes of amplitude `style` with a small column ripple
        v = 128 + (style if y % 2 == 0 else -style) + ((x * 5 + y) % 3 - 1)
    return v if bd == 8 else v * 4 + x % 4


def checksum(frame: Frame, p: Int) -> Int:
    var cs = 0
    ref pl = frame.planes[p]
    for y in range(pl.h):
        for x in range(pl.w):
            cs = (cs + pl.get(x, y) * (y * pl.w + x + 1)) % 4294967296
    return cs


def cdef_case(name: String, bd: Int, sx: Int, sy: Int, style: Int, ypri: Int, want: List[Int], mut failures: Int) raises:
    """16x16 pseudo-random frame, idx 0 (4/2 luma, 3/1 chroma, damping 5), the 8x8 block at unit (2, 2) skipped.
    Expected checksums come from tools/av1_cdef_oracle.py (an independent transcription of spec 7.15)."""
    var pre = Frame(16, 16, bd, sx, sy, 3)
    for p in range(3):
        for y in range(pre.planes[p].h):
            for x in range(pre.planes[p].w):
                pre.planes[p].set(x, y, cdef_px(p, x, y, bd, style))
    var out = pre.copy()
    var inp = CdefInput(4, 4)
    inp.cdef_damping = 5
    inp.cdef_idx[0] = 0
    inp.cdef_y_pri_strength[0] = ypri
    inp.cdef_y_sec_strength[0] = 2
    inp.cdef_uv_pri_strength[0] = 3
    inp.cdef_uv_sec_strength[0] = 1
    for r in range(2, 4):
        for c in range(2, 4):
            inp.skips[r * 4 + c] = 1
    cdef(out, pre, inp)
    var got = List[Int]()
    for p in range(3):
        got.append(checksum(out, p))
    check(name, got, want, failures)
    # the skipped block must be untouched
    for y in range(8, 16):
        for x in range(8, 16):
            if out.planes[0].get(x, y) != pre.planes[0].get(x, y):
                failures += 1
                print("FAIL", name, "skipped block changed")
                return


def dir_of(kind: Int) raises -> Tuple[Int, Int]:
    """Stripe patterns: 0 anti-diagonal, 1 diagonal, 2 rows, 3 columns (200 / 56)."""
    var fr = Frame(8, 8, 8, 1, 1, 1)
    for i in range(8):
        for j in range(8):
            var hi: Bool
            if kind == 0:
                hi = (i + j) % 4 < 2
            elif kind == 1:
                hi = (i - j) % 4 < 2
            elif kind == 2:
                hi = i % 2 == 0
            else:
                hi = j % 2 == 0
            fr.planes[0].set(j, i, 200 if hi else 56)
    return cdef_direction(fr, Tables(), 0, 0)


def lr_case(name: String, bd: Int, sx: Int, sy: Int, fh: Int, uw: Int, sizes: List[Int], want: List[Int], mut failures: Int) raises:
    """Pseudo-random deblocked and CDEF frames, per-unit types / coefficients as tools/av1_lr_oracle.py (unit_params);
    expected checksums come from that oracle (spec 7.17 transcribed per 4x4 block)."""
    var pre = Frame(uw, fh, bd, sx, sy, 3)
    var cd = Frame(uw, fh, bd, sx, sy, 3)
    var top = (1 << bd) - 1
    for p in range(3):
        for y in range(pre.planes[p].h):
            for x in range(pre.planes[p].w):
                var v = (x * 29 + y * 31 + ((x * y) % 13) * 11 + p * 40) % 256
                if bd != 8:
                    v = v * 4 + x % 4
                pre.planes[p].set(x, y, v)
                var c = v + ((x + y) % 5 - 2) * (1 if bd == 8 else 4)
                cd.planes[p].set(x, y, max(0, min(top, c)))
    var inp = LrInput(fh, uw, sx, sy, 3, True, [3, 3, 3], sizes)
    for p in range(3):
        for u in range(inp.unit_rows[p] * inp.unit_cols[p]):
            inp.lr_type[p][u] = UInt8((u * 2 + p) % 3)
            inp.lr_wiener[p][u * 6 + 0] = ((u * 3) % 16) - 5 if p == 0 else 0
            inp.lr_wiener[p][u * 6 + 1] = -10 + u * 4
            inp.lr_wiener[p][u * 6 + 2] = 20 + u * 5
            inp.lr_wiener[p][u * 6 + 3] = ((u * 2) % 16) - 4 if p == 0 else 0
            inp.lr_wiener[p][u * 6 + 4] = -8 + u * 3
            inp.lr_wiener[p][u * 6 + 5] = 25 - u * 4
            inp.lr_sgr_set[p][u] = UInt8((u * 5 + p * 3 + 1) % 16)
            inp.lr_sgr_xqd[p][u * 2] = -20 + u * 7 + p
            inp.lr_sgr_xqd[p][u * 2 + 1] = 30 - u * 9 + p * 2
    var out = cd.copy()
    loop_restoration(out, cd, pre, inp)
    var got = List[Int]()
    for p in range(3):
        got.append(checksum(out, p))
    check(name, got, want, failures)


def main() raises:
    var failures = 0
    # BLOCK_16X16 = 6; TX_4X4 = 0, TX_8X8 = 1, TX_16X16 = 2
    var flat = Frame(32, 16, 8, 1, 1, 3)
    for p in range(3):
        for i in range(len(flat.planes[p].px)):
            flat.planes[p].px[i] = 128
    var inp = lf_for(32, 16, 3, 6, 0, 30)
    loop_filter(flat, inp)
    for p in range(3):
        for i in range(len(flat.planes[p].px)):
            if flat.planes[p].px[i] != 128:
                failures += 1
                print("FAIL flat frame changed in plane", p)
                break

    # 4-tap (narrow): 100 | 110, lvl 10: ps0 -28, qs0 -18, f 30, f1 4, f2 4, outer f 2 -> 102 104 | 106 108
    var f = step_frame(32, 16, 8, 1, 100, 110, 16)
    loop_filter(f, lf_for(32, 16, 1, 6, 0, 10))
    var want: List[Int] = [100, 100, 100, 100, 100, 100, 102, 104, 106, 108, 110, 110, 110, 110, 110, 110]
    for y in [0, 7, 15]:
        check("narrow y=" + String(y), row_of(f, 0, y, 8, 16), want, failures)

    # 8-tap luma wide filter (log2 3, n 3): 101 103 104 | 106 108 109
    f = step_frame(32, 16, 8, 1, 100, 110, 16)
    loop_filter(f, lf_for(32, 16, 1, 6, 1, 10))
    check("wide8", row_of(f, 0, 5, 8, 16), [100, 100, 100, 100, 100, 101, 103, 104, 106, 108, 109, 110, 110, 110, 110, 110], failures)

    # 14-tap luma wide filter (log2 4, n 6), 16 wide transforms
    f = step_frame(32, 16, 8, 1, 100, 110, 16)
    loop_filter(f, lf_for(32, 16, 1, 6, 2, 10))
    check("wide16", row_of(f, 0, 5, 8, 16), [100, 100, 101, 101, 102, 103, 103, 104, 106, 107, 108, 108, 109, 109, 110, 110], failures)

    # 10-bit narrow: 400 | 440 (thresholds shift by 2): 408 415 | 425 432
    f = step_frame(32, 16, 10, 1, 400, 440, 16)
    loop_filter(f, lf_for(32, 16, 1, 6, 0, 10))
    check("narrow10", row_of(f, 0, 3, 8, 16), [400, 400, 400, 400, 400, 400, 408, 415, 425, 432, 440, 440, 440, 440, 440, 440], failures)

    # chroma 6-tap (log2 3, plane > 0: n 2, n2 1) at chroma x 8; V has level 0 and stays a step; luma flat
    f = step_frame(32, 16, 8, 3, 100, 110, 16)
    for i in range(len(f.planes[0].px)):
        f.planes[0].px[i] = 128
    inp = lf_for(32, 16, 3, 6, 1, 10)
    inp.loop_filter_level[3] = 0
    loop_filter(f, inp)
    check("chroma6 U", row_of(f, 1, 2, 0, 16), [100, 100, 100, 100, 100, 100, 101, 104, 106, 109, 110, 110, 110, 110, 110, 110], failures)
    check("chroma6 V untouched", row_of(f, 2, 2, 0, 16), [100, 100, 100, 100, 100, 100, 100, 100, 110, 110, 110, 110, 110, 110, 110, 110], failures)

    # mask rejects a big step (2 * 40 + 20 > blimit 34): unchanged
    f = step_frame(32, 16, 8, 1, 100, 140, 16)
    loop_filter(f, lf_for(32, 16, 1, 6, 0, 10))
    check("mask reject", row_of(f, 0, 0, 14, 4), [100, 100, 140, 140], failures)

    # level 0 everywhere: nothing runs
    f = step_frame(32, 16, 8, 1, 100, 110, 16)
    loop_filter(f, lf_for(32, 16, 1, 6, 0, 0))
    check("level 0", row_of(f, 0, 0, 14, 4), [100, 100, 110, 110], failures)

    # step 13: blimit(lvl 9) = 31 < 2*13 + 6 = 32 <= blimit(lvl 10) = 34, so lvl 9 does nothing and lvl 9 + ref delta 1 filters
    f = step_frame(32, 16, 8, 1, 100, 113, 16)
    loop_filter(f, lf_for(32, 16, 1, 6, 0, 9))
    check("lvl9 plain", row_of(f, 0, 0, 14, 4), [100, 100, 113, 113], failures)
    f = step_frame(32, 16, 8, 1, 100, 113, 16)
    inp = lf_for(32, 16, 1, 6, 0, 9)
    inp.loop_filter_delta_enabled = True  # RefFrames = INTRA_FRAME: ref_deltas[0] = 1
    loop_filter(f, inp)
    check("lvl9 + delta", row_of(f, 0, 0, 14, 4), [103, 105, 108, 110], failures)

    # segment feature ALT_LF_Y_V (feature 1) of segment 0 lifts level 0 to 10: same result as the plain narrow case
    f = step_frame(32, 16, 8, 1, 100, 110, 16)
    inp = lf_for(32, 16, 1, 6, 0, 0)
    inp.seg_feature_enabled[1] = True
    inp.seg_feature_data[1] = 10
    loop_filter(f, inp)
    check("segment lvl", row_of(f, 0, 0, 14, 4), [102, 104, 106, 108], failures)

    # hev (thresh = lvl >> 4 = 1, |p1 - p0| = 2): only p0 / q0 change: 101 105 | 111 113
    f = step_frame(32, 16, 8, 1, 101, 113, 16)
    for y in range(16):
        f.planes[0].set(15, y, 103)
    loop_filter(f, lf_for(32, 16, 1, 6, 0, 16))
    check("hev", row_of(f, 0, 4, 14, 4), [101, 105, 111, 113], failures)

    # level 40 + ref delta 1 << (40 >> 5) = 42: blimit 130, so step 53 (132) is rejected and step 52 (130) is filtered
    f = step_frame(32, 16, 8, 1, 100, 153, 16)
    inp = lf_for(32, 16, 1, 6, 0, 40)
    inp.loop_filter_delta_enabled = True
    loop_filter(f, inp)
    check("nshift reject", row_of(f, 0, 0, 14, 4), [100, 100, 153, 153], failures)
    f = step_frame(32, 16, 8, 1, 100, 152, 16)
    loop_filter(f, inp)
    check("nshift accept", row_of(f, 0, 0, 14, 4), [108, 115, 137, 144], failures)

    # unit right of the edge has level 0, the unit left of it (col 3) has DeltaLF +10: the edge takes the previous unit's level
    f = step_frame(32, 16, 8, 1, 100, 110, 16)
    inp = lf_for(32, 16, 1, 6, 0, 0)
    for r in range(4):
        inp.delta_lfs[(r * 8 + 3) * 4] = 10
    loop_filter(f, inp)
    check("prev unit level", row_of(f, 0, 0, 14, 4), [102, 104, 106, 108], failures)

    # CDEF: flat frame stays flat with every strength set
    var cp = Frame(16, 16, 8, 1, 1, 3)
    for p in range(3):
        for i in range(len(cp.planes[p].px)):
            cp.planes[p].px[i] = 77
    var cout = cp.copy()
    var cinp = CdefInput(4, 4)
    cinp.cdef_idx[0] = 0
    cinp.cdef_y_pri_strength[0] = 15
    cinp.cdef_y_sec_strength[0] = 4
    cinp.cdef_uv_pri_strength[0] = 15
    cinp.cdef_uv_sec_strength[0] = 4
    cdef(cout, cp, cinp)
    for p in range(3):
        for i in range(len(cout.planes[p].px)):
            if cout.planes[p].px[i] != 77:
                failures += 1
                print("FAIL cdef flat changed in plane", p)
                break

    # CDEF direction search on stripes (values from the oracle: dir, var)
    var d = dir_of(0)
    check("dir anti-diagonal", [d[0], d[1]], [0, 257904], failures)
    d = dir_of(1)
    check("dir diagonal", [d[0], d[1]], [4, 257904], failures)
    d = dir_of(2)
    check("dir rows", [d[0], d[1]], [2, 272160], failures)
    d = dir_of(3)
    check("dir cols", [d[0], d[1]], [6, 272160], failures)

    cdef_case("cdef 8-bit 420", 8, 1, 1, 0, 4, [4259339, 281442, 285346], failures)
    cdef_case("cdef 10-bit 420", 10, 1, 1, 0, 4, [17088984, 1129010, 1144626], failures)
    cdef_case("cdef 8-bit 444", 8, 0, 0, 0, 4, [4259339, 4031029, 4525379], failures)
    cdef_case("cdef var_str 2 (var 477)", 8, 1, 1, 3, 4, [4204378, 265427, 265427], failures)
    cdef_case("cdef var_str 12 (var 272278)", 8, 1, 1, 72, 15, [4063013, 247761, 247761], failures)
    cdef_case("cdef var_str 13 (var 756196)", 8, 1, 1, 120, 15, [3964709, 235473, 235473], failures)
    cdef_case("cdef 8-bit 422", 8, 1, 0, 0, 4, [4259339, 1065841, 1127905], failures)

    lr_case("lr 8-bit 420", 8, 1, 1, 100, 100, [64, 32, 32], [2087952885, 397919868, 394847886], failures)
    lr_case("lr 10-bit 420", 10, 1, 1, 100, 100, [64, 32, 32], [4131646498, 1596227082, 1583994783], failures)
    lr_case("lr 8-bit 444", 8, 0, 0, 70, 90, [64, 64, 64], [2555199730, 2530183361, 2515035396], failures)
    lr_case("lr 8-bit 422", 8, 1, 0, 90, 66, [64, 64, 64], [2250325124, 561384703, 568675589], failures)
    lr_case("lr 8-bit 420 odd size", 8, 1, 1, 75, 71, [64, 32, 32], [1827391241, 120472115, 117237280], failures)

    if failures == 0:
        print("PASS av1filter")
    else:
        print("FAIL av1filter:", failures, "checks")
