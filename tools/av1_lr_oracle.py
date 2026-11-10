"""Independent transcription of spec 7.17 (loop restoration, per 4x4 block as written) for tests/av1filter_test.
Prints the plane checksums the Mojo test pins. Usage: python3 -I tools/av1_lr_oracle.py"""
SGR = [(2,12,1,4),(2,15,1,6),(2,18,1,8),(2,21,1,9),(2,24,1,10),(2,29,1,11),(2,36,1,12),(2,45,1,13),
       (2,56,1,14),(2,68,1,15),(0,0,1,5),(0,0,1,8),(0,0,1,11),(0,0,1,14),(2,30,0,0),(2,75,0,0)]
def r2(x, n): return (x + ((1 << n) >> 1)) >> n if n else x
def pre_px(p, x, y, bd):
    v = (x*29 + y*31 + ((x*y) % 13)*11 + p*40) % 256
    return v if bd == 8 else v*4 + x % 4
def cdef_px(p, x, y, bd):
    v = pre_px(p, x, y, bd) + ((x+y) % 5 - 2) * (1 if bd == 8 else 4)
    return max(0, min((1 << bd) - 1, v))
def unit_params(plane, u):
    typ = (u*2 + plane) % 3
    v = [((u*3) % 16) - 5 if plane == 0 else 0, -10 + u*4, 20 + u*5]
    h = [((u*2) % 16) - 4 if plane == 0 else 0, -8 + u*3, 25 - u*4]
    return typ, v, h, (u*5 + plane*3 + 1) % 16, (-20 + u*7 + plane, 30 - u*9 + plane*2)
def run(bd, subx, suby, FH, UW, sizes):
    planes = 3
    dims = [(UW if p == 0 else (UW + subx) >> subx, FH if p == 0 else (FH + suby) >> suby) for p in range(planes)]
    pre = [[[pre_px(p, x, y, bd) for x in range(dims[p][0])] for y in range(dims[p][1])] for p in range(planes)]
    cdf = [[[cdef_px(p, x, y, bd) for x in range(dims[p][0])] for y in range(dims[p][1])] for p in range(planes)]
    lr = [[row[:] for row in a] for a in cdf]
    r0_ = 5 if bd == 12 else 3; r1_ = 9 if bd == 12 else 11
    for y in range(0, FH, 4):
        for x in range(0, UW, 4):
            for plane in range(planes):
                row = y >> 2; col = x >> 2
                sx = 0 if plane == 0 else subx; sy = 0 if plane == 0 else suby
                stripe = (row*4 + 8) // 64
                sstart = (-8 + stripe*64) >> sy; send = sstart + (64 >> sy) - 1
                size = sizes[plane]
                urows = max((((FH + sy) >> sy) + (size >> 1)) // size, 1)
                ucols = max((((UW + sx) >> sx) + (size >> 1)) // size, 1)
                ur = min(urows - 1, ((row*4 + 8) >> sy) // size); uc = min(ucols - 1, ((col*4) >> sx) // size)
                pex = ((UW + sx) >> sx) - 1; pey = ((FH + sy) >> sy) - 1
                bx = (col*4) >> sx; by = (row*4) >> sy
                w = min(4 >> sx, pex - bx + 1); h = min(4 >> sy, pey - by + 1)
                typ, vc, hc, sset, xqd = unit_params(plane, ur*ucols + uc)
                def src(xx, yy):
                    xx = max(0, min(pex, xx)); yy = max(0, min(pey, yy))
                    if yy < sstart: return pre[plane][max(sstart-2, yy)][xx]
                    if yy > send: return pre[plane][min(send+2, yy)][xx]
                    return cdf[plane][yy][xx]
                if typ == 1:
                    def coefs(c):
                        f = [0]*7; f[3] = 128
                        for i in range(3): f[i] = c[i]; f[6-i] = c[i]; f[3] -= 2*c[i]
                        return f
                    vf, hf = coefs(vc), coefs(hc)
                    off = 1 << (bd + 7 - r0_ - 1); lim = (1 << (bd + 1 + 7 - r0_)) - 1
                    inter = [[max(-off, min(lim - off, r2(sum(hf[t]*src(bx+c+t-3, by+r-3) for t in range(7)), r0_))) for c in range(w)] for r in range(h+6)]
                    for r in range(h):
                        for c in range(w):
                            lr[plane][by+r][bx+c] = max(0, min((1 << bd) - 1, r2(sum(vf[t]*inter[r+t][c] for t in range(7)), r1_)))
                elif typ == 2:
                    def box(pss):
                        r, eps = SGR[sset][pss*2], SGR[sset][pss*2+1]
                        if r == 0: return None
                        n = (2*r+1)**2; n2e = n*n*eps; s = ((1 << 20) + n2e//2)//n2e
                        A = {}; B = {}
                        for i in range(-1, h+1):
                            for j in range(-1, w+1):
                                a = b = 0
                                for dy in range(-r, r+1):
                                    for dx in range(-r, r+1):
                                        c = src(bx+j+dx, by+i+dy); a += c*c; b += c
                                a = r2(a, 2*(bd-8)); d = r2(b, bd-8)
                                p = max(0, a*n - d*d); z = r2(p*s, 20)
                                a2 = 256 if z >= 255 else (1 if z == 0 else ((z << 8) + z//2)//(z+1))
                                oon = ((1 << 12) + n//2)//n
                                A[(i, j)] = a2; B[(i, j)] = r2((256 - a2)*b*oon, 12)
                        F = [[0]*w for _ in range(h)]
                        for i in range(h):
                            shift = 4 if (pss == 0 and (i & 1)) else 5
                            for j in range(w):
                                a = b = 0
                                for dy in (-1, 0, 1):
                                    for dx in (-1, 0, 1):
                                        if pss == 0: wt = (6 if dx == 0 else 5) if ((i+dy) & 1) else 0
                                        else: wt = 4 if (dx == 0 or dy == 0) else 3
                                        a += wt*A[(i+dy, j+dx)]; b += wt*B[(i+dy, j+dx)]
                                F[i][j] = r2(a*cdf[plane][by+i][bx+j] + b, 8 + shift - 4)
                        return F
                    f0, f1 = box(0), box(1)
                    w0, w1 = xqd; w2 = 128 - w0 - w1
                    for i in range(h):
                        for j in range(w):
                            u = cdf[plane][by+i][bx+j] << 4
                            v = w1*u + w0*(f0[i][j] if SGR[sset][0] else u) + w2*(f1[i][j] if SGR[sset][2] else u)
                            lr[plane][by+i][bx+j] = max(0, min((1 << bd) - 1, r2(v, 11)))
    for p in range(planes):
        cs = 0
        for y, row in enumerate(lr[p]):
            for x, v in enumerate(row): cs = (cs + v*(y*len(row)+x+1)) % 4294967296
        print("bd", bd, "sub", subx, suby, "FH", FH, "UW", UW, "plane", p, "checksum", cs)
def main():
    run(8, 1, 1, 100, 100, [64, 32, 32])
    run(10, 1, 1, 100, 100, [64, 32, 32])
    run(8, 0, 0, 70, 90, [64, 64, 64])
    run(8, 1, 0, 90, 66, [64, 64, 64])  # 4:2:2 chroma keeps the luma unit size (lr_uv_shift needs 4:2:0)
    run(8, 1, 1, 75, 71, [64, 32, 32])  # odd sizes: Round2 of the plane extents
if __name__ == "__main__":
    main()
