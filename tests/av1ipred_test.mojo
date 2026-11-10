"""Lane B gate for src/imkit/av1ipred.mojo (spec 7.11.2 intra, 7.11.4 palette, 7.11.5 chroma from luma).

(1) Hand-computed blocks on a hand-built frame: DC, V, H, Paeth, the three smooth modes, directional 45, 90, 180, 203, at 4x4
    and 8x8 (numbers worked from the spec formulas, shown in the comments).
(2) Palette prediction, and the bad-input guards.
(3) tests/data/av1ipred_cases.txt, written by tools/av1ipred_oracle.py (a separate transliteration of the spec in Python, tables
    parsed from the spec text): 600 random intra blocks (every mode, delta, size, neighbour flags, edge filter, upsampling,
    filter intra, 8/10/12 bit, subsampling, frame-edge overhang) and 150 CFL blocks; the block must match and no other sample
    of any plane may change. Run through tests/av1ipred_test.sh."""
from imkit.av1frame import Frame
from imkit.av1tab import Tables
from imkit.av1ipred import (
    IntraInput, predict_intra, predict_palette, predict_chroma_from_luma,
)

comptime M64 = 6364136223846793005
comptime C64 = 1442695040888963407


def check(name: String, ok: Bool, detail: String = "") raises:
    if not ok:
        print("FAIL", name, detail)
        raise Error("av1ipred_test: " + name)


def lcg_fill(mut f: Frame, plane: Int, seed: Int, maxv: Int):
    var s = UInt64(seed) * UInt64(M64) + UInt64(C64)
    var w = f.planes[plane].w
    var h = f.planes[plane].h
    for i in range(w * h):
        s = s * UInt64(M64) + UInt64(C64)
        f.planes[plane].px[i] = UInt16(Int((s >> 33) % UInt64(maxv + 1)))


def blank(w: Int, h: Int, bd: Int = 8) -> Frame:
    return Frame(w, h, bd, 0, 0, 3)


def inp_for(w: Int, h: Int) -> IntraInput:
    var i = IntraInput()
    i.mi_cols = w // 4
    i.mi_rows = h // 4
    return i^


def put_edges(mut f: Frame, x: Int, y: Int, w: Int, a: List[Int], l: List[Int], corner: Int):
    """Above row at y - 1 (x..), left column at x - 1 (y..), corner at (x - 1, y - 1)."""
    for j in range(len(a)):
        f.planes[0].set(x + j, y - 1, a[j])
    for i in range(len(l)):
        f.planes[0].set(x - 1, y + i, l[i])
    f.planes[0].set(x - 1, y - 1, corner)


def run(mut f: Frame, t: Tables, inp: IntraInput, x: Int, y: Int, mode: Int, lw: Int, lh: Int, hl: Bool = True, ha: Bool = True,
        har: Bool = False, hbl: Bool = False) raises:
    predict_intra(f, t, inp, 0, x, y, hl, ha, har, hbl, mode, lw, lh)


def px(f: Frame, x: Int, y: Int) -> Int:
    return f.planes[0].get(x, y)


def rd(tok: StringSlice) raises -> Int:
    return Int(tok)


