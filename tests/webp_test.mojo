"""webp_decode check (CPU). Modes: `golden` decodes every fixture and compares with libwebp's output (lossless bit exact, lossy
max channel diff <= 2 and mean <= 0.5), `mutants` feeds truncated and corrupted files (must raise or decode, never crash or
hang), `bench` times the decode. Fixtures and goldens: tests/webp_fixtures.sh. Run through tests/webp_test.sh."""
from std.sys import argv
from std.time import perf_counter_ns
from imkit.webp import webp_decode

comptime DIR = ".work/webp/"


def slurp(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def names(prefix: String) -> List[String]:
    var all: List[String] = [
        "ll_bg", "ll_bg_small", "ll_icon", "ll_icon2", "ll_icon_exact", "ll_pal4", "ll_pal2", "ll_pal16", "ll_noise", "ll_tiny", "ll_odd",
        "ly_bg", "ly_bg_q30", "ly_bg_small", "ly_bg_odd", "ly_bg_sharp", "ly_bg_seg", "ly_bg_simple",
        "ly_alpha_raw", "ly_alpha_ll", "ly_alpha_fast", "ly_alpha_best", "ly_alpha_bg", "ly_alpha_h", "ly_alpha_v",
        "ly_part2", "ly_part8", "ly_flat", "ly_flat_alpha", "ly_seg1", "ly_strong", "ly_simple_strong", "ly_q100", "ly_q100_noise", "ly_q2",
        "ly_1x1", "ly_17x1", "ly_1x17", "ly_16x16", "ly_33x31",
    ]
    var out = List[String]()
    for n in all:
        if n.startswith(prefix):
            out.append(n)
    return out^


def golden(mut fails: Int) raises:
    for n in names(""):
        var bytes = slurp(DIR + n + ".webp")
        var want = slurp(DIR + n + ".rgba")
        var tag = "webp " + n
        try:
            var d = webp_decode(Span(bytes))
            if len(d[2]) * 4 != len(want):
                print("FAIL " + tag + ": " + String(d[0]) + " x " + String(d[1]) + " is not the golden size " + String(len(want) // 4) + " px")
                fails += 1
                continue
            var mx, sum, bad = 0, 0, 0
            for i in range(len(d[2])):
                var v = d[2][i]
                for c in range(4):
                    var df = abs(Int((v >> UInt32(8 * c)) & 255) - Int(want[4 * i + c]))
                    mx = max(mx, df)
                    sum += df
                    if df != 0:
                        bad += 1
            var mean = Float64(sum) / Float64(len(want))
            var lossy = n.startswith("ly_")
            var ok = (mx <= 2 and mean <= 0.5) if lossy else mx == 0
            print(("PASS " if ok else "FAIL ") + tag + ": " + String(d[0]) + " x " + String(d[1]) + " max diff " + String(mx) + " mean " + String(mean) + " differing " + String(bad))
            if not ok:
                fails += 1
        except e:
            print("FAIL " + tag + ": raised " + String(e))
            fails += 1


def put32(mut b: List[UInt8], at: Int, v: Int):
    for i in range(4):
        b[at + i] = UInt8((v >> (8 * i)) & 255)


def mutants(mut fails: Int) raises:
    var raised_trunc, trunc_total, raised_bad, bad_total = 0, 0, 0, 0
    for n in names(""):
        var good = slurp(DIR + n + ".webp")
        if len(good) > 40000:
            continue  # the sweep stays under the 10 s budget on the small files
        # truncation: the payload is cut and the RIFF and chunk sizes are patched, so the decoder itself must notice
        for frac in range(1, 8):
            var cut = 20 + (len(good) - 20) * frac // 8
            var t = List[UInt8](good[:cut])
            put32(t, 4, cut - 8)
            if le32_at(t, 16) + 20 > cut:
                put32(t, 16, cut - 20)
            trunc_total += 1
            try:
                _ = webp_decode(Span(t))
                print("FAIL webp mutant " + n + ": truncated to " + String(cut) + " bytes still decoded")
                fails += 1
            except:
                raised_trunc += 1
        # a bad byte somewhere in the first 160 bytes (headers, prefix codes, probabilities): raise or decode, never crash
        for at in range(20, min(len(good), 180), 3):
            for v in [0, 255]:
                var m = List[UInt8](good)
                m[at] = UInt8(v)
                bad_total += 1
                try:
                    _ = webp_decode(Span(m))
                except:
                    raised_bad += 1
    var ok = raised_trunc == trunc_total and raised_bad > 0
    print(("PASS " if ok else "FAIL ") + "webp mutants: truncated " + String(raised_trunc) + "/" + String(trunc_total) + " raised, corrupted " + String(raised_bad) + "/" + String(bad_total) + " raised, no crash")
    if not ok:
        fails += 1


def le32_at(b: List[UInt8], i: Int) -> Int:
    return Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24


def bench() raises:
    for n in ["ll_bg", "ly_bg"]:
        var bytes = slurp(DIR + n + ".webp")
        var ts = List[Int]()
        for _ in range(5):
            var t0 = perf_counter_ns()
            var d = webp_decode(Span(bytes))
            ts.append(Int(perf_counter_ns() - t0))
            _ = d[0]
        sort(ts)
        print("webp bench " + n + ": " + String(len(bytes)) + " bytes, median of 5 " + String(ts[2] // 1000) + " us")


def main() raises:
    var mode = argv()[1] if len(argv()) > 1 else "golden"
    var fails = 0
    if mode == "golden":
        golden(fails)
    elif mode == "mutants":
        mutants(fails)
    elif mode == "once":  # once NAME [decode]: for /usr/bin/time -f %M, peak RSS with and without the decode
        var bytes = slurp(DIR + argv()[2] + ".webp")
        if len(argv()) > 3:
            var d = webp_decode(Span(bytes))
            print("decoded " + String(d[0]) + " x " + String(d[1]))
    else:
        bench()
    if fails > 0:
        print("FAIL webp_test: " + String(fails))
        raise Error("webp_test")
    print("PASS webp_test " + mode)
