"""Independent transcription of spec 7.18.3 (film grain synthesis) for tests/av1grain_test: prints the plane checksums the Mojo
test pins. Gaussian_Sequence is read from the spec text (AV1SPEC dir, default the boss worktree's .work/av1spec), so the generated
av1tab table is cross-checked too. Usage: python3 -I tools/av1_grain_oracle.py"""
import os, re
SPEC = os.environ.get("AV1SPEC", os.path.expanduser("~/Projects/mojo/mojo-imkit-lanes/avif/.work/av1spec"))
txt = open(SPEC + "/10.additional.tables.md").read()
body = txt[txt.index("Gaussian_Sequence[ 2048 ] = {"):]
GAUSS = [int(v) for v in re.findall(r"-?\d+", body[body.index("{") + 1:body.index("}")])]
assert len(GAUSS) == 2048
def r2(x, n): return (x + ((1 << n) >> 1)) >> n if n else x
def clip3(lo, hi, v): return lo if v < lo else (hi if v > hi else v)
class P: pass
def coefs(n, a, m, c): return [128 + ((i * a) % m) - c for i in range(n)]
def cfg_a():
    p = P(); p.bd = 8; p.sx = p.sy = 1; p.w, p.h = 75, 71; p.mc = 2; p.mono = False; p.seed = 0xBDE4
    p.y = [(16, 0), (100, 90), (200, 120)]; p.cb = [(16, 20), (128, 100)]; p.cr = [(50, 60), (240, 30)]; p.cfl = False
    p.scaling8 = 2; p.lag = 2; p.ay = coefs(12, 7, 11, 5); p.acb = coefs(13, 5, 9, 4); p.acr = coefs(13, 3, 7, 3)
    p.arshift6 = 1; p.gss = 0; p.cbm = (140, 100, 300); p.crm = (120, 150, 200); p.overlap = True; p.restr = False
    return p
def cfg_b():
    p = P(); p.bd = 10; p.sx = p.sy = 0; p.w, p.h = 70, 40; p.mc = 0; p.mono = False; p.seed = 777
    p.y = [(0, 40), (255, 60)]; p.cb = []; p.cr = []; p.cfl = True
    p.scaling8 = 1; p.lag = 1; p.ay = coefs(4, 7, 11, 5); p.acb = coefs(5, 5, 9, 4); p.acr = coefs(5, 3, 7, 3)
    p.arshift6 = 0; p.gss = 1; p.cbm = (0, 0, 0); p.crm = (0, 0, 0); p.overlap = False; p.restr = True
    return p
def cfg_c():
    p = P(); p.bd = 8; p.sx = 1; p.sy = 0; p.w, p.h = 64, 33; p.mc = 2; p.mono = False; p.seed = 4242
    p.y = [(30, 50)]; p.cb = [(60, 80)]; p.cr = []; p.cfl = False
    p.scaling8 = 3; p.lag = 3; p.ay = coefs(24, 7, 11, 5); p.acb = coefs(25, 5, 9, 4); p.acr = coefs(25, 3, 7, 3)
    p.arshift6 = 2; p.gss = 2; p.cbm = (128, 128, 256); p.crm = (0, 0, 0); p.overlap = True; p.restr = True
    return p
def cfg_d():
    p = P(); p.bd = 8; p.sx = p.sy = 1; p.w, p.h = 40, 36; p.mc = 2; p.mono = True; p.seed = 31337
    p.y = [(0, 20), (255, 70)]; p.cb = []; p.cr = []; p.cfl = False
    p.scaling8 = 0; p.lag = 0; p.ay = []; p.acb = []; p.acr = []
    p.arshift6 = 0; p.gss = 0; p.cbm = (0, 0, 0); p.crm = (0, 0, 0); p.overlap = True; p.restr = False
    return p
def src_px(pl, x, y, bd):
    v = (x * 17 + y * 29 + ((x * y) % 7) * 23 + pl * 45) % 256
    return v if bd == 8 else v * 4 + x % 4
