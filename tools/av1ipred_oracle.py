#!/usr/bin/env python3
"""Oracle for src/imkit/av1ipred.mojo: a literal transliteration of spec 7.11.2 (intra prediction) and 7.11.5 (chroma from
luma), written from the spec text with the spec's own names, tables read from the spec (10.additional.tables.md).
Writes tests/data/av1ipred_cases.txt, one case per line; tests/av1ipred_test.mojo regenerates each frame from the seed with the
same LCG, runs the Mojo code and compares. Usage: tools/av1ipred_oracle.py SPEC_DIR OUT_FILE [NCASES]
Python is only the oracle here: this file is not part of the build."""
import re
import sys
import random

SPEC = sys.argv[1]
OUT = sys.argv[2]
NCASES = int(sys.argv[3]) if len(sys.argv) > 3 else 600
M64 = (1 << 64) - 1

tabs = open(SPEC + "/10.additional.tables.md").read()
dec = open(SPEC + "/08.decoding.process.md").read()


def table(text, name):
    """Numbers of the first `Name[...] = { ... }` definition (balanced braces)."""
    m = re.search(r"^" + name + r"\s*\[[^=\n]*=\s*\{", text, re.M)
    k, depth = m.end() - 1, 0
    for e in range(k, len(text)):
        depth += (text[e] == "{") - (text[e] == "}")
        if depth == 0:
            return [int(v) for v in re.findall(r"-?\d+", text[k:e])]


Dr_Intra_Derivative = table(tabs, "Dr_Intra_Derivative")
Mode_To_Angle = table(tabs, "Mode_To_Angle")
Intra_Filter_Taps = table(tabs, "Intra_Filter_Taps")
Intra_Edge_Kernel = table(dec, "Intra_Edge_Kernel")
Tx_Width_Log2 = table(tabs, "Tx_Width_Log2")
Tx_Height_Log2 = table(tabs, "Tx_Height_Log2")
Sm = {2: table(tabs, "Sm_Weights_Tx_4x4"), 3: table(tabs, "Sm_Weights_Tx_8x8"), 4: table(tabs, "Sm_Weights_Tx_16x16"),
      5: table(tabs, "Sm_Weights_Tx_32x32"), 6: table(tabs, "Sm_Weights_Tx_64x64")}
assert len(Dr_Intra_Derivative) == 90 and len(Mode_To_Angle) == 13 and len(Intra_Filter_Taps) == 5 * 8 * 7
assert len(Intra_Edge_Kernel) == 15 and len(Tx_Width_Log2) == 19 and [len(Sm[k]) for k in Sm] == [4, 8, 16, 32, 64]

DC_PRED, V_PRED, H_PRED, D45, D135, D113, D157, D203, D67, SMOOTH, SMOOTH_V, SMOOTH_H, PAETH = range(13)


def Round2(x, n):
    return x if n == 0 else (x + (1 << (n - 1))) >> n


def Round2Signed(x, n):
    return Round2(x, n) if x >= 0 else -Round2(-x, n)


def lcg_frame(seed, w, h, maxv):
    s = (seed * 6364136223846793005 + 1442695040888963407) & M64
    out = []
    for _ in range(w * h):
        s = (s * 6364136223846793005 + 1442695040888963407) & M64
        out.append((s >> 33) % (maxv + 1))
    return out


class Frame:
    def __init__(self, seed, bd, sx, sy, mi_cols, mi_rows, nplanes):
        self.bd, self.sx, self.sy = bd, sx, sy
        self.mi_cols, self.mi_rows = mi_cols, mi_rows
        W, H = mi_cols * 4, mi_rows * 4
        self.dims = [(W, H)] + [((W + sx) >> sx, (H + sy) >> sy)] * (nplanes - 1)
        self.p = []
        for k, (w, h) in enumerate(self.dims):
            v = lcg_frame(seed * 8 + k, w, h, (1 << bd) - 1)
            self.p.append([v[r * w:(r + 1) * w] for r in range(h)])


def Clip1(f, v):
    return max(0, min((1 << f.bd) - 1, v))


