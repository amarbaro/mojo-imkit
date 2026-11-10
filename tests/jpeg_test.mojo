"""JPEG decoder check (CPU): jpeg_decode against the ImageMagick goldens that tests/jpeg_test.sh writes, bad-input mutants of good
files, and the decode time. Run it through the script.
usage: jpeg_test check DIR | mutants FILE... | fuzz FILE N | bench FILE"""
from std.os import getenv, listdir
from std.sys import argv
from std.time import perf_counter_ns
from imkit.assets import MAXPX as PNG_MAXPX
from imkit.jpeg import MAXPX, jpeg_decode


def load(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def check(dir: String) raises:
    var names = List[String]()
    for n in listdir(dir):
        if n.endswith(".jpg"):
            names.append(String(n))
    sort(names)
    if len(names) == 0:
        raise Error("no fixtures in " + dir)
    # The decoder repeats libjpeg's integer IDCT, fancy upsampling and colour constants, so the default bar is bit-exact: the brief's
    # bar (max diff 2, mean 0.5) let an IDCT constant off by one pass (max 2, mean 2e-5). JPEG_MAXDIFF=2 restores the brief's bar.
    var tol = Int(getenv("JPEG_MAXDIFF", "0"))
    var tmean = 0.5 if tol > 0 else 0.0
    var fails = 0
    for n in names:
        var pic = jpeg_decode(Span(load(dir + "/" + n)))
        var gold = load(dir + "/" + n + ".rgba")
        var worst, sum = 0, 0
        if len(gold) != 4 * pic[0] * pic[1]:
            print("FAIL", n, "size", pic[0], "x", pic[1], "against", len(gold) // 4, "golden pixels")
            fails += 1
            continue
        for i in range(len(gold) // 4):
            var v = pic[2][i]
            for ch in range(3):
                var dv = abs(Int((v >> UInt32(8 * ch)) & 255) - Int(gold[4 * i + ch]))
                worst = max(worst, dv)
                sum += dv
            if Int(v >> 24) != Int(gold[4 * i + 3]):
                worst = 999
        var mean = Float64(sum) / Float64(3 * len(gold) // 4)
        var ok = worst <= tol and mean <= tmean
        print("PASS" if ok else "FAIL", n, String(pic[0]) + "x" + String(pic[1]), "max", worst, "mean", mean)
        if not ok:
            fails += 1
    if MAXPX != PNG_MAXPX:
        print("FAIL MAXPX differs from assets.MAXPX")
        fails += 1
    if fails > 0:
        raise Error(String(fails) + " fixtures failed")


def raises(name: String, bytes: List[UInt8]) -> Bool:
    """True if jpeg_decode raises. The case name is printed first so a crash or hang names itself."""
    print("case", name, flush=True)
    try:
        _ = jpeg_decode(Span(bytes))
    except e:
        print("PASS raised:", e)
        return True
    print("FAIL", name, "decoded")
    return False


def mutants(path: String) raises -> Int:
    var b = load(path)
    var fails = 0
    for cut in [0, 1, 2, 3, 20, 100, len(b) // 10, len(b) // 2, len(b) - 100, len(b) - 3, len(b) - 2, len(b) - 1]:
        fails += 0 if raises(path + " cut at " + String(cut), List[UInt8](b[:cut])) else 1
    var dht = -1  # the first DHT, found by its marker
    var sof = -1
    for i in range(len(b) - 1):
        if b[i] == 0xFF and b[i + 1] == 0xC4 and dht < 0:
            dht = i
        if b[i] == 0xFF and (b[i + 1] == 0xC0 or b[i + 1] == 0xC2) and sof < 0:
            sof = i
    # the 16 length counts of the first table: all 255 -> over-subscribed; one count raised -> over-subscribed or segment overrun
    var m = List[UInt8](b)
    for k in range(16):
        m[dht + 5 + k] = 255
    fails += 0 if raises(path + " DHT counts all 255", m) else 1
    m = List[UInt8](b)
    m[dht + 5] = 255
    fails += 0 if raises(path + " DHT first count 255", m) else 1
    m = List[UInt8](b)
    m[dht + 5 + 8] = m[dht + 5 + 8] + 40
    fails += 0 if raises(path + " DHT count 9 + 40", m) else 1
    # soft corruption: a symbol byte changed. A valid table that decodes garbage may raise or not, it must not crash or hang.
    m = List[UInt8](b)
    m[dht + 25] = 0xFF
    print("case", path, "DHT symbol 0xFF", flush=True)
    try:
        _ = jpeg_decode(Span(m))
        print("PASS decoded garbage without a crash")
    except e:
        print("PASS raised:", e)
    # SOF fields: size (a 65535 x 65535 picture must be refused before it allocates), component count, precision
    m = List[UInt8](b)
    m[sof + 5], m[sof + 6], m[sof + 7], m[sof + 8] = 255, 255, 255, 255
    fails += 0 if raises(path + " 65535 x 65535", m) else 1
    m = List[UInt8](b)
    m[sof + 9] = 4
    fails += 0 if raises(path + " 4 components", m) else 1
    m = List[UInt8](b)
    m[sof + 4] = 12
    fails += 0 if raises(path + " 12-bit", m) else 1
    m = List[UInt8](b)
    m[sof + 1] = 0xC9  # SOF9 arithmetic
    m[sof + 1] = 0xC9
    fails += 0 if raises(path + " arithmetic SOF", m) else 1
    fails += 0 if raises("not a JPEG", List[UInt8](b[2:])) else 1
    return fails


def fuzz(path: String, n: Int) raises:
    """N random corruptions (1 to 4 bytes replaced, deterministic LCG) of a good file, then every sampling-factor byte 0x00 to 0xFF for
    each component. Each must decode or raise; a crash or a hang fails the run (the script puts a timeout on it)."""
    var b = load(path)
    var seed = 12345
    var raised, decoded = 0, 0
    for i in range(n):
        var m = List[UInt8](b)
        seed = (seed * 6364136223846793005 + 1442695040888963407) & 0x7FFFFFFFFFFFFFFF
        for _ in range(1 + (seed >> 40) % 4):
            seed = (seed * 6364136223846793005 + 1442695040888963407) & 0x7FFFFFFFFFFFFFFF
            m[(seed >> 20) % len(m)] = UInt8((seed >> 52) & 255)
        if i % 100 == 0:
            print("fuzz", path, "case", i, flush=True)
        try:
            _ = jpeg_decode(Span(m))
            decoded += 1
        except:
            raised += 1
    var sof = -1
    for i in range(len(b) - 1):
        if b[i] == 0xFF and (b[i + 1] == 0xC0 or b[i + 1] == 0xC2) and sof < 0:
            sof = i
    for comp in range(Int(b[sof + 9])):
        for hv in range(256):
            var m = List[UInt8](b)
            m[sof + 11 + 3 * comp] = UInt8(hv)
            try:
                _ = jpeg_decode(Span(m))
                decoded += 1
            except:
                raised += 1
    print("PASS fuzz", path, ":", raised, "raised,", decoded, "decoded, no crash or hang")


def bench(path: String) raises:
    var b = load(path)
    var t = List[Int]()
    var w = 0
    for i in range(6):  # the first run is warm-up
        var t0 = perf_counter_ns()
        var pic = jpeg_decode(Span(b))
        w = pic[0]
        if i > 0:
            t.append(Int(perf_counter_ns() - t0))
    sort(t)
    print("bench", path, w, "median of 5:", Float64(t[2]) / 1e6, "ms, min", Float64(t[0]) / 1e6, "ms")


def main() raises:
    var a = argv()
    if len(a) < 3:
        raise Error("usage: jpeg_test check DIR | mutants FILE... | bench FILE")
    if a[1] == "check":
        check(String(a[2]))
    elif a[1] == "mutants":
        var fails = 0
        for i in range(2, len(a)):
            fails += mutants(String(a[i]))
        if fails > 0:
            raise Error(String(fails) + " mutants did not raise")
    elif a[1] == "fuzz":
        fuzz(String(a[2]), Int(a[3]))
    else:
        bench(String(a[2]))
