"""Glyph atlas for ui.mojo from a TrueType font, through FreeType (the system libfreetype, OwnedDLHandle): ASCII 32-126
at a few pixel sizes, shelf-packed once at start into one alpha8 atlas AW wide; seven int16 of metrics per glyph.
Struct offsets: FreeType 2.14 (offsetof on its headers).

    var font = Font("/usr/share/fonts/TTF/Roboto-Medium.ttf", [13, 16, 22])
    font.width("Pause", 0)        # pixels at size 0
"""
from std.ffi import OwnedDLHandle

comptime AW = 512  # atlas width, pixels
comptime FIRST = 32  # ASCII 32..126
comptime NCH = 95
comptime GM = 7  # metrics per glyph: atlas x, atlas y, w, h, left bearing, top bearing, advance


@always_inline
def peek[T: AnyType](addr: Int) -> Pointer[T, MutAnyOrigin]:
    return Pointer[T, MutAnyOrigin](unsafe_from_address=addr)


struct Font(Movable):
    var atlas: List[UInt8]  # AW x height, alpha
    var height: Int
    var sizes: List[Int]
    var ascent: List[Int]
    var g: List[Int16]  # [size][char][GM]

    def __init__(out self, path: String, var sizes: List[Int]) raises:
        var ft = OwnedDLHandle("libfreetype.so.6")
        var lib = 0
        var face = 0
        var p = path.copy()
        if ft.get_function[Int32]("FT_Init_FreeType")(Pointer(to=lib)) != 0 or \
           ft.get_function[Int32]("FT_New_Face")(lib, p.as_c_string_span().unsafe_ptr(), Int(0), Pointer(to=face)) != 0:
            raise Error("FreeType could not open " + path)
        self.atlas = List[UInt8]()
        self.height = 0
        self.ascent = List[Int]()
        self.g = List[Int16]()
        self.sizes = sizes^
        var x, y, row = 1, 1, 0  # shelf packing, 1 px gutter
        for px in self.sizes:
            _ = ft.get_function[Int32]("FT_Set_Pixel_Sizes")(face, UInt32(0), UInt32(px))
            var size = peek[Int](face + 160)[]
            self.ascent.append(Int(peek[Int64](size + 48)[] >> 6))
            for c in range(FIRST, FIRST + NCH):
                _ = ft.get_function[Int32]("FT_Load_Char")(face, UInt(c), Int32(4))  # FT_LOAD_RENDER
                var slot = peek[Int](face + 152)[]
                var h = Int(peek[UInt32](slot + 152)[])
                var w = Int(peek[UInt32](slot + 156)[])
                var pitch = Int(peek[Int32](slot + 160)[])
                var buf = peek[Int](slot + 168)[]
                if x + w + 1 > AW:
                    x, y, row = 1, y + row + 1, 0
                if y + h + 1 > self.height:
                    self.height = y + h + 1
                    self.atlas.resize(AW * self.height, 0)
                for r in range(h):
                    for k in range(w):
                        self.atlas[(y + r) * AW + x + k] = peek[UInt8](buf + r * pitch + k)[]
                var m: List[Int] = [x, y, w, h, Int(peek[Int32](slot + 192)[]), Int(peek[Int32](slot + 196)[]), Int(peek[Int64](slot + 128)[] >> 6)]
                for v in m:
                    self.g.append(Int16(v))
                x += w + 1
                row = max(row, h)
        _ = ft.get_function[Int32]("FT_Done_Face")(face)
        _ = ft.get_function[Int32]("FT_Done_FreeType")(lib)

    def glyph(self, s: Int, c: Int) -> Int:
        """Index of character c's metrics at size slot s (non-ASCII draws as '?')."""
        return ((s * NCH) + (c - FIRST if FIRST <= c < FIRST + NCH else ord("?") - FIRST)) * GM

    def width(self, text: StringSlice, s: Int) -> Int:
        var w = 0
        for b in text.as_bytes():
            w += Int(self.g[self.glyph(s, Int(b)) + 6])
        return w
