"""AV1 symbol (range) decoder, spec section 8.2 — no default CDF tables.

This is the entropy decoder every tile is read through: init_symbol(sz)
(8.2.2), read_symbol(cdf) (8.2.6) with the CDF adaptation, read_bool()
(8.2.2), read_literal(n) (8.2.5) and exit_symbol() (8.2.4). The default
CDF tables are not here; they come from a converter in a later stage.

CDF layout (matches the stored default tables byte for byte): a CDF for N
symbols is a List[UInt16] of N + 1 entries. Entry i (i < N) is the inverse
cumulative value 32768 - CDF(i), i.e. exactly the spec's
f = (1 << 15) - cdf[symbol]; entry N - 1 is 0, and entry N is the adaptation
counter (0..32). A converter copies libaom's AOM_CDFn tables in unchanged.

Past the end of the tile the decoder feeds zero bits, as 8.2.2 requires
(SymbolMaxBits goes negative); no byte outside the tile range is ever read.
AV1 has no unary-coded syntax element — coefficient reading (5.11.39) uses
read_symbol and read_literal only — so there is no read_unary().
"""

comptime EC_PROB_SHIFT = 6
comptime EC_MIN_PROB = 4  # must be <= (1 << EC_PROB_SHIFT) / 16
comptime CDF_PROB_TOP = 1 << 15
comptime CDF_COUNT_MAX = 32


def floor_log2(x: Int) -> Int:
    """FloorLog2(x): index of the highest set bit of x, for x >= 1."""
    var n = 0
    var v = x
    while v > 1:
        v >>= 1
        n += 1
    return n


def update_cdf(mut cdf: List[UInt16], symbol: Int, n: Int) raises:
    """CDF adaptation (section 8.2.6), in the stored inverse-CDF form.

    The spec walks the normal cumulative values with tmp = 0 before `symbol`
    and tmp = 1 << 15 from `symbol` on; complementing gives target = 1 << 15
    before `symbol` and 0 from it, which is what the stored entries move to.
    """
    if n < 2 or len(cdf) < n + 1:
        raise Error("av1sym: bad CDF for adaptation")
    var count = Int(cdf[n])
    var rate = 3 + (1 if count > 15 else 0) + (1 if count > 31 else 0) + min(floor_log2(n), 2)
    for i in range(n - 1):
        var target = 0
        if i < symbol:
            target = 1 << 15
        var v = Int(cdf[i])
        if target > v:
            v += (target - v) >> rate
        else:
            v -= (v - target) >> rate
        cdf[i] = UInt16(v)
    if count < CDF_COUNT_MAX:
        cdf[n] = UInt16(count + 1)


