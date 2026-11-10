"""Test-only AV1 symbol ENCODER (libaom od_ec_enc: od_ec_encode_q15, normalize with a 16-bit precarry buffer, od_ec_enc_done),
written independently of src/imkit/av1sym.mojo so the stage-3 gate can round-trip random symbol streams through the decoder.
CDFs here use the AV1 spec convention: increasing cumulative values ending at 32768, then a counter (spec 8.2.6)."""

comptime EC_PROB_SHIFT = 6
comptime EC_MIN_PROB = 4


def ilog_nz(v: UInt32) -> Int:
    """Number of bits needed for v > 0 (OD_ILOG_NZ)."""
    var n = 0
    var x = v
    while x > 0:
        n += 1
        x >>= 1
    return n


struct Encoder(Movable):
    var low: UInt64
    var rng: UInt32
    var cnt: Int
    var pre: List[UInt16]

    def __init__(out self):
        self.low = 0
        self.rng = 0x8000
        self.cnt = -9
        self.pre = List[UInt16]()

    def _normalize(mut self, low_in: UInt64, rng: UInt32):
        var low = low_in
        var c = self.cnt
        var d = 16 - ilog_nz(rng)
        var s = c + d
        if s >= 0:
            c += 16
            var m = (UInt64(1) << UInt64(c)) - 1
            if s >= 8:
                self.pre.append(UInt16((low >> UInt64(c)) & 0xFFFF))
                low &= m
                c -= 8
                m >>= 8
            self.pre.append(UInt16((low >> UInt64(c)) & 0xFFFF))
            s = c + d - 24
            low &= m
        self.low = low << UInt64(d)
        self.rng = rng << UInt32(d)
        self.cnt = s

    def encode(mut self, mut cdf: List[UInt16], s: Int, n: Int, adapt: Bool):
        """Encode symbol s of an n-symbol CDF (spec convention), then adapt it like the decoder must (spec 8.2.6)."""
        var fl: UInt32 = 32768 if s == 0 else 32768 - UInt32(cdf[s - 1])  # inverse CDF, libaom's icdf
        var fh: UInt32 = 32768 - UInt32(cdf[s])
        var nm1 = n - 1
        var r = self.rng
        var l = self.low
        if fl < 32768:
            var u = ((r >> 8) * (fl >> EC_PROB_SHIFT) >> (7 - EC_PROB_SHIFT)) + UInt32(EC_MIN_PROB * (nm1 - (s - 1)))
            var v = ((r >> 8) * (fh >> EC_PROB_SHIFT) >> (7 - EC_PROB_SHIFT)) + UInt32(EC_MIN_PROB * (nm1 - s))
            l += UInt64(r - u)
            r = u - v
        else:
            r -= ((r >> 8) * (fh >> EC_PROB_SHIFT) >> (7 - EC_PROB_SHIFT)) + UInt32(EC_MIN_PROB * (nm1 - s))
        self._normalize(l, r)
        if adapt:
            update(cdf, s, n)

    def encode_bool(mut self, b: Bool):
        var cdf: List[UInt16] = [16384, 32768, 0]
        self.encode(cdf, 1 if b else 0, 2, False)

    def finish(mut self) -> List[UInt8]:
        """od_ec_enc_done: flush low, then resolve carries from the 16-bit precarry buffer into bytes."""
        var m: UInt64 = 0x3FFF
        var e = ((self.low + m) & ~m) | (m + 1)
        var c = self.cnt
        var s = c + 10
        if s > 0:
            var nmask = (UInt64(1) << UInt64(c + 16)) - 1
            while True:
                self.pre.append(UInt16((e >> UInt64(c + 16)) & 0xFFFF))
                e &= nmask
                s -= 8
                c -= 8
                nmask >>= 8
                if s <= 0:
                    break
        var out = List[UInt8](length=len(self.pre), fill=0)
        var carry = 0
        var i = len(self.pre) - 1
        while i >= 0:
            carry = Int(self.pre[i]) + carry
            out[i] = UInt8(carry & 255)
            carry >>= 8
            i -= 1
        return out^


def update(mut cdf: List[UInt16], s: Int, n: Int):
    """Spec 8.2.6 CDF adaptation (increasing convention, counter in cdf[n])."""
    var cnt = Int(cdf[n])
    var lg = 0
    var x = n
    while x > 1:
        lg += 1
        x >>= 1
    var rate = 3 + (1 if cnt > 15 else 0) + (1 if cnt > 31 else 0) + min(lg, 2)
    var tmp = 0
    for i in range(n - 1):
        if i == s:
            tmp = 32768
        var v = Int(cdf[i])
        if tmp < v:
            cdf[i] = UInt16(v - ((v - tmp) >> rate))
        else:
            cdf[i] = UInt16(v + ((tmp - v) >> rate))
    if cnt < 32:
        cdf[n] = UInt16(cnt + 1)