def main() raises:
    var t = Tables()
    var A: List[Int] = [10, 20, 30, 40]
    var L: List[Int] = [50, 60, 70, 80]

    # ---- (1) hand-computed 4x4 at (4, 4) of a 16x16 plane; no above-right / below-left, edge filter off
    var f = blank(16, 16)
    var inp = inp_for(16, 16)
    put_edges(f, 4, 4, 4, A, L, 5)
    run(f, t, inp, 4, 4, 1, 2, 2)  # V_PRED: every row is AboveRow
    var ok = True
    for i in range(4):
        for j in range(4):
            if px(f, 4 + j, 4 + i) != A[j]:
                ok = False
    check("v4x4", ok)

    f = blank(16, 16)
    put_edges(f, 4, 4, 4, A, L, 5)
    run(f, t, inp, 4, 4, 2, 2, 2)  # H_PRED: every column is LeftCol
    ok = True
    for i in range(4):
        for j in range(4):
            if px(f, 4 + j, 4 + i) != L[i]:
                ok = False
    check("h4x4", ok)

    f = blank(16, 16)
    put_edges(f, 4, 4, 4, A, L, 5)
    run(f, t, inp, 4, 4, 0, 2, 2)  # DC: (10+20+30+40 + 50+60+70+80 + 4) / 8 = 364 / 8 = 45
    check("dc4x4", px(f, 4, 4) == 45 and px(f, 7, 7) == 45)

    f = blank(16, 16)
    put_edges(f, 4, 4, 4, A, L, 5)
    run(f, t, inp, 4, 4, 0, 2, 2, hl=False)  # above only: (100 + 2) >> 2 = 25
    check("dc4x4-above", px(f, 5, 6) == 25)
    f = blank(16, 16)
    put_edges(f, 4, 4, 4, A, L, 5)
    run(f, t, inp, 4, 4, 0, 2, 2, ha=False)  # left only: (260 + 2) >> 2 = 65
    check("dc4x4-left", px(f, 5, 6) == 65)
    f = blank(16, 16)
    run(f, t, inp, 0, 0, 0, 2, 2, hl=False, ha=False)  # neither: 128
    check("dc4x4-none", px(f, 0, 0) == 128 and px(f, 3, 3) == 128)

    # Paeth, left wins when A <= L: pLeft = A - 5 <= pTop = L - 5, pLeft <= pTL
    f = blank(16, 16)
    put_edges(f, 4, 4, 4, A, L, 5)
    run(f, t, inp, 4, 4, 12, 2, 2)
    ok = True
    for i in range(4):
        for j in range(4):
            if px(f, 4 + j, 4 + i) != L[i]:
                ok = False
    check("paeth4x4-left", ok)
    # A = 100..130, L = 10..40: pTop = L - 5 < pLeft, pTop <= pTL = A + L - 10 -> above
    f = blank(16, 16)
    put_edges(f, 4, 4, 4, [100, 110, 120, 130], [10, 20, 30, 40], 5)
    run(f, t, inp, 4, 4, 12, 2, 2)
    ok = True
    for i in range(4):
        for j in range(4):
            if px(f, 4 + j, 4 + i) != 100 + 10 * j:
                ok = False
    check("paeth4x4-above", ok)
    # corner wins: A = L = 100..., corner 200: base = 100 + 100 - 200 = 0, pLeft = 100, pTop = 100, pTL = 200 -> left (pLeft <= pTop)
    # corner 20, A = 200, L = 190: base = 370, pLeft = 180, pTop = 170, pTL = 350 -> above
    f = blank(16, 16, 10)
    put_edges(f, 4, 4, 4, [200, 200, 200, 200], [190, 190, 190, 190], 20)
    run(f, t, inp, 4, 4, 12, 2, 2)
    check("paeth4x4-10bit", px(f, 5, 5) == 200)

    # Paeth tie pTop == pTL: corner 100, A = 80, L = 110: base = 90, pLeft = 20, pTop = 10, pTL = 10 -> above (80, not 100)
    f = blank(16, 16)
    put_edges(f, 4, 4, 4, [80, 80, 80, 80], [110, 110, 110, 110], 100)
    run(f, t, inp, 4, 4, 12, 2, 2)
    check("paeth4x4-tie", px(f, 5, 5) == 80)

    # smooth, weights 255 149 85 64
    f = blank(16, 16)
    put_edges(f, 4, 4, 4, A, L, 5)
    run(f, t, inp, 4, 4, 9, 2, 2)
    # (0,0): 255*10 + 1*80 + 255*50 + 1*40 = 15420 -> (15420 + 256) >> 9 = 30; (3,3): 64*40 + 192*80 + 64*80 + 192*40 = 30720 -> 60
    check("smooth4x4", px(f, 4, 4) == 30 and px(f, 7, 7) == 60, String(px(f, 4, 4)) + " " + String(px(f, 7, 7)))
    f = blank(16, 16)
    put_edges(f, 4, 4, 4, A, L, 5)
    run(f, t, inp, 4, 4, 10, 2, 2)
    # SMOOTH_V (0,0): 255*10 + 1*80 = 2630 -> (2630 + 128) >> 8 = 10; (row 3, col 2): 64*30 + 192*80 = 17280 -> 68
    check("smooth-v4x4", px(f, 4, 4) == 10 and px(f, 6, 7) == 68, String(px(f, 4, 4)) + " " + String(px(f, 6, 7)))
    f = blank(16, 16)
    put_edges(f, 4, 4, 4, A, L, 5)
    run(f, t, inp, 4, 4, 11, 2, 2)
    # SMOOTH_H (0,0): 255*50 + 1*40 = 12790 -> 50; (row 2, col 3): 64*70 + 192*40 = 12160 -> 48
    check("smooth-h4x4", px(f, 4, 4) == 50 and px(f, 7, 6) == 48, String(px(f, 4, 4)) + " " + String(px(f, 7, 6)))

    # D45 (pAngle 45, dx = 64): pred[i][j] = AboveRow[i + j + 1], AboveRow[4..7] = 40 (no above-right)
    f = blank(16, 16)
    put_edges(f, 4, 4, 4, A, L, 5)
    run(f, t, inp, 4, 4, 3, 2, 2)
    var d45 = [20, 30, 40, 40, 30, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40]
    ok = True
    for i in range(4):
        for j in range(4):
            if px(f, 4 + j, 4 + i) != d45[i * 4 + j]:
                ok = False
    check("d45-4x4", ok)

    # D203 (pAngle 203, dy = Dr[67] = 27), LeftCol[4..7] = 80: idx = (j + 1) * 27, base = (idx >> 6) + i, shift = (idx >> 1) & 31
    f = blank(16, 16)
    put_edges(f, 4, 4, 4, A, L, 5)
    run(f, t, inp, 4, 4, 7, 2, 2)
    # j = 0: shift 13: (50*19 + 60*13 + 16) >> 5 = 54, 64, 74, 80; (0, 1): shift 27: (50*5 + 60*27 + 16) >> 5 = 58;
    # (0, 2): idx 81, base 1, shift 8: (60*24 + 70*8 + 16) >> 5 = 63
    check("d203-4x4", px(f, 4, 4) == 54 and px(f, 4, 5) == 64 and px(f, 4, 6) == 74 and px(f, 4, 7) == 80
          and px(f, 5, 4) == 58 and px(f, 6, 4) == 63,
          String(px(f, 4, 4)) + " " + String(px(f, 4, 5)) + " " + String(px(f, 4, 6)) + " " + String(px(f, 4, 7)) + " "
          + String(px(f, 5, 4)) + " " + String(px(f, 6, 4)))

    # ---- 8x8 at (8, 8) of a 24x24 plane: A = 10..80, L = 100..170, corner 5
    var A8: List[Int] = [10, 20, 30, 40, 50, 60, 70, 80]
    var L8: List[Int] = [100, 110, 120, 130, 140, 150, 160, 170]
    var inp24 = inp_for(24, 24)
    f = blank(24, 24)
    put_edges(f, 8, 8, 8, A8, L8, 5)
    run(f, t, inp24, 8, 8, 0, 3, 3)  # DC: (1080 + 360 + 8) / 16 = 90
    check("dc8x8", px(f, 8, 8) == 90 and px(f, 15, 15) == 90)
    f = blank(24, 24)
    put_edges(f, 8, 8, 8, A8, L8, 5)
    run(f, t, inp24, 8, 8, 9, 3, 3)
    # SMOOTH (0,0): 255*10 + 170 + 255*100 + 80 = 28300 -> 55; (7,7): 32*80 + 224*170 + 32*170 + 224*80 = 64000 -> 125
    check("smooth8x8", px(f, 8, 8) == 55 and px(f, 15, 15) == 125, String(px(f, 8, 8)) + " " + String(px(f, 15, 15)))
    f = blank(24, 24)
    put_edges(f, 8, 8, 8, A8, L8, 5)
    run(f, t, inp24, 8, 8, 1, 3, 3)
    check("v8x8", px(f, 8, 8) == 10 and px(f, 15, 15) == 80 and px(f, 11, 9) == 40)
    f = blank(24, 24)
    put_edges(f, 8, 8, 8, A8, L8, 5)
    run(f, t, inp24, 8, 8, 2, 3, 3)
    check("h8x8", px(f, 8, 8) == 100 and px(f, 15, 15) == 170 and px(f, 9, 11) == 130)
    f = blank(24, 24)
    put_edges(f, 8, 8, 8, A8, L8, 5)
    run(f, t, inp24, 8, 8, 3, 3, 3)  # D45: AboveRow[i + j + 1], 80 beyond AboveRow[7] -> (0,0) = 20, (6,0) = 80, (3,4) = 80
    check("d45-8x8", px(f, 8, 8) == 20 and px(f, 14, 8) == 80 and px(f, 8 + 4, 8 + 3) == 80 and px(f, 8 + 1, 8 + 2) == 50)

    # directional 90 / 180 with an angle delta of zero are V / H exactly, even with the edge filter enabled
    inp24.enable_intra_edge_filter = True
    f = blank(24, 24)
    put_edges(f, 8, 8, 8, A8, L8, 5)
    run(f, t, inp24, 8, 8, 1, 3, 3)
    check("v8x8-filter-on", px(f, 8, 8) == 10 and px(f, 15, 15) == 80)

    # ---- (2) palette: CurrFrame[start + (i, j)] = palette[map[y * 4 + i][x * 4 + j]], x and y in 4x4 units
    f = blank(16, 16)
    var pal: List[UInt16] = [7, 100, 200, 300]
    var cmap = List[UInt8](length=64, fill=0)  # 8 x 8 map, stride 8
    for i in range(64):
        cmap[i] = UInt8(i % 4)
    predict_palette(f, 0, 4, 4, 1, 0, 0, pal, cmap, 8)  # TX_4X4 at map unit (1, 0): columns 4..7 of rows 0..3
    check("palette", px(f, 4, 4) == 7 and px(f, 5, 4) == 100 and px(f, 7, 4) == 300 and px(f, 5, 7) == 100 and px(f, 8, 4) == 0)
    var raised = 0
    var tries = 0
    for k in range(4):
        tries += 1
        try:
            if k == 0:
                cmap[4] = 9
                predict_palette(f, 0, 4, 4, 1, 0, 0, pal, cmap, 8)  # index 9 >= 4 colours
            elif k == 1:
                predict_palette(f, 0, 4, 4, 2, 2, 0, pal, cmap, 8)  # map too small
            elif k == 2:
                predict_palette(f, 0, 40, 4, 0, 0, 0, pal, cmap, 8)  # outside plane
            else:
                predict_palette(f, 0, 4, 4, 0, 0, 19, pal, cmap, 8)  # bad tx size
        except e:
            raised += 1
    check("palette-raises", raised == tries, String(raised))
    raised = 0
    tries = 0
    for k in range(5):
        tries += 1
        try:
            f = blank(16, 16)
            if k == 0:
                predict_intra(f, t, inp, 0, 4, 4, True, True, False, False, 13, 2, 2)  # UV_CFL_PRED is not an intra mode here
            elif k == 1:
                predict_intra(f, t, inp, 0, 0, 4, True, True, False, False, 0, 2, 2)  # have_left at x = 0
            elif k == 2:
                predict_intra(f, t, inp, 3, 4, 4, True, True, False, False, 0, 2, 2)  # bad plane
            elif k == 3:
                predict_intra(f, t, inp, 0, 4, 4, True, True, False, False, 0, 7, 2)  # bad size
            else:
                var big = inp_for(32, 32)  # MiCols * 4 larger than the plane
                predict_intra(f, t, big, 0, 4, 4, True, True, False, False, 0, 2, 2)
        except e:
            raised += 1
    check("intra-raises", raised == tries, String(raised))

    # ---- (3) oracle vectors
    var text = open("tests/data/av1ipred_cases.txt", "r").read()
    var nintra = 0
    var ncfl = 0
    for line in text.split("\n"):
        if line.byte_length() == 0:
            continue
        var parts = line.split("|")
        var h = parts[0].split(" ")
        var e = parts[1].split(" ")
        var kind = String(h[0])
        var seed = rd(h[1])
        var bd = rd(h[2])
        var sx = rd(h[3])
        var sy = rd(h[4])
        var mi_cols = rd(h[5])
        var mi_rows = rd(h[6])
        var plane = rd(h[7])
        var maxv = (1 << bd) - 1
        var g = Frame(mi_cols * 4, mi_rows * 4, bd, sx, sy, 3)
        var g0 = Frame(mi_cols * 4, mi_rows * 4, bd, sx, sy, 3)
        for k in range(3):
            lcg_fill(g, k, seed * 8 + k, maxv)
            lcg_fill(g0, k, seed * 8 + k, maxv)
        var bx = rd(h[8])
        var by = rd(h[9])
        var bw: Int
        var bh: Int
        # the expected list is the block clipped to the plane, row-major
        var pw = g.planes[plane].w
        var ph = g.planes[plane].h
        if kind == "INTRA":
            var ii = IntraInput()
            ii.mi_cols = mi_cols
            ii.mi_rows = mi_rows
            ii.angle_delta_y = rd(h[17])
            ii.angle_delta_uv = rd(h[18])
            ii.use_filter_intra = rd(h[19]) == 1
            ii.filter_intra_mode = rd(h[20])
            ii.enable_intra_edge_filter = rd(h[21]) == 1
            ii.filter_type = rd(h[22])
            var lw = rd(h[15])
            var lh = rd(h[16])
            bw = 1 << lw
            bh = 1 << lh
            predict_intra(g, t, ii, plane, bx, by, rd(h[10]) == 1, rd(h[11]) == 1, rd(h[12]) == 1, rd(h[13]) == 1, rd(h[14]), lw, lh)
            nintra += 1
        else:
            var tx = rd(h[10])
            var tw = Int(t.tx_width[tx])
            var th = Int(t.tx_height[tx])
            bw = tw
            bh = th
            predict_chroma_from_luma(g, plane, bx, by, tx, rd(h[11]), rd(h[12]), rd(h[13]))
            ncfl += 1
        var n = rd(e[1])
        var idx = 2
        var cases_ok = True
        var bad = ""
        for i in range(bh):
            for j in range(bw):
                if by + i < ph and bx + j < pw:
                    if g.planes[plane].get(bx + j, by + i) != rd(e[idx]):
                        cases_ok = False
                        bad = kind + " seed " + String(seed) + " at (" + String(j) + "," + String(i) + ") got " + String(g.planes[plane].get(bx + j, by + i)) + " want " + e[idx]
                    idx += 1
                    g0.planes[plane].set(bx + j, by + i, g.planes[plane].get(bx + j, by + i))
        check("oracle", cases_ok and (idx - 2 == n), bad)
        for k in range(3):
            var a = g.planes[k].px.copy()
            var b = g0.planes[k].px.copy()
            for q in range(len(a)):
                if a[q] != b[q]:
                    check("oracle-stray-write", False, kind + " seed " + String(seed) + " plane " + String(k))
    print("oracle vectors: intra", nintra, "cfl", ncfl)
    print("PASS av1ipred")