def lut_for(pts):
    lut = [0] * 257
    if not pts: return lut
    for x in range(pts[0][0]): lut[x] = pts[0][1]
    for i in range(len(pts) - 1):
        dy = pts[i+1][1] - pts[i][1]; dx = pts[i+1][0] - pts[i][0]
        delta = dy * ((65536 + (dx >> 1)) // dx)
        for x in range(dx): lut[pts[i][0] + x] = pts[i][1] + ((x * delta + 32768) >> 16)
    for x in range(pts[-1][0], 256): lut[x] = pts[-1][1]
    return lut
def run(p):
    bd, sx, sy, w, h = p.bd, p.sx, p.sy, p.w, p.h
    planes = 1 if p.mono else 3
    out = [[[src_px(pl, x, y, bd) for x in range(w if pl == 0 else (w + sx) >> sx)] for y in range(h if pl == 0 else (h + sy) >> sy)] for pl in range(planes)]
    Y = [row[:] for row in out[0]]
    state = [0]
    def rnd(bits):
        r = state[0]; bit = ((r >> 0) ^ (r >> 1) ^ (r >> 3) ^ (r >> 12)) & 1
        r = (r >> 1) | (bit << 15); state[0] = r
        return (r >> (16 - bits)) & ((1 << bits) - 1)
    center = 128 << (bd - 8); gmin = -center; gmax = (256 << (bd - 8)) - 1 - center
    state[0] = p.seed
    shift = 12 - bd + p.gss
    LG = [[r2(GAUSS[rnd(11)], shift) if p.y else 0 for x in range(82)] for y in range(73)]
    sh = p.arshift6 + 6
    for y in range(3, 73):
        for x in range(3, 79):
            s = 0; pos = 0
            for dr in range(-p.lag, 1):
                for dc in range(-p.lag, p.lag + 1):
                    if dr == 0 and dc == 0: break
                    s += LG[y+dr][x+dc] * (p.ay[pos] - 128); pos += 1
            LG[y][x] = clip3(gmin, gmax, LG[y][x] + r2(s, sh))
    cw = 44 if sx else 82; ch = 38 if sy else 73
    if not p.mono:
        state[0] = p.seed ^ 0xb524
        CB = [[r2(GAUSS[rnd(11)], shift) if (p.cb or p.cfl) else 0 for x in range(cw)] for y in range(ch)]
        state[0] = p.seed ^ 0x49d8
        CR = [[r2(GAUSS[rnd(11)], shift) if (p.cr or p.cfl) else 0 for x in range(cw)] for y in range(ch)]
        for y in range(3, ch):
            for x in range(3, cw - 3):
                s0 = s1 = 0; pos = 0
                for dr in range(-p.lag, 1):
                    for dc in range(-p.lag, p.lag + 1):
                        c0 = p.acb[pos] - 128 if pos < len(p.acb) else 0; c1 = p.acr[pos] - 128 if pos < len(p.acr) else 0
                        if dr == 0 and dc == 0:
                            if p.y:
                                luma = 0; lx = ((x - 3) << sx) + 3; ly = ((y - 3) << sy) + 3
                                for i in range(sy + 1):
                                    for j in range(sx + 1): luma += LG[ly+i][lx+j]
                                luma = r2(luma, sx + sy); s0 += luma * c0; s1 += luma * c1
                            break
                        s0 += CB[y+dr][x+dc] * c0; s1 += CR[y+dr][x+dc] * c1; pos += 1
                CB[y][x] = clip3(gmin, gmax, CB[y][x] + r2(s0, sh)); CR[y][x] = clip3(gmin, gmax, CR[y][x] + r2(s1, sh))
    luts = [lut_for(p.y)] + ([] if p.mono else ([lut_for(p.y)] * 2 if p.cfl else [lut_for(p.cb), lut_for(p.cr)]))
    # noise stripes
    NS = {}
    luma_num = 0; y = 0
    while y < (h + 1) // 2:
        state[0] = p.seed; state[0] ^= ((luma_num * 37 + 178) & 255) << 8; state[0] ^= (luma_num * 173 + 105) & 255
        x = 0
        while x < (w + 1) // 2:
            rand = rnd(8); ox = rand >> 4; oy = rand & 15
            for pl in range(planes):
                psx = sx if pl else 0; psy = sy if pl else 0
                pox = 6 + ox if psx else 9 + ox * 2; poy = 6 + oy if psy else 9 + oy * 2
                for i in range(34 >> psy):
                    for j in range(34 >> psx):
                        g = (LG if pl == 0 else (CB if pl == 1 else CR))[poy + i][pox + j]
                        if psx == 0:
                            if j < 2 and p.overlap and x > 0:
                                old = NS[(luma_num, pl, i, x*2 + j)]
                                g = old*27 + g*17 if j == 0 else old*17 + g*27
                                g = clip3(gmin, gmax, r2(g, 5))
                            NS[(luma_num, pl, i, x*2 + j)] = g
                        else:
                            if j == 0 and p.overlap and x > 0:
                                old = NS[(luma_num, pl, i, x + j)]
                                g = clip3(gmin, gmax, r2(old*23 + g*22, 5))
                            NS[(luma_num, pl, i, x + j)] = g
            x += 16
        luma_num += 1; y += 16
    NI = []
    for pl in range(planes):
        psx = sx if pl else 0; psy = sy if pl else 0
        img = []
        for y in range((h + psy) >> psy):
            ln = y >> (5 - psy); i = y - (ln << (5 - psy)); row = []
            for x in range((w + psx) >> psx):
                g = NS[(ln, pl, i, x)]
                if psy == 0:
                    if i < 2 and ln > 0 and p.overlap:
                        old = NS[(ln - 1, pl, i + 32, x)]
                        g = old*27 + g*17 if i == 0 else old*17 + g*27
                        g = clip3(gmin, gmax, r2(g, 5))
                else:
                    if i < 1 and ln > 0 and p.overlap:
                        old = NS[(ln - 1, pl, i + 16, x)]
                        g = clip3(gmin, gmax, r2(old*23 + g*22, 5))
                row.append(g)
            img.append(row)
        NI.append(img)
    if p.restr:
        mn = 16 << (bd - 8); mxl = 235 << (bd - 8); mxc = mxl if p.mc == 0 else 240 << (bd - 8)
    else:
        mn = 0; mxl = (256 << (bd - 8)) - 1; mxc = mxl
    ss = p.scaling8 + 8
    def scale(pl, idx):
        s = bd - 8; x = idx >> s; rem = idx - (x << s)
        if bd == 8 or x == 255: return luts[pl][x]
        return luts[pl][x] + r2((luts[pl][x+1] - luts[pl][x]) * rem, s)
    if not p.mono:
        for y in range((h + sy) >> sy):
            for x in range((w + sx) >> sx):
                lx = x << sx; ly = y << sy; lnx = min(lx + 1, w - 1)
                avg = r2(Y[ly][lx] + Y[ly][lnx], 1) if sx else Y[ly][lx]
                for pl, pts, m in ((1, p.cb, p.cbm), (2, p.cr, p.crm)):
                    if pts or p.cfl:
                        orig = out[pl][y][x]
                        if p.cfl: merged = avg
                        else:
                            comb = avg * (m[1] - 128) + orig * (m[0] - 128)
                            merged = clip3(0, (1 << bd) - 1, (comb >> 6) + ((m[2] - 256) << (bd - 8)))
                        nz = r2(scale(pl, merged) * NI[pl][y][x], ss)
                        out[pl][y][x] = clip3(mn, mxc, orig + nz)
    if p.y:
        for y in range(h):
            for x in range(w):
                orig = Y[y][x]; nz = r2(scale(0, orig) * NI[0][y][x], ss)
                out[0][y][x] = clip3(mn, mxl, orig + nz)
    res = []
    for pl in range(planes):
        cs = 0
        for y, row in enumerate(out[pl]):
            for x, v in enumerate(row): cs = (cs + v * (y*len(row) + x + 1)) % 4294967296
        res.append(cs)
    return res
def main():
    for name, f in (("A", cfg_a), ("B", cfg_b), ("C", cfg_c), ("D", cfg_d)):
        print(name, run(f()))
if __name__ == "__main__":
    main()
