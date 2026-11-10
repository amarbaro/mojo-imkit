"""Print the image sequence facts of an AVIF file, in the shape of `avifdec --info`'s sequence lines.

Usage: avif_seq_info FILE"""
from std.sys import argv
from imkit.avifseq import avis_info


def main() raises:
    var data: List[UInt8]
    with open(argv()[1], "r") as f:
        data = f.read_bytes()
    var s = avis_info(Span(data))
    print("repeat", "infinite" if s.repeat_count < 0 else String(s.repeat_count))
    print("timescale", s.timescale, "duration", s.duration, "frames", len(s.pts))
    for i in range(len(s.pts)):
        print("frame", i, "pts", s.pts[i], "duration", s.durations[i], String(s.width) + "x" + String(s.height),
              "obu0", String(Int(data[s.sample_off[i]])))
