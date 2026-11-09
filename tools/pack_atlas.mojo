"""Pack PNGs into an asset atlas: PREFIX.bin + PREFIX.txt (the format is in src/imkit/assets.mojo).
usage: mojo run -I src tools/pack_atlas.mojo PREFIX a.png b.png ...   (names are the file stems; icons from Blender, textures from ComfyUI go in assets/src/)"""
from std.sys import argv
from imkit.assets import pack


def main() raises:
    var a = argv()
    if len(a) < 3:
        raise Error("FAIL usage: pack_atlas PREFIX a.png [b.png ...]")
    var paths = List[String]()
    for i in range(2, len(a)):
        paths.append(String(a[i]))
    pack(paths, String(a[1]))
    print("packed", len(paths), "pictures ->", String(a[1]) + ".bin", String(a[1]) + ".txt")
