#!/usr/bin/env python3
"""Oracle for src/imkit/assets.mojo: writes tests/fixtures/{rgba,rgb,pil}.png and their raw RGBA bytes (.raw, what
png_decode must return). rgba.png and rgb.png are written by hand with the PNG row filters 0 to 4 cycling per row, so every
unfilter branch runs; pil.png comes from Pillow's own encoder (adaptive filters) when Pillow is installed."""
import struct, sys, zlib
from pathlib import Path

W, H = 24, 20
out = Path(__file__).resolve().parent.parent / "tests" / "fixtures"
out.mkdir(parents=True, exist_ok=True)


def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else (b if pb <= pc else c)


def png(rows, bpp, ctype):
    raw = bytearray()
    prev = bytes(W * bpp)
    for r, row in enumerate(rows):
        f = r % 5
        raw.append(f)
        for i, x in enumerate(row):
            a = row[i - bpp] if i >= bpp else 0
            b, c = prev[i], (prev[i - bpp] if i >= bpp else 0)
            pred = (0, a, b, (a + b) // 2, paeth(a, b, c))[f]
            raw.append((x - pred) & 255)
        prev = row
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, ctype, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(bytes(raw))) + chunk(b"IEND", b"")


def px(x, y):
    return ((x * 11 + y * 3) % 256, (x * 5 + y * 17 + 40) % 256, (255 - x * 9) % 256, (x * y * 7) % 256)


rgba = [bytes(v for x in range(W) for v in px(x, y)) for y in range(H)]
rgb = [bytes(v for x in range(W) for v in px(x, y)[:3]) for y in range(H)]
(out / "rgba.png").write_bytes(png(rgba, 4, 6))
(out / "rgba.raw").write_bytes(b"".join(rgba))
(out / "rgb.png").write_bytes(png(rgb, 3, 2))
(out / "rgb.raw").write_bytes(b"".join(bytes(v for x in range(W) for v in px(x, y)[:3] + (255,)) for y in range(H)))
try:
    from PIL import Image
    im = Image.new("RGBA", (W, H))
    im.putdata([px(x, y) for y in range(H) for x in range(W)])
    im.save(out / "pil.png")
    (out / "pil.raw").write_bytes(b"".join(rgba))
except ImportError:
    print("Pillow missing: pil.png not written", file=sys.stderr)
print("wrote", sorted(p.name for p in out.iterdir()))
