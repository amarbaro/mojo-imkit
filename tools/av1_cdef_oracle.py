"""Independent transcription of spec 7.15 (CDEF) for tests/av1filter_test: prints the checksums and direction values the
Mojo test pins. Usage: python3 -I tools/av1_cdef_oracle.py   (all inputs are fixed below)."""
CDEF_DIRS = [[(-1,1),(-2,2)],[(0,1),(-1,2)],[(0,1),(0,2)],[(0,1),(1,2)],[(1,1),(2,2)],[(1,0),(2,1)],[(1,0),(2,0)],[(1,0),(2,-1)]]
UV_DIR = [[[0,1,2,3,4,5,6,7],[1,2,2,2,3,4,6,0]],[[7,0,2,4,5,6,6,6],[0,1,2,3,4,5,6,7]]]
DIV = [0,840,420,280,210,168,140,120,105]
PRI = [[4,2],[3,3]]; SEC = [[2,1],[2,1]]
def flog2(x): return x.bit_length() - 1
def direction(px, bd, x0, y0):
    cost = [0]*8; part = [[0]*15 for _ in range(8)]
    for i in range(8):
        for j in range(8):
            x = (px[y0+i][x0+j] >> (bd-8)) - 128
            part[0][i+j] += x; part[1][i+j//2] += x; part[2][i] += x; part[3][3+i-j//2] += x
            part[4][7+i-j] += x; part[5][3-i//2+j] += x; part[6][j] += x; part[7][i//2+j] += x
    for i in range(8):
        cost[2] += part[2][i]**2; cost[6] += part[6][i]**2
    cost[2] *= DIV[8]; cost[6] *= DIV[8]
    for i in range(7):
        cost[0] += (part[0][i]**2 + part[0][14-i]**2) * DIV[i+1]
        cost[4] += (part[4][i]**2 + part[4][14-i]**2) * DIV[i+1]
    cost[0] += part[0][7]**2 * DIV[8]; cost[4] += part[4][7]**2 * DIV[8]
    for i in range(1, 8, 2):
        for j in range(5): cost[i] += part[i][3+j]**2
        cost[i] *= DIV[8]
        for j in range(3): cost[i] += (part[i][j]**2 + part[i][10-j]**2) * DIV[2*j+2]
    best = 0; yd = 0
    for i in range(8):
        if cost[i] > best: best = cost[i]; yd = i
    return yd, (best - cost[(yd+4)&7]) >> 10
def constrain(diff, thr, damp):
    if not thr: return 0
    adj = max(0, damp - flog2(thr)); s = -1 if diff < 0 else 1
    return s * max(0, min(abs(diff), thr - (abs(diff) >> adj)))
def filt(src, out, plane_w, plane_h, mi_rows, mi_cols, subx, suby, r, c, pri, sec, damp, d, bd):
    sh = bd - 8; x0 = (c*4) >> subx; y0 = (r*4) >> suby
    for i in range(8 >> suby):
        for j in range(8 >> subx):
            s = 0; x = src[y0+i][x0+j]; mx = mn = x
            for k in range(2):
                for sg in (-1, 1):
                    for dd, kind in ((d,'p'), ((d-2)&7,'s'), ((d+2)&7,'s')):
                        y = y0+i+sg*CDEF_DIRS[dd][k][0]; xx = x0+j+sg*CDEF_DIRS[dd][k][1]
                        cr = (y << suby) >> 2; cc = (xx << subx) >> 2
                        if 0 <= cr < mi_rows and 0 <= cc < mi_cols:
                            p = src[y][xx]
                            t = (pri >> sh) & 1
                            s += (PRI[t][k] if kind == 'p' else SEC[t][k]) * constrain(p - x, pri if kind == 'p' else sec, damp)
                            mx = max(p, mx); mn = min(p, mn)
            out[y0+i][x0+j] = max(mn, min(mx, x + ((8 + s - (1 if s < 0 else 0)) >> 4)))
STYLE = 0
def px(p, x, y, bd):
    if STYLE == 0:
        v = (x*37 + y*23 + ((x*y) % 11)*17 + p*50) % 256
    else:  # horizontal stripes of amplitude STYLE plus a small column ripple
        v = 128 + (STYLE if y % 2 == 0 else -STYLE) + ((x*5 + y) % 3 - 1)
    return v if bd == 8 else v*4 + x % 4
def run(bd, subx, suby, planes, ypri=4):
    W = H = 16; mi = 4
    pl = []
    for p in range(planes):
        w = W if p == 0 else W >> subx; h = H if p == 0 else H >> suby
        pl.append([[px(p, x, y, bd) for x in range(w)] for y in range(h)])
    out = [[row[:] for row in a] for a in pl]
    ysec, uvpri, uvsec, damping = 2, 3, 1, 5
    sh = bd - 8
    for r in range(0, mi, 2):
        for c in range(0, mi, 2):
            if r == 2 and c == 2: continue  # skip flag set on this 8x8 block
            yd, var = direction(pl[0], bd, c*4, r*4)
            pri = ypri << sh; sec = ysec << sh
            d = 0 if pri == 0 else yd
            vs = min(flog2(var >> 6), 12) if (var >> 6) else 0
            pri = (pri*(4+vs)+8) >> 4 if var else 0
            filt(pl[0], out[0], W, H, mi, mi, 0, 0, r, c, pri, sec, damping+sh, d, bd)
            if planes > 1:
                pri = uvpri << sh; sec = uvsec << sh
                d = 0 if pri == 0 else UV_DIR[subx][suby][yd]
                for p in (1, 2):
                    filt(pl[p], out[p], W >> subx, H >> suby, mi, mi, subx, suby, r, c, pri, sec, damping+sh-1, d, bd)
    for p in range(planes):
        cs = 0
        for y, row in enumerate(out[p]):
            for x, v in enumerate(row): cs = (cs + v * (y*len(row)+x+1)) % 4294967296
        print("bd", bd, "sub", subx, suby, "plane", p, "checksum", cs)
    print("dirs", [direction(pl[0], bd, x, y) for y in (0, 8) for x in (0, 8)])
def main():
    global STYLE
    run(8, 1, 1, 3); run(10, 1, 1, 3); run(8, 0, 0, 3); run(8, 1, 0, 3)
    for STYLE, ypri in ((3, 4), (72, 15), (120, 15)):
        print('style', STYLE, 'ypri', ypri)
        run(8, 1, 1, 3, ypri)

def pattern(f):
    px_ = [[f(i, j) for j in range(8)] for i in range(8)]
    return direction(px_, 8, 0, 0)
A, B = 200, 56
print("anti-diagonal", pattern(lambda i, j: A if (i+j) % 4 < 2 else B))
print("diagonal", pattern(lambda i, j: A if (i-j) % 4 < 2 else B))
print("rows", pattern(lambda i, j: A if i % 2 == 0 else B))
print("cols", pattern(lambda i, j: A if j % 2 == 0 else B))

if __name__ == "__main__":
    main()