def predict_intra(f, plane, x, y, haveLeft, haveAbove, haveAboveRight, haveBelowLeft, mode, log2W, log2H,
                  AngleDeltaY, AngleDeltaUV, use_filter_intra, filter_intra_mode, enable_intra_edge_filter, filterType):
    w, h = 1 << log2W, 1 << log2H
    maxX = f.mi_cols * 4 - 1
    maxY = f.mi_rows * 4 - 1
    if plane > 0:
        maxX = ((f.mi_cols * 4) >> f.sx) - 1
        maxY = ((f.mi_rows * 4) >> f.sy) - 1
    CF = f.p[plane]
    BD = f.bd
    AboveRow, LeftCol = {}, {}
    for i in range(w + h):
        if not haveAbove and haveLeft:
            AboveRow[i] = CF[y][x - 1]
        elif not haveAbove and not haveLeft:
            AboveRow[i] = (1 << (BD - 1)) - 1
        else:
            aboveLimit = min(maxX, x + (2 * w if haveAboveRight else w) - 1)
            AboveRow[i] = CF[y - 1][min(aboveLimit, x + i)]
        if not haveLeft and haveAbove:
            LeftCol[i] = CF[y - 1][x]
        elif not haveLeft and not haveAbove:
            LeftCol[i] = (1 << (BD - 1)) + 1
        else:
            leftLimit = min(maxY, y + (2 * h if haveBelowLeft else h) - 1)
            LeftCol[i] = CF[min(leftLimit, y + i)][x - 1]
    if haveAbove and haveLeft:
        AboveRow[-1] = CF[y - 1][x - 1]
    elif haveAbove:
        AboveRow[-1] = CF[y - 1][x]
    elif haveLeft:
        AboveRow[-1] = CF[y][x - 1]
    else:
        AboveRow[-1] = 1 << (BD - 1)
    LeftCol[-1] = AboveRow[-1]

    pred = [[0] * w for _ in range(h)]
    if plane == 0 and use_filter_intra:
        w4, h2 = w >> 2, h >> 1
        for i2 in range(h2):
            for j4 in range(w4):
                p = [0] * 7
                for i in range(7):
                    if i < 5:
                        if i2 == 0:
                            p[i] = AboveRow[(j4 << 2) + i - 1]
                        elif j4 == 0 and i == 0:
                            p[i] = LeftCol[(i2 << 1) - 1]
                        else:
                            p[i] = pred[(i2 << 1) - 1][(j4 << 2) + i - 1]
                    else:
                        if j4 == 0:
                            p[i] = LeftCol[(i2 << 1) + i - 5]
                        else:
                            p[i] = pred[(i2 << 1) + i - 5][(j4 << 2) - 1]
                for i1 in range(2):
                    for j1 in range(4):
                        pr = 0
                        for i in range(7):
                            pr += Intra_Filter_Taps[(filter_intra_mode * 8 + (i1 << 2) + j1) * 7 + i] * p[i]
                        pred[(i2 << 1) + i1][(j4 << 2) + j1] = Clip1(f, Round2Signed(pr, 4))
    elif 1 <= mode <= 8:
        angleDelta = AngleDeltaY if plane == 0 else AngleDeltaUV
        pAngle = Mode_To_Angle[mode] + angleDelta * 3
        upsampleAbove = upsampleLeft = 0

        def strength_sel(delta):
            d = abs(delta)
            blkWh = w + h
            s = 0
            if filterType == 0:
                if blkWh <= 8:
                    if d >= 56: s = 1
                elif blkWh <= 12:
                    if d >= 40: s = 1
                elif blkWh <= 16:
                    if d >= 40: s = 1
                elif blkWh <= 24:
                    if d >= 8: s = 1
                    if d >= 16: s = 2
                    if d >= 32: s = 3
                elif blkWh <= 32:
                    s = 1
                    if d >= 4: s = 2
                    if d >= 32: s = 3
                else:
                    s = 3
            else:
                if blkWh <= 8:
                    if d >= 40: s = 1
                    if d >= 64: s = 2
                elif blkWh <= 16:
                    if d >= 20: s = 1
                    if d >= 48: s = 2
                elif blkWh <= 24:
                    if d >= 4: s = 3
                else:
                    s = 3
            return s

        def upsample_sel(delta):
            d = abs(delta)
            if d <= 0 or d >= 40:
                return 0
            return int(w + h <= 16) if filterType == 0 else int(w + h <= 8)

        def edge_filter(buf, sz, strength):
            if strength == 0:
                return
            edge = [buf[i - 1] for i in range(sz)]
            for i in range(1, sz):
                s = 0
                for j in range(5):
                    k = max(0, min(sz - 1, i - 2 + j))
                    s += Intra_Edge_Kernel[(strength - 1) * 5 + j] * edge[k]
                buf[i - 1] = (s + 8) >> 4

        def edge_upsample(buf, numPx):
            dup = [0] * (numPx + 3)
            dup[0] = buf[-1]
            for i in range(-1, numPx):
                dup[i + 2] = buf[i]
            dup[numPx + 2] = buf[numPx - 1]
            buf[-2] = dup[0]
            for i in range(numPx):
                s = -dup[i] + 9 * dup[i + 1] + 9 * dup[i + 2] - dup[i + 3]
                s = Clip1(f, Round2(s, 4))
                buf[2 * i - 1] = s
                buf[2 * i] = dup[i + 2]

        if enable_intra_edge_filter:
            if pAngle != 90 and pAngle != 180:
                if pAngle > 90 and pAngle < 180 and (w + h) >= 24:
                    s = LeftCol[0] * 5 + AboveRow[-1] * 6 + AboveRow[0] * 5
                    LeftCol[-1] = AboveRow[-1] = Round2(s, 4)
                if haveAbove:
                    strength = strength_sel(pAngle - 90)
                    numPx = min(w, maxX - x + 1) + (h if pAngle < 90 else 0) + 1
                    edge_filter(AboveRow, numPx, strength)
                if haveLeft:
                    strength = strength_sel(pAngle - 180)
                    numPx = min(h, maxY - y + 1) + (w if pAngle > 180 else 0) + 1
                    edge_filter(LeftCol, numPx, strength)
                upsampleAbove = upsample_sel(pAngle - 90)
                if upsampleAbove:
                    edge_upsample(AboveRow, w + (h if pAngle < 90 else 0))
                upsampleLeft = upsample_sel(pAngle - 180)
                if upsampleLeft:
                    edge_upsample(LeftCol, h + (w if pAngle > 180 else 0))
        dx = dy = None
        if pAngle < 90:
            dx = Dr_Intra_Derivative[pAngle]
        elif 90 < pAngle < 180:
            dx = Dr_Intra_Derivative[180 - pAngle]
        if 90 < pAngle < 180:
            dy = Dr_Intra_Derivative[pAngle - 90]
        elif pAngle > 180:
            dy = Dr_Intra_Derivative[270 - pAngle]
        for i in range(h):
            for j in range(w):
                if pAngle < 90:
                    idx = (i + 1) * dx
                    base = (idx >> (6 - upsampleAbove)) + (j << upsampleAbove)
                    shift = ((idx << upsampleAbove) >> 1) & 0x1F
                    maxBaseX = (w + h - 1) << upsampleAbove
                    if base < maxBaseX:
                        pred[i][j] = Round2(AboveRow[base] * (32 - shift) + AboveRow[base + 1] * shift, 5)
                    else:
                        pred[i][j] = AboveRow[maxBaseX]
                elif 90 < pAngle < 180:
                    idx = (j << 6) - (i + 1) * dx
                    base = idx >> (6 - upsampleAbove)
                    if base >= -(1 << upsampleAbove):
                        shift = ((idx << upsampleAbove) >> 1) & 0x1F
                        pred[i][j] = Round2(AboveRow[base] * (32 - shift) + AboveRow[base + 1] * shift, 5)
                    else:
                        idx = (i << 6) - (j + 1) * dy
                        base = idx >> (6 - upsampleLeft)
                        shift = ((idx << upsampleLeft) >> 1) & 0x1F
                        pred[i][j] = Round2(LeftCol[base] * (32 - shift) + LeftCol[base + 1] * shift, 5)
                elif pAngle > 180:
                    idx = (j + 1) * dy
                    base = (idx >> (6 - upsampleLeft)) + (i << upsampleLeft)
                    shift = ((idx << upsampleLeft) >> 1) & 0x1F
                    pred[i][j] = Round2(LeftCol[base] * (32 - shift) + LeftCol[base + 1] * shift, 5)
                elif pAngle == 90:
                    pred[i][j] = AboveRow[j]
                else:
                    pred[i][j] = LeftCol[i]
    elif mode == SMOOTH:
        for i in range(h):
            for j in range(w):
                s = (Sm[log2H][i] * AboveRow[j] + (256 - Sm[log2H][i]) * LeftCol[h - 1]
                     + Sm[log2W][j] * LeftCol[i] + (256 - Sm[log2W][j]) * AboveRow[w - 1])
                pred[i][j] = Round2(s, 9)
    elif mode == SMOOTH_V:
        for i in range(h):
            for j in range(w):
                pred[i][j] = Round2(Sm[log2H][i] * AboveRow[j] + (256 - Sm[log2H][i]) * LeftCol[h - 1], 8)
    elif mode == SMOOTH_H:
        for i in range(h):
            for j in range(w):
                pred[i][j] = Round2(Sm[log2W][j] * LeftCol[i] + (256 - Sm[log2W][j]) * AboveRow[w - 1], 8)
    elif mode == DC_PRED:
        if haveLeft and haveAbove:
            s = sum(LeftCol[k] for k in range(h)) + sum(AboveRow[k] for k in range(w))
            s += (w + h) >> 1
            v = s // (w + h)
        elif haveLeft:
            v = Clip1(f, (sum(LeftCol[k] for k in range(h)) + (h >> 1)) >> log2H)
        elif haveAbove:
            v = Clip1(f, (sum(AboveRow[k] for k in range(w)) + (w >> 1)) >> log2W)
        else:
            v = 1 << (BD - 1)
        pred = [[v] * w for _ in range(h)]
    else:  # PAETH
        for i in range(h):
            for j in range(w):
                base = AboveRow[j] + LeftCol[i] - AboveRow[-1]
                pLeft, pTop, pTopLeft = abs(base - LeftCol[i]), abs(base - AboveRow[j]), abs(base - AboveRow[-1])
                if pLeft <= pTop and pLeft <= pTopLeft:
                    pred[i][j] = LeftCol[i]
                elif pTop <= pTopLeft:
                    pred[i][j] = AboveRow[j]
                else:
                    pred[i][j] = AboveRow[-1]
    out = []
    PW, PH = f.dims[plane]
    for i in range(h):
        for j in range(w):
            if y + i < PH and x + j < PW:
                out.append(pred[i][j])
    return out


