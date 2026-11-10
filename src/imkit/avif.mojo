"""Pure Mojo AVIF container parser (stage 1: HEIF/ISOBMFF metadata only).

Parses the boxes needed to describe an AVIF image without decoding the AV1
payload: ftyp, meta (hdlr, pitm, iloc, iinf/infe, iref, iprp/ipco/ipma), and
the item properties ispe, av1C, colr nclx, auxC.

`avif_info(bytes)` returns width, height, bit depth, chroma format, alpha
presence, colour primaries/transfer/matrix and the byte range of the primary
item's AV1 data (and of the alpha auxiliary item when present).

Every length is bounds-checked and a truncated file raises.
"""

comptime FOURCC_FTYP = 0x66747970
comptime FOURCC_META = 0x6D657461
comptime FOURCC_HDLR = 0x68646C72
comptime FOURCC_PITM = 0x7069746D
comptime FOURCC_ILOC = 0x696C6F63
comptime FOURCC_IINF = 0x69696E66
comptime FOURCC_INFE = 0x696E6665
comptime FOURCC_IREF = 0x69726566
comptime FOURCC_IPRP = 0x69707270
comptime FOURCC_IPCO = 0x6970636F
comptime FOURCC_IPMA = 0x69706D61
comptime FOURCC_ISPE = 0x69737065
comptime FOURCC_PIXI = 0x70697869
comptime FOURCC_AV1C = 0x61763143
comptime FOURCC_COLR = 0x636F6C72
comptime FOURCC_AUXC = 0x61757843
comptime FOURCC_IDAT = 0x69646174
comptime FOURCC_AV01 = 0x61763031
comptime FOURCC_AUXL = 0x6175786C
comptime FOURCC_NCLX = 0x6E636C78
comptime FOURCC_RICC = 0x72494343
comptime FOURCC_PROF = 0x70726F66
comptime FOURCC_AVIF = 0x61766966
comptime FOURCC_AVIS = 0x61766973
comptime FOURCC_MIF1 = 0x6D696631
comptime FOURCC_MDAT = 0x6D646174


@fieldwise_init
struct Prop(Copyable, Movable):
    var typ: Int
    var start: Int
    var end: Int


@fieldwise_init
struct Item(Copyable, Movable):
    var id: Int
    var typ: Int
    var cm: Int
    var base_off: Int
    var ext_off: Int
    var ext_len: Int
    var off: Int
    var length: Int
    var has_loc: Bool


struct AvifInfo(Copyable, Movable):
    var width: Int
    var height: Int
    var depth: Int
    var chroma: Int
    var has_alpha: Bool
    var full_range: Bool
    var primaries: Int
    var transfer: Int
    var matrix: Int
    var primary_off: Int
    var primary_len: Int
    var alpha_off: Int
    var alpha_len: Int
    var obu0: Int

    def __init__(out self):
        self.width = 0
        self.height = 0
        self.depth = 8
        self.chroma = 420
        self.has_alpha = False
        self.full_range = True
        self.primaries = 2
        self.transfer = 2
        self.matrix = 6
        self.primary_off = 0
        self.primary_len = 0
        self.alpha_off = 0
        self.alpha_len = 0
        self.obu0 = 0


