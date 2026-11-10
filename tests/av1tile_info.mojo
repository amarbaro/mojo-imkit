"""Parse every tile of an AVIF's primary (and alpha) item, or of a raw .obu file, and print one line per tile.

Usage: av1tile_info FILE
A tile passes when parse_tiles() returns for it: its symbol decoder ended exactly at the tile end (exit_process(), spec 8.2.4)
and its blocks covered every 4x4 unit of the tile. Any symbol read wrong desyncs the decoder, which then ends elsewhere."""
from std.sys import argv
from imkit.avif import avif_info
from imkit.av1obu import parse_av1
from imkit.av1tile import parse_tiles


def item(name: String, data: List[UInt8], off: Int, length: Int) raises:
    var payload = List[UInt8]()
    for i in range(length):
        payload.append(data[off + i])
    var st = parse_av1(Span(payload))
    var stats = parse_tiles(st)
    if len(stats) != len(st.tile_sizes):
        raise Error("av1tile: " + String(len(stats)) + " tile results for " + String(len(st.tile_sizes)) + " tiles")
    for i in range(len(stats)):
        ref s = stats[i]
        if s.mi_covered != s.mi_total:
            raise Error("av1tile: tile " + String(i) + " blocks cover " + String(s.mi_covered) + " of " + String(s.mi_total) + " 4x4 units")
        print(name, "tile", i, "ok blocks", s.blocks, "tx", s.tx_blocks, "nonzero", s.nonzero, "skip", s.skip, "intrabc", s.intrabc,
              "palette", s.palette, "cfl", s.cfl, "filter_intra", s.filter_intra, "golomb", s.golomb, "vartx_split", s.vartx_split,
              "wiener", s.wiener, "sgrproj", s.sgrproj, "segmented", s.segmented)


def main() raises:
    var path = argv()[1]
    var data: List[UInt8]
    with open(path, "r") as f:
        data = f.read_bytes()
    if path.endswith(".obu"):
        item("primary", data, 0, len(data))
        return
    var info = avif_info(Span(data))
    item("primary", data, info.primary_off, info.primary_len)
    if info.alpha_len > 0:
        item("alpha", data, info.alpha_off, info.alpha_len)
