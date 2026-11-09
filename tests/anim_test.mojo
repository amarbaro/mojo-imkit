"""Spring table check, no GPU, no window. Gates: an id first seen sits at its target; one step matches the hand-computed
semi-implicit Euler value; dt is clamped (a 10 s stall steps like 0.05 s) and dt 0 does not move; a spring settles on its
target within 2 s at 60 fps with under 5% overshoot, and snaps exactly; an id no widget asked for last frame is evicted and
the survivors keep their state (swap-remove); a returning id starts at its target again. PASS / FAIL, exit 1 on any FAIL.

usage: mojo run -I src tests/anim_test.mojo
"""
from imkit.anim import Anim


def check(ok: Bool, name: String, mut fails: Int):
    print(("PASS " if ok else "FAIL ") + name)
    if not ok:
        fails += 1


def near(a: Float32, b: Float32) -> Bool:
    return abs(a - b) < 1e-5


def vel_of(an: Anim, id: Int) -> Float32:
    for k in range(len(an.id)):
        if an.id[k] == id:
            return an.vel[k]
    return -1


def main() raises:
    var fails = 0
    var an = Anim()
    an.begin(0.02)
    check(an.get(7, 3) == 3 and an.get(7, 3) == 3, "first sight starts at the target and rests there", fails)
    var a1 = Anim()
    a1.begin(0.02)
    _ = a1.get(1, 0)
    a1.begin(0.02)
    check(near(a1.get(1, 1), 0.104), "one step: v = 260 * 1 * 0.02, x = v * 0.02", fails)
    var a2 = Anim()
    a2.begin(10)
    _ = a2.get(1, 0)
    a2.begin(10)
    check(near(a2.get(1, 1), 0.65), "a 10 s stall steps like 0.05 s", fails)
    var a3 = Anim()
    a3.begin(0)
    _ = a3.get(1, 0)
    a3.begin(0)
    check(a3.get(1, 1) == 0 and a3.get(1, 1) == 0, "dt 0 does not move", fails)
    var a4 = Anim()
    a4.begin(1.0 / 60)
    _ = a4.get(1, 0)
    var peak = Float32(0)
    var settled = -1
    for k in range(120):
        a4.begin(1.0 / 60)
        var x = a4.get(1, 1)
        peak = max(peak, x)
        if settled < 0 and x == 1:
            settled = k
    check(settled >= 0 and peak < 1.05, "settles on the target in 2 s, snaps exactly, overshoot under 5%", fails)
    var a5 = Anim()
    a5.begin(0.02)
    _ = a5.get(1, 0)
    _ = a5.get(2, 0)
    _ = a5.get(3, 0)
    a5.begin(0.02)  # all three were asked for: kept
    var kept = len(a5.id)
    var b3 = a5.get(3, 1)  # moves id 3
    var v3 = vel_of(a5, 3)
    _ = a5.get(1, 0)  # id 2 not asked for
    a5.begin(0.02)
    check(kept == 3 and len(a5.id) == 2, "an id nobody asked for last frame is evicted", fails)
    check(len(a5.id) == 2 and near(vel_of(a5, 3), v3) and near(a5.cur[0] + a5.cur[1], b3 + 0), "the survivors keep their state (swap-remove)", fails)
    _ = a5.get(1, 0)
    a5.begin(0.02)
    check(a5.get(2, 5) == 5, "a returning id starts at its target", fails)
    if fails:
        raise Error("FAIL " + String(fails) + " anim checks")
    print("PASS anim_test")