struct AvifParser(Movable):
    var d: List[UInt8]
    var info: AvifInfo
    var pitm: Int
    var pitm_found: Bool
    var items: List[Item]
    var props: List[Prop]
    var assoc_item: List[Int]
    var assoc_prop: List[Int]
    var idat_start: Int
    var idat_end: Int
    var has_idat: Bool
    var ftyp_ok: Bool
    var auxl_from: List[Int]
    var auxl_to: List[Int]

    def __init__(out self, src: Span[UInt8, _]):
        self.d = List[UInt8]()
        self.d.extend(src)
        self.info = AvifInfo()
        self.pitm = 0
        self.pitm_found = False
        self.items = List[Item]()
        self.props = List[Prop]()
        self.assoc_item = List[Int]()
        self.assoc_prop = List[Int]()
        self.idat_start = 0
        self.idat_end = 0
        self.has_idat = False
        self.ftyp_ok = False
        self.auxl_from = List[Int]()
        self.auxl_to = List[Int]()

    # ---- helpers ----

    def be16(self, p: Int) -> Int:
        return Int(self.d[p]) << 8 | Int(self.d[p + 1])

    def be32(self, p: Int) -> Int:
        return (Int(self.d[p]) << 24) | (Int(self.d[p + 1]) << 16) | (Int(self.d[p + 2]) << 8) | Int(self.d[p + 3])

    def be64(self, p: Int) -> Int:
        var v = 0
        for i in range(8):
            v = (v << 8) | Int(self.d[p + i])
        return v

    def read_n(self, p: Int, n: Int, limit: Int) raises -> Int:
        if n == 0:
            return 0
        if p + n > limit:
            raise Error("avif: truncated field")
        var v = 0
        for i in range(n):
            v = (v << 8) | Int(self.d[p + i])
        return v

    def box_header(self, p: Int, limit: Int) raises -> Tuple[Int, Int, Int, Int]:
        if p + 8 > limit:
            raise Error("avif: truncated box header")
        var sz = self.be32(p)
        var typ = self.be32(p + 4)
        var hs = 8
        if sz == 1:
            if p + 16 > limit:
                raise Error("avif: truncated box size")
            var big = self.be64(p + 8)
            if big < 16 or big > limit - p:
                raise Error("avif: bad box size")
            sz = Int(big)
            hs = 16
        elif sz == 0:
            sz = limit - p
        elif sz < 8 or p + sz > limit:
            raise Error("avif: bad box size")
        return (typ, p + hs, p + sz, p + sz)

    def find_item(self, id: Int) -> Int:
        for i in range(len(self.items)):
            if self.items[i].id == id:
                return i
        return -1

    def ensure_item(mut self, id: Int) -> Int:
        var i = self.find_item(id)
        if i < 0:
            self.items.append(Item(id, 0, 0, 0, 0, 0, 0, 0, False))
            i = len(self.items) - 1
        return i

    def item_props(self, id: Int) -> List[Int]:
        var r = List[Int]()
        for i in range(len(self.assoc_item)):
            if self.assoc_item[i] == id:
                r.append(self.assoc_prop[i])
        return r^

    # ---- boxes ----

    def parse_ftyp(mut self, s: Int, e: Int) raises:
        if e - s < 8:
            raise Error("avif: bad ftyp")
        var major = self.be32(s)
        var ok = major == FOURCC_AVIF or major == FOURCC_AVIS or major == FOURCC_MIF1
        var p = s + 8
        while p + 4 <= e:
            var b = self.be32(p)
            if b == FOURCC_AVIF or b == FOURCC_AVIS or b == FOURCC_MIF1:
                ok = True
            p += 4
        if not ok:
            raise Error("avif: not an AVIF file (ftyp)")
        self.ftyp_ok = True

    def parse_meta(mut self, s: Int, e: Int) raises:
        if s + 4 > e:
            raise Error("avif: truncated meta")
        var p = s + 4
        while p < e:
            var typ, ps, pe, nxt = self.box_header(p, e)
            if typ == FOURCC_HDLR:
                if pe - ps < 12:
                    raise Error("avif: bad hdlr")
            elif typ == FOURCC_PITM:
                self.parse_pitm(ps, pe)
            elif typ == FOURCC_ILOC:
                self.parse_iloc(ps, pe)
            elif typ == FOURCC_IINF:
                self.parse_iinf(ps, pe)
            elif typ == FOURCC_IREF:
                self.parse_iref(ps, pe)
            elif typ == FOURCC_IPRP:
                self.parse_iprp(ps, pe)
            elif typ == FOURCC_IDAT:
                self.idat_start = ps
                self.idat_end = pe
                self.has_idat = True
            p = nxt

    def parse_pitm(mut self, s: Int, e: Int) raises:
        if s + 4 > e:
            raise Error("avif: bad pitm")
        var ver = Int(self.d[s])
        if ver == 0:
            if s + 6 > e:
                raise Error("avif: bad pitm")
            self.pitm = self.be16(s + 4)
        else:
            if s + 8 > e:
                raise Error("avif: bad pitm")
            self.pitm = self.be32(s + 4)
        self.pitm_found = True

    def parse_iloc(mut self, s: Int, e: Int) raises:
        if s + 4 > e:
            raise Error("avif: bad iloc")
        var ver = Int(self.d[s])
        if ver > 2:
            raise Error("avif: iloc version " + String(ver))
        var p = s + 4
        if p + 2 > e:
            raise Error("avif: bad iloc")
        var b = Int(self.d[p])
        var offset_size = b >> 4
        var length_size = b & 15
        p += 1
        b = Int(self.d[p])
        var base_offset_size = b >> 4
        var index_size = 0
        if ver >= 1:
            index_size = b & 15
        p += 1
        if p + 2 > e:
            raise Error("avif: bad iloc")
        var item_count = self.be16(p)
        p += 2
        for _ in range(item_count):
            var item_id = 0
            if ver < 2:
                if p + 2 > e:
                    raise Error("avif: truncated iloc item")
                item_id = self.be16(p)
                p += 2
            else:
                if p + 4 > e:
                    raise Error("avif: truncated iloc item")
                item_id = self.be32(p)
                p += 4
            var cm = 0
            if ver >= 1:
                if p + 2 > e:
                    raise Error("avif: truncated iloc item")
                cm = self.be16(p) & 15
                p += 2
            if p + 2 > e:
                raise Error("avif: truncated iloc item")
            p += 2  # data_reference_index
            var base_off = self.read_n(p, base_offset_size, e)
            p += base_offset_size
            if p + 2 > e:
                raise Error("avif: truncated iloc item")
            var extent_count = self.be16(p)
            p += 2
            var first_off = 0
            var total_len = 0
            for j in range(extent_count):
                if index_size > 0:
                    _ = self.read_n(p, index_size, e)
                    p += index_size
                var ext_off = self.read_n(p, offset_size, e)
                p += offset_size
                var ext_len = self.read_n(p, length_size, e)
                p += length_size
                if j == 0:
                    first_off = ext_off
                total_len += ext_len
            var idx = self.ensure_item(item_id)
            self.items[idx].cm = cm
            self.items[idx].base_off = base_off
            self.items[idx].ext_off = first_off
            self.items[idx].ext_len = total_len
            self.items[idx].has_loc = True

    def parse_iinf(mut self, s: Int, e: Int) raises:
        if s + 4 > e:
            raise Error("avif: bad iinf")
        var ver = Int(self.d[s])
        var p = s + 4
        var count = 0
        if ver == 0:
            if p + 2 > e:
                raise Error("avif: bad iinf")
            count = self.be16(p)
            p += 2
        else:
            if p + 4 > e:
                raise Error("avif: bad iinf")
            count = self.be32(p)
            p += 4
        for _ in range(count):
            var typ, ps, pe, nxt = self.box_header(p, e)
            if typ == FOURCC_INFE:
                self.parse_infe(ps, pe)
            p = nxt

    def parse_infe(mut self, s: Int, e: Int) raises:
        if s + 4 > e:
            raise Error("avif: bad infe")
        var ver = Int(self.d[s])
        var p = s + 4
        if ver < 2:
            return
        var item_id = 0
        if ver == 2:
            if p + 4 > e:
                raise Error("avif: bad infe")
            item_id = self.be16(p)
            p += 4
        else:
            if p + 6 > e:
                raise Error("avif: bad infe")
            item_id = self.be32(p)
            p += 6
        if p + 4 > e:
            raise Error("avif: bad infe")
        var ityp = self.be32(p)
        var idx = self.ensure_item(item_id)
        self.items[idx].typ = ityp

    def parse_iref(mut self, s: Int, e: Int) raises:
        if s + 4 > e:
            raise Error("avif: bad iref")
        var ver = Int(self.d[s])
        var p = s + 4
        while p < e:
            var typ, ps, pe, nxt = self.box_header(p, e)
            var q = ps
            var from_id = 0
            var cnt = 0
            if ver == 0:
                if q + 4 > pe:
                    raise Error("avif: bad iref")
                from_id = self.be16(q)
                cnt = self.be16(q + 2)
                q += 4
            else:
                if q + 6 > pe:
                    raise Error("avif: bad iref")
                from_id = self.be32(q)
                cnt = self.be16(q + 4)
                q += 6
            for _ in range(cnt):
                var to_id = 0
                if ver == 0:
                    if q + 2 > pe:
                        raise Error("avif: bad iref")
                    to_id = self.be16(q)
                    q += 2
                else:
                    if q + 4 > pe:
                        raise Error("avif: bad iref")
                    to_id = self.be32(q)
                    q += 4
                if typ == FOURCC_AUXL:
                    self.auxl_from.append(from_id)
                    self.auxl_to.append(to_id)
            p = nxt

    def parse_iprp(mut self, s: Int, e: Int) raises:
        var p = s
        while p < e:
            var typ, ps, pe, nxt = self.box_header(p, e)
            if typ == FOURCC_IPCO:
                self.parse_ipco(ps, pe)
            elif typ == FOURCC_IPMA:
                self.parse_ipma(ps, pe)
            p = nxt

    def parse_ipco(mut self, s: Int, e: Int) raises:
        var p = s
        while p < e:
            var typ, ps, pe, nxt = self.box_header(p, e)
            self.props.append(Prop(typ, ps, pe))
            p = nxt

    def parse_ipma(mut self, s: Int, e: Int) raises:
        if s + 4 > e:
            raise Error("avif: bad ipma")
        var ver = Int(self.d[s])
        var flags = (Int(self.d[s + 1]) << 16) | (Int(self.d[s + 2]) << 8) | Int(self.d[s + 3])
        var wide = (flags & 1) != 0
        var p = s + 4
        if p + 4 > e:
            raise Error("avif: bad ipma")
        var entry_count = self.be32(p)
        p += 4
        for _ in range(entry_count):
            var item_id = 0
            if ver < 1:
                if p + 2 > e:
                    raise Error("avif: bad ipma")
                item_id = self.be16(p)
                p += 2
            else:
                if p + 4 > e:
                    raise Error("avif: bad ipma")
                item_id = self.be32(p)
                p += 4
            if p + 1 > e:
                raise Error("avif: bad ipma")
            var assoc_count = Int(self.d[p])
            p += 1
            for _ in range(assoc_count):
                var idx = 0
                if wide:
                    if p + 2 > e:
                        raise Error("avif: bad ipma")
                    idx = self.be16(p) & 0x7FFF
                    p += 2
                else:
                    if p + 1 > e:
                        raise Error("avif: bad ipma")
                    idx = Int(self.d[p]) & 0x7F
                    p += 1
                if idx > 0:
                    self.assoc_item.append(item_id)
                    self.assoc_prop.append(idx)

    # ---- properties ----

    def parse_ispe(self, s: Int, e: Int) raises -> Tuple[Int, Int]:
        if s + 12 > e:
            raise Error("avif: bad ispe")
        return (self.be32(s + 4), self.be32(s + 8))

    def parse_av1c(self, s: Int, e: Int) raises -> Tuple[Int, Int]:
        if s + 4 > e:
            raise Error("avif: bad av1C")
        var b2 = Int(self.d[s + 2])
        var high_bitdepth = (b2 >> 6) & 1
        var twelve_bit = (b2 >> 5) & 1
        var monochrome = (b2 >> 4) & 1
        var sub_x = (b2 >> 3) & 1
        var sub_y = (b2 >> 2) & 1
        var depth = 8
        if high_bitdepth == 1:
            depth = 10
            if twelve_bit == 1:
                depth = 12
        var chroma = 444
        if monochrome == 1:
            chroma = 400
        elif sub_x == 1 and sub_y == 1:
            chroma = 420
        elif sub_x == 1 and sub_y == 0:
            chroma = 422
        return (depth, chroma)

    def parse_colr(mut self, s: Int, e: Int) raises:
        if s + 4 > e:
            raise Error("avif: bad colr")
        var ctyp = self.be32(s)
        if ctyp == FOURCC_NCLX:
            if s + 11 > e:
                raise Error("avif: bad nclx")
            self.info.primaries = self.be16(s + 4)
            self.info.transfer = self.be16(s + 6)
            self.info.matrix = self.be16(s + 8)
            self.info.full_range = ((Int(self.d[s + 10]) >> 7) & 1) == 1

    def auxc_is_alpha(self, s0: Int, e: Int) -> Bool:
        var s = s0 + 4  # auxC is a FullBox: version and flags come before the URN
        var urn = "urn:mpeg:mpegB:cicp:systems:auxiliary:alpha".as_bytes()
        var n = len(urn)
        if s + n + 1 > e:
            return False
        for i in range(n):
            if self.d[s + i] != urn[i]:
                return False
        return self.d[s + n] == 0

    # ---- resolution ----

    def resolve_locations(mut self) raises:
        for i in range(len(self.items)):
            if not self.items[i].has_loc:
                continue
            var off = self.items[i].base_off + self.items[i].ext_off
            var cm = self.items[i].cm
            if cm == 1:
                if not self.has_idat:
                    raise Error("avif: iloc construction_method 1 without idat")
                off += self.idat_start
            elif cm == 2:
                raise Error("avif: iloc construction_method 2 not supported")
            var ln = self.items[i].ext_len
            if off < 0 or ln < 0 or off + ln > len(self.d):
                raise Error("avif: item data out of bounds")
            self.items[i].off = off
            self.items[i].length = ln

    def resolve_primary(mut self) raises:
        var idx = self.find_item(self.pitm)
        if idx < 0:
            raise Error("avif: primary item not in iloc")
        var it = self.items[idx].copy()
        if not it.has_loc:
            raise Error("avif: primary item has no location")
        if it.length < 1:
            raise Error("avif: primary item data is empty")
        if it.off >= len(self.d):
            raise Error("avif: primary item data out of bounds")
        self.info.primary_off = it.off
        self.info.primary_len = it.length
        self.info.obu0 = Int(self.d[it.off])

        var props = self.item_props(self.pitm)
        var have_ispe = False
        var have_av1c = False
        for pi in props:
            if pi < 1 or pi > len(self.props):
                continue
            var pr = self.props[pi - 1].copy()
            if pr.typ == FOURCC_ISPE:
                var w, h = self.parse_ispe(pr.start, pr.end)
                self.info.width = w
                self.info.height = h
                have_ispe = True
            elif pr.typ == FOURCC_AV1C:
                var dep, ch = self.parse_av1c(pr.start, pr.end)
                self.info.depth = dep
                self.info.chroma = ch
                have_av1c = True
            elif pr.typ == FOURCC_COLR:
                self.parse_colr(pr.start, pr.end)
        if not have_ispe:
            raise Error("avif: primary item has no ispe")
        if not have_av1c:
            raise Error("avif: primary item has no av1C")

    def resolve_alpha(mut self) raises:
        var best = -1
        for i in range(len(self.items)):
            var id = self.items[i].id
            if id == self.pitm:
                continue
            if not self.items[i].has_loc:
                continue
            var props = self.item_props(id)
            var is_alpha = False
            for pi in props:
                if pi < 1 or pi > len(self.props):
                    continue
                var pr = self.props[pi - 1].copy()
                if pr.typ == FOURCC_AUXC and self.auxc_is_alpha(pr.start, pr.end):
                    is_alpha = True
            if not is_alpha:
                continue
            var linked = False
            for k in range(len(self.auxl_from)):
                if self.auxl_from[k] == id and self.auxl_to[k] == self.pitm:
                    linked = True
            if linked or best < 0:
                best = i
                if linked:
                    break
        if best >= 0:
            self.info.has_alpha = True
            self.info.alpha_off = self.items[best].off
            self.info.alpha_len = self.items[best].length

    # ---- entry ----

    def parse(mut self) raises:
        var n = len(self.d)
        var p = 0
        while p < n:
            var typ, ps, pe, nxt = self.box_header(p, n)
            if typ == FOURCC_FTYP:
                self.parse_ftyp(ps, pe)
            elif typ == FOURCC_META:
                self.parse_meta(ps, pe)
            p = nxt
        if not self.ftyp_ok:
            raise Error("avif: no ftyp box")
        if not self.pitm_found:
            raise Error("avif: no pitm box")
        self.resolve_locations()
        self.resolve_primary()
        self.resolve_alpha()


def avif_info(d: Span[UInt8, _]) raises -> AvifInfo:
    var p = AvifParser(d)
    p.parse()
    return p.info.copy()
