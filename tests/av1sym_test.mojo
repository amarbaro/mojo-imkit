"""Stage 3 gate (AV1 symbol decoder): random symbol streams encoded by tests/av1sym_enc.mojo (libaom's od_ec_enc) must decode
through src/imkit/av1sym.mojo to the same symbols, booleans and literals, with the decoder's adapted inverse CDFs equal to
32768 minus the encoder's adapted spec CDFs after every symbol, and exit_process() accepting the trailing bits.
Run through tests/av1sym_test.sh (also runs the mutants that prove the gate)."""
from std.os import getenv
from imkit.av1sym import SymbolDecoder
from av1sym_enc import Encoder, update


struct Rng(Movable):
    var s: UInt64

    def __init__(out self, seed: UInt64):
        self.s = seed * 0x9E3779B97F4A7C15 + 1

    def next(mut self) -> UInt64:
        self.s ^= self.s << 13
        self.s ^= self.s >> 7
        self.s ^= self.s << 17
        return self.s

    def below(mut self, n: Int) -> Int:
        return Int(self.next() % UInt64(n))


def random_cdf(mut rng: Rng, n: Int) -> List[UInt16]:
    """Spec-convention CDF: n - 1 increasing cut points in 1..32767 (ties allowed), 32768, then a random counter."""
    var cuts = List[Int]()
    for _ in range(n - 1):
        cuts.append(1 + rng.below(32767))
    sort(cuts)
    var cdf = List[UInt16]()
    for c in cuts:
        cdf.append(UInt16(c))
    cdf.append(32768)
    cdf.append(UInt16(rng.below(33)))
    return cdf^


def inverse(cdf: List[UInt16], n: Int) -> List[UInt16]:
    """The decoder's stored form: 32768 - cdf[i] for i < n, counter unchanged."""
    var icdf = List[UInt16]()
    for i in range(n):
        icdf.append(UInt16(32768 - Int(cdf[i])))
    icdf.append(cdf[n])
    return icdf^


def pick(mut rng: Rng, cdf: List[UInt16], n: Int) -> Int:
    """Half the time uniform over symbols (rare ones get coded), half by the CDF's own probabilities."""
    if rng.below(2) == 0:
        return rng.below(n)
    var u = rng.below(32768)
    for s in range(n):
        if u < Int(cdf[s]):
            return s
    return n - 1


def one_stream(seed: UInt64, adapt: Bool, mut ops: Int) raises -> String:
    """Encode then decode one random stream; empty string on success, else what differed."""
    var rng = Rng(seed)
    var k = 1 + rng.below(4)
    var ns = List[Int]()
    var enc_cdfs = List[List[UInt16]]()
    var dec_cdfs = List[List[UInt16]]()
    var exp_cdfs = List[List[UInt16]]()  # spec CDFs adapted in step with the decoder, from the same start as the encoder's
    for _ in range(k):
        var n = 2 + rng.below(15)
        var c = random_cdf(rng, n)
        ns.append(n)
        dec_cdfs.append(inverse(c, n))
        exp_cdfs.append(c.copy())
        enc_cdfs.append(c^)
    var count = 1 + rng.below(300)
    var kinds = List[Int]()  # 0 symbol, 1 bool, 2 literal
    var args = List[Int]()  # cdf index, or literal bit count
    var vals = List[Int]()
    var enc = Encoder()
    for _ in range(count):
        var kind = rng.below(4)
        if kind >= 2:
            kind = 0 if kind == 2 else (1 if rng.below(2) == 0 else 2)
        if kind == 0:
            var j = rng.below(k)
            var s = pick(rng, enc_cdfs[j], ns[j])
            enc.encode(enc_cdfs[j], s, ns[j], adapt)
            args.append(j)
            vals.append(s)
        elif kind == 1:
            var b = rng.below(2)
            enc.encode_bool(b == 1)
            args.append(0)
            vals.append(b)
        else:
            var bits = 1 + rng.below(16)
            var x = rng.below(1 << bits)
            for i in range(bits - 1, -1, -1):
                enc.encode_bool(((x >> i) & 1) == 1)
            args.append(bits)
            vals.append(x)
        kinds.append(kind)
    var data = enc.finish()
    var dec = SymbolDecoder(Span(data), 0, len(data))
    dec.disable_cdf_update = not adapt
    for i in range(count):
        ops += 1
        if kinds[i] == 0:
            var j = args[i]
            var got = dec.read_symbol(dec_cdfs[j], ns[j])
            if got != vals[i]:
                return "op " + String(i) + " symbol n=" + String(ns[j]) + " want " + String(vals[i]) + " got " + String(got)
            if adapt:
                update(exp_cdfs[j], vals[i], ns[j])
            for t in range(ns[j] + 1):
                var want = Int(exp_cdfs[j][t]) if t == ns[j] else 32768 - Int(exp_cdfs[j][t])
                if Int(dec_cdfs[j][t]) != want:
                    return "op " + String(i) + " cdf[" + String(t) + "] want " + String(want) + " got " + String(dec_cdfs[j][t])
        elif kinds[i] == 1:
            var b = 1 if dec.read_bool() else 0
            if b != vals[i]:
                return "op " + String(i) + " bool want " + String(vals[i]) + " got " + String(b)
        else:
            var x = dec.read_literal(args[i])
            if x != vals[i]:
                return "op " + String(i) + " literal(" + String(args[i]) + ") want " + String(vals[i]) + " got " + String(x)
    dec.exit_process()
    return ""


def main() raises:
    var n = Int(getenv("AV1SYM_STREAMS", "3000"))
    var fails = 0
    var ops = 0
    for seed in range(1, n + 1):
        var adapt = seed % 5 != 0
        var why: String
        try:
            why = one_stream(UInt64(seed), adapt, ops)
        except e:
            why = "raised: " + String(e)
        if why != "":
            fails += 1
            if fails <= 5:
                print("FAIL stream", seed, "adapt", adapt, ":", why)
    print("streams", n, "ops", ops, "fails", fails)
    if fails > 0:
        raise Error("FAIL av1sym round trip")
    print("PASS av1sym")