def cfl(f, plane, startX, startY, txSz, alpha, MaxLumaW, MaxLumaH):
    w, h = 1 << Tx_Width_Log2[txSz], 1 << Tx_Height_Log2[txSz]
    subX, subY = f.sx, f.sy
    L = [[0] * w for _ in range(h)]
    lumaAvg = 0
    for i in range(h):
        lumaY = min((startY + i) << subY, MaxLumaH - (1 << subY))
        for j in range(w):
            lumaX = min((startX + j) << subX, MaxLumaW - (1 << subX))
            t = 0
            for dy in range(subY + 1):
                for dx in range(subX + 1):
                    t += f.p[0][lumaY + dy][lumaX + dx]
            v = t << (3 - subX - subY)
            L[i][j] = v
            lumaAvg += v
    lumaAvg = Round2(lumaAvg, Tx_Width_Log2[txSz] + Tx_Height_Log2[txSz])
    out = []
    PW, PH = f.dims[plane]
    for i in range(h):
        for j in range(w):
            if startY + i < PH and startX + j < PW:
                dc = f.p[plane][startY + i][startX + j]
                out.append(Clip1(f, dc + Round2Signed(alpha * (L[i][j] - lumaAvg), 6)))
    return out


def main():
    rnd = random.Random(20261110)
    lines = []
    n = 0
    while n < NCASES:
        bd = rnd.choice([8, 8, 10, 12])
        sx, sy = rnd.choice([(0, 0), (1, 1), (1, 0)])
        mi_cols, mi_rows = rnd.randint(2, 24), rnd.randint(2, 24)
        plane = rnd.choice([0, 0, 0, 1, 2])
        PW, PH = (mi_cols * 4, mi_rows * 4) if plane == 0 else (((mi_cols * 4) + sx) >> sx, ((mi_rows * 4) + sy) >> sy)
        log2w, log2h = rnd.randint(2, 6), rnd.randint(2, 6)
        if rnd.random() < 0.5:
            log2h = log2w
        if abs(log2w - log2h) > 2:
            continue
        x = 4 * rnd.randrange(0, (PW + 3) // 4)
        y = 4 * rnd.randrange(0, (PH + 3) // 4)
        if x >= PW or y >= PH:
            continue
        hl, ha = int(x > 0 and rnd.random() < 0.85), int(y > 0 and rnd.random() < 0.85)
        har, hbl = rnd.randint(0, 1), rnd.randint(0, 1)
        mode = rnd.randint(0, 12)
        dy_, duv = rnd.randint(-3, 3), rnd.randint(-3, 3)
        fi = int(plane == 0 and log2w <= 5 and log2h <= 5 and rnd.random() < 0.15)
        fim = rnd.randint(0, 4)
        eef, ft = rnd.randint(0, 1), rnd.randint(0, 1)
        seed = n + 1
        f = Frame(seed, bd, sx, sy, mi_cols, mi_rows, 3)
        exp = predict_intra(f, plane, x, y, hl, ha, har, hbl, mode, log2w, log2h, dy_, duv, fi, fim, eef, ft)
        lines.append("INTRA %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d | %d %s" % (
            seed, bd, sx, sy, mi_cols, mi_rows, plane, x, y, hl, ha, har, hbl, mode, log2w, log2h, dy_, duv, fi, fim,
            eef, ft, len(exp), " ".join(map(str, exp))))
        n += 1
    m = 0
    while m < NCASES // 4:
        bd = rnd.choice([8, 10])
        sx, sy = rnd.choice([(0, 0), (1, 1), (1, 0)])
        mi_cols, mi_rows = rnd.randint(4, 24), rnd.randint(4, 24)
        plane = rnd.choice([1, 2])
        PW, PH = ((mi_cols * 4 + sx) >> sx, (mi_rows * 4 + sy) >> sy)
        tx = rnd.randint(0, 18)
        w, h = 1 << Tx_Width_Log2[tx], 1 << Tx_Height_Log2[tx]
        if w > 32 or h > 32:
            continue
        sxp, syp = 4 * rnd.randrange(0, (PW + 3) // 4), 4 * rnd.randrange(0, (PH + 3) // 4)
        if sxp >= PW or syp >= PH:
            continue
        LW, LH = mi_cols * 4, mi_rows * 4
        mlw = rnd.choice([LW, LW, rnd.randint(2, LW)])
        mlh = rnd.choice([LH, LH, rnd.randint(2, LH)])
        alpha = rnd.randint(-16, 16)
        seed = 100000 + m
        f = Frame(seed, bd, sx, sy, mi_cols, mi_rows, 3)
        exp = cfl(f, plane, sxp, syp, tx, alpha, mlw, mlh)
        lines.append("CFL %d %d %d %d %d %d %d %d %d %d %d %d %d | %d %s" % (
            seed, bd, sx, sy, mi_cols, mi_rows, plane, sxp, syp, tx, alpha, mlw, mlh, len(exp), " ".join(map(str, exp))))
        m += 1
    open(OUT, "w").write("\n".join(lines) + "\n")
    print("wrote", len(lines), "cases to", OUT)


main()
