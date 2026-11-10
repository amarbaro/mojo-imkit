"""AVIF image sequence (brand `avis`) timing and sample table: what `avifdec --info` reports for an animation.

Walks moov / trak for the colour track (handler `pict`), reads mdhd (timescale), stts (frame durations), stsz / stsc / stco / co64
(sample sizes and file offsets), the `av01` sample entry (width, height), the track's elst + tkhd (repetition count). No sample is
decoded: frames after the first are normally inter frames, which this decoder does not implement."""

comptime FOURCC_MOOV = 0x6D6F6F76
comptime FOURCC_TRAK = 0x7472616B
comptime FOURCC_MDIA = 0x6D646961
comptime FOURCC_MINF = 0x6D696E66
comptime FOURCC_STBL = 0x7374626C
comptime FOURCC_EDTS = 0x65647473
comptime FOURCC_TKHD = 0x746B6864
comptime FOURCC_MDHD = 0x6D646864
comptime FOURCC_ELST = 0x656C7374
comptime FOURCC_STTS = 0x73747473
comptime FOURCC_STSZ = 0x7374737A
comptime FOURCC_STSC = 0x73747363
comptime FOURCC_STCO = 0x7374636F
comptime FOURCC_CO64 = 0x636F3634
comptime FOURCC_STSD = 0x73747364
comptime FOURCC_HDLR = 0x68646C72
comptime FOURCC_PICT = 0x70696374


struct SeqInfo(Copyable, Movable):
    var timescale: Int  # media timescale (ticks per second)
    var duration: Int  # sum of the frame durations, in ticks
    var width: Int
    var height: Int
    var repeat_count: Int  # -1 = infinite
    var pts: List[Int]  # per frame, ticks
    var durations: List[Int]  # per frame, ticks
    var sample_off: List[Int]  # per frame, absolute file offset of its AV1 temporal unit
    var sample_size: List[Int]

    def __init__(out self):
        self.timescale = 0
        self.duration = 0
        self.width = 0
        self.height = 0
        self.repeat_count = 0
        self.pts = List[Int]()
        self.durations = List[Int]()
        self.sample_off = List[Int]()
        self.sample_size = List[Int]()


def be(d: Span[UInt8, _], o: Int, n: Int) raises -> Int:
    if o < 0 or o + n > len(d):
        raise Error("avifseq: read beyond the file")
    var v = 0
    for i in range(n):
        v = (v << 8) | Int(d[o + i])
    return v


def find_box(d: Span[UInt8, _], start: Int, end: Int, typ: Int, skip: Int = 0) raises -> Tuple[Int, Int]:
    """(payload start, box end) of the `skip`-th child box of that type in [start, end), or (-1, -1)."""
    var o = start
    var seen = 0
    while o + 8 <= end:
        var sz = be(d, o, 4)
        var hdr = 8
        if sz == 1:
            sz = be(d, o + 8, 8)
            hdr = 16
        elif sz == 0:
            sz = end - o
        if sz < hdr or o + sz > end:
            raise Error("avifseq: bad box size")
        if be(d, o + 4, 4) == typ:
            if seen == skip:
                return (o + hdr, o + sz)
            seen += 1
        o += sz
    return (-1, -1)


