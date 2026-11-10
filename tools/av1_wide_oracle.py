"""Oracle for tests/av1filter_test: spec 7.14.6.4 wide filter on a 1-D step, printed as the values the Mojo test pins."""
import sys

def r2(x, n): return (x + (1 << (n - 1))) >> n

def wide(line, base, log2, plane):
    n = 6 if log2 == 4 else (3 if plane == 0 else 2)
    n2 = 0 if (log2 == 3 and plane == 0) else 1
    F = {}
    for i in range(-n, n):
        t = 0
        for j in range(-n, n + 1):
            p = max(-(n + 1), min(n, i + j))
            t += line[base + p] * (2 if abs(j) <= n2 else 1)
        F[i] = r2(t, log2)
    out = list(line)
    for i in range(-n, n): out[base + i] = F[i]
    return out

a, b = int(sys.argv[1]), int(sys.argv[2])
for log2, plane in ((3, 0), (4, 0), (3, 1)):
    line = [a] * 16 + [b] * 16
    o = wide(line, 16, log2, plane)
    print(log2, plane, o[8:24])
