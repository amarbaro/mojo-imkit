"""Print the HEIF container facts of an AVIF file, one per line.

Usage: avif_info FILE
"""

from std.sys import argv
from imkit.avif import avif_info


def read_all(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def main() raises:
    var args = argv()
    if len(args) < 2:
        print("usage: avif_info FILE")
        return
    var data = read_all(args[1])
    var info = avif_info(Span(data))

    print("resolution " + String(info.width) + "x" + String(info.height))
    print("depth " + String(info.depth))

    var fmt = "YUV444"
    if info.chroma == 420:
        fmt = "YUV420"
    elif info.chroma == 422:
        fmt = "YUV422"
    elif info.chroma == 400:
        fmt = "YUV400"
    print("format " + fmt)

    var alpha = "no"
    if info.has_alpha:
        alpha = "yes"
    print("alpha " + alpha)

    var rng = "limited"
    if info.full_range:
        rng = "full"
    print("range " + rng)

    print("primaries " + String(info.primaries))
    print("transfer " + String(info.transfer))
    print("matrix " + String(info.matrix))

    comptime HEX = "0123456789ABCDEF"
    var b = info.obu0
    print("obu0 0x" + String(HEX[byte=(b >> 4) & 15]) + String(HEX[byte=b & 15]))