def avis_info(d: Span[UInt8, _]) raises -> SeqInfo:
    var moov = find_box(d, 0, len(d), FOURCC_MOOV)
    if moov[0] < 0:
        raise Error("avifseq: no moov box (not an image sequence)")
    var info = SeqInfo()
    var k = 0
    while True:
        var trak = find_box(d, moov[0], moov[1], FOURCC_TRAK, k)
        if trak[0] < 0:
            raise Error("avifseq: no colour track")
        k += 1
        var mdia = find_box(d, trak[0], trak[1], FOURCC_MDIA)
        if mdia[0] < 0:
            continue
        var hdlr = find_box(d, mdia[0], mdia[1], FOURCC_HDLR)
        if hdlr[0] < 0 or be(d, hdlr[0] + 8, 4) != FOURCC_PICT:
            continue
        var mdhd = find_box(d, mdia[0], mdia[1], FOURCC_MDHD)
        if mdhd[0] < 0:
            raise Error("avifseq: no mdhd")
        info.timescale = be(d, mdhd[0] + (20 if be(d, mdhd[0], 1) == 1 else 12), 4)
        var minf = find_box(d, mdia[0], mdia[1], FOURCC_MINF)
        var stbl = find_box(d, minf[0], minf[1], FOURCC_STBL)
        if stbl[0] < 0:
            raise Error("avifseq: no stbl")
        # frame durations
        var stts = find_box(d, stbl[0], stbl[1], FOURCC_STTS)
        if stts[0] < 0:
            raise Error("avifseq: no stts")
        var n_entries = be(d, stts[0] + 4, 4)
        var t = 0
        for e in range(n_entries):
            var cnt = be(d, stts[0] + 8 + e * 8, 4)
            var delta = be(d, stts[0] + 12 + e * 8, 4)
            if cnt > 1 << 20:
                raise Error("avifseq: absurd sample count")
            for _ in range(cnt):
                info.pts.append(t)
                info.durations.append(delta)
                t += delta
        info.duration = t
        # sample sizes
        var stsz = find_box(d, stbl[0], stbl[1], FOURCC_STSZ)
        if stsz[0] < 0:
            raise Error("avifseq: no stsz")
        var fixed = be(d, stsz[0] + 4, 4)
        var count = be(d, stsz[0] + 8, 4)
        if count != len(info.pts):
            raise Error("avifseq: stsz and stts disagree on the frame count")
        for i in range(count):
            info.sample_size.append(fixed if fixed != 0 else be(d, stsz[0] + 12 + i * 4, 4))
        # chunk offsets and samples per chunk
        var wide = False
        var stco = find_box(d, stbl[0], stbl[1], FOURCC_STCO)
        if stco[0] < 0:
            stco = find_box(d, stbl[0], stbl[1], FOURCC_CO64)
            wide = True
        var stsc = find_box(d, stbl[0], stbl[1], FOURCC_STSC)
        if stco[0] < 0 or stsc[0] < 0:
            raise Error("avifseq: no stco / stsc")
        var n_chunks = be(d, stco[0] + 4, 4)
        var n_runs = be(d, stsc[0] + 4, 4)
        var sample = 0
        for ch in range(n_chunks):
            var per = 0
            for r in range(n_runs):
                if be(d, stsc[0] + 8 + r * 12, 4) <= ch + 1:
                    per = be(d, stsc[0] + 12 + r * 12, 4)
            var off = be(d, stco[0] + 8 + ch * (8 if wide else 4), 8 if wide else 4)
            for _ in range(per):
                if sample < count:
                    info.sample_off.append(off)
                    off += info.sample_size[sample]
                    sample += 1
        if sample != count:
            raise Error("avifseq: chunk table covers " + String(sample) + " of " + String(count) + " samples")
        # frame size from the av01 sample entry: 6 reserved, 2 index, 16 predefined, then width and height
        var stsd = find_box(d, stbl[0], stbl[1], FOURCC_STSD)
        if stsd[0] >= 0:
            info.width = be(d, stsd[0] + 8 + 8 + 24, 2)
            info.height = be(d, stsd[0] + 8 + 8 + 26, 2)
        # repetition: elst flag 1 = repeat; tkhd duration all ones = forever, else duration / one pass of the edit
        var edts = find_box(d, trak[0], trak[1], FOURCC_EDTS)
        if edts[0] >= 0:
            var elst = find_box(d, edts[0], edts[1], FOURCC_ELST)
            if elst[0] >= 0 and (be(d, elst[0], 4) & 1) == 1:
                var v1 = be(d, elst[0], 1) == 1
                var seg = be(d, elst[0] + 8, 8 if v1 else 4)
                var tkhd = find_box(d, trak[0], trak[1], FOURCC_TKHD)
                var tdur = be(d, tkhd[0] + (28 if be(d, tkhd[0], 1) == 1 else 20), 8 if be(d, tkhd[0], 1) == 1 else 4)
                if tdur == (1 << 64) - 1 or tdur < 0 or (be(d, tkhd[0], 1) == 0 and tdur == 0xFFFFFFFF):
                    info.repeat_count = -1
                elif seg > 0:
                    info.repeat_count = tdur // seg - 1
        return info^