struct SymbolDecoder(Movable):
    """init_symbol(sz) state and the decoding processes of section 8.2."""

    var d: List[UInt8]  # the tile's bytes, copied out of the span
    var bit_pos: Int  # bits consumed from d (the spec's get_position())
    var symbol_value: Int
    var symbol_range: Int
    var symbol_max_bits: Int
    var disable_cdf_update: Bool

    def __init__(out self, src: Span[UInt8, _], start: Int, end: Int) raises:
        """Initialization process for symbol decoder (section 8.2.2), sz = end - start."""
        self.d = List[UInt8]()
        self.bit_pos = 0
        self.symbol_value = 0
        self.symbol_range = CDF_PROB_TOP
        self.symbol_max_bits = 0
        self.disable_cdf_update = False
        if start < 0 or end < start or end > len(src):
            raise Error("av1sym: bad tile byte range")
        if end == start:
            raise Error("av1sym: empty tile")
        for i in range(start, end):
            self.d.append(src[i])
        var sz = end - start
        var num_bits = min(sz * 8, 15)
        var buf = self.read_bits(num_bits)
        var padded = buf << (15 - num_bits)
        self.symbol_value = ((1 << 15) - 1) ^ padded
        self.symbol_range = 1 << 15
        self.symbol_max_bits = 8 * sz - 15

    # ---- bit input (the f(n) parsing process, section 5.3.4) ----

    def read_bits(mut self, n: Int) raises -> Int:
        """f(n) over the tile bytes; bits past the tile end read as zero (section 8.2.2)."""
        if n < 0 or n > 32:
            raise Error("av1sym: bad bit count")
        var total = len(self.d) * 8
        var v = 0
        for _ in range(n):
            v <<= 1
            if self.bit_pos < total:
                var byte = Int(self.d[self.bit_pos >> 3])
                v |= (byte >> (7 - (self.bit_pos & 7))) & 1
            self.bit_pos += 1
        return v

    def bit_at(self, p: Int) -> Int:
        """Bit p of the tile, zero outside it (used by the exit process)."""
        var total = len(self.d) * 8
        if p < 0 or p >= total:
            return 0
        return (Int(self.d[p >> 3]) >> (7 - (p & 7))) & 1

    def tell(self) -> Int:
        """Current bit position inside the tile."""
        return self.bit_pos

    # ---- range decoding (section 8.2.6) ----

    def renormalize(mut self) raises:
        """Range and value renormalisation, the ordered steps of section 8.2.6."""
        if self.symbol_range <= 0:
            raise Error("av1sym: empty symbol range")
        var bits = 15 - floor_log2(self.symbol_range)
        self.symbol_range <<= bits
        var num_bits = min(bits, max(0, self.symbol_max_bits))
        var new_data = self.read_bits(num_bits)
        var padded = new_data << (bits - num_bits)
        self.symbol_value = padded ^ (((self.symbol_value + 1) << bits) - 1)
        self.symbol_max_bits -= bits

    def read_symbol(mut self, mut cdf: List[UInt16], n: Int) raises -> Int:
        """Symbol decoding process (section 8.2.6), CDF adapted when enabled."""
        if n < 2:
            raise Error("av1sym: a CDF needs at least two symbols")
        if len(cdf) < n + 1:
            raise Error("av1sym: CDF shorter than N + 1")
        var cur = self.symbol_range
        var prev = cur
        var symbol = -1
        while True:
            symbol += 1
            if symbol >= n:
                raise Error("av1sym: symbol ran past the CDF")
            prev = cur
            var f = Int(cdf[symbol])
            cur = ((self.symbol_range >> 8) * (f >> EC_PROB_SHIFT)) >> (7 - EC_PROB_SHIFT)
            cur += EC_MIN_PROB * (n - symbol - 1)
            if self.symbol_value >= cur:
                break
        self.symbol_range = prev - cur
        if self.symbol_range <= 0:
            raise Error("av1sym: empty symbol range")
        self.symbol_value -= cur
        self.renormalize()
        if not self.disable_cdf_update:
            update_cdf(cdf, symbol, n)
        return symbol

    def read_bool(mut self) raises -> Bool:
        """Boolean decoding process (section 8.2.3): read_symbol on [1<<14, 1<<15, 0].

        The CDF is fixed and never reused, so the adaptation is omitted
        (the note under 8.2.3); this is the hot path of read_literal.
        """
        var cur = ((self.symbol_range >> 8) * ((1 << 14) >> EC_PROB_SHIFT)) >> (7 - EC_PROB_SHIFT)
        cur += EC_MIN_PROB
        var symbol = 0
        var prev = self.symbol_range
        if self.symbol_value < cur:
            symbol = 1
            prev = cur
            cur = 0
        self.symbol_range = prev - cur
        if self.symbol_range <= 0:
            raise Error("av1sym: empty symbol range")
        self.symbol_value -= cur
        self.renormalize()
        return symbol == 1

    def read_literal(mut self, n: Int) raises -> Int:
        """read_literal(n) (section 8.2.5)."""
        var x = 0
        for _ in range(n):
            if self.read_bool():
                x = 2 * x + 1
            else:
                x = 2 * x
        return x

    # ---- exit (section 8.2.4) ----

    def exit_process(self) raises:
        """exit_symbol() (section 8.2.4): trailing one bit, then zero padding."""
        if self.symbol_max_bits < -14:
            raise Error("av1sym: symbol decoder overran its tile")
        var trailing = self.bit_pos - min(15, self.symbol_max_bits + 15)
        var padding_end = self.bit_pos + max(0, self.symbol_max_bits)
        if self.bit_at(trailing) != 1:
            raise Error("av1sym: trailing bit is not 1")
        for p in range(trailing + 1, padding_end):
            if self.bit_at(p) != 0:
                raise Error("av1sym: nonzero padding after the trailing bit")
