#!/usr/bin/env python3
"""Test oracle: encode RGBA with the system libwebp through ctypes, to reach encoder settings ImageMagick does not expose
(token partitions, skip probability, segments, filter strength). Never part of the decoder.
usage: webp_oracle_enc.py RAW.rgba WIDTH HEIGHT OUT.webp [name=value ...]   (names are WebPConfig fields, e.g. partitions=3)"""
import ctypes as C
import sys

FIELDS = ["lossless", "quality", "method", "image_hint", "target_size", "target_PSNR", "segments", "sns_strength", "filter_strength",
          "filter_sharpness", "filter_type", "autofilter", "alpha_compression", "alpha_filtering", "alpha_quality", "pass",
          "show_compressed", "preprocessing", "partitions", "partition_limit", "emulate_jpeg_size", "thread_level", "low_memory",
          "near_lossless", "exact", "use_delta_palette", "use_sharp_yuv", "qmin", "qmax"]
FLOATS = {"quality", "target_PSNR"}


class Config(C.Structure):
    _fields_ = [(n, C.c_float if n in FLOATS else C.c_int) for n in FIELDS] + [("pad", C.c_uint32 * 8)]


WRITER = C.CFUNCTYPE(C.c_int, C.POINTER(C.c_uint8), C.c_size_t, C.c_void_p)


class Picture(C.Structure):  # only the leading fields matter, the rest is zero padding for WebPPictureInit to fill
    _fields_ = [("use_argb", C.c_int), ("colorspace", C.c_int), ("width", C.c_int), ("height", C.c_int), ("y", C.c_void_p),
                ("u", C.c_void_p), ("v", C.c_void_p), ("y_stride", C.c_int), ("uv_stride", C.c_int), ("a", C.c_void_p),
                ("a_stride", C.c_int), ("pad1", C.c_uint32 * 2), ("argb", C.c_void_p), ("argb_stride", C.c_int),
                ("pad2", C.c_uint32 * 3), ("writer", WRITER), ("custom_ptr", C.c_void_p), ("rest", C.c_uint8 * 512)]


raw, w, h, out = open(sys.argv[1], "rb").read(), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
lib = C.CDLL("libwebp.so.7")
ver = 0x020F
cfg = Config()
assert lib.WebPConfigInitInternal(C.byref(cfg), 0, C.c_float(75), ver), "WebPConfigInitInternal"
for kv in sys.argv[5:]:
    k, v = kv.split("=")
    assert k in FIELDS, k
    setattr(cfg, k, float(v) if k in FLOATS else int(v))
pic = Picture()
assert lib.WebPPictureInitInternal(C.byref(pic), ver), "WebPPictureInitInternal"
pic.width, pic.height, pic.use_argb = w, h, 1
buf = (C.c_uint8 * len(raw)).from_buffer_copy(raw)
assert lib.WebPPictureImportRGBA(C.byref(pic), buf, w * 4), "WebPPictureImportRGBA"
chunks = []


def write(data, size, picture):
    chunks.append(bytes(C.cast(data, C.POINTER(C.c_uint8 * size)).contents))
    return 1


pic.writer = WRITER(write)
assert lib.WebPValidateConfig(C.byref(cfg)), "WebPValidateConfig"
assert lib.WebPEncode(C.byref(cfg), C.byref(pic)), "WebPEncode failed"
open(out, "wb").write(b"".join(chunks))
