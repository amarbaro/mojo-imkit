"""Decoded AV1 picture planes shared by reconstruction, filters and output (stages 5 to 7)."""


struct Plane(Copyable, Movable):
    """One plane of samples (8 to 12 bits in UInt16), `w x h` samples, row r starts at r * stride."""

    var w: Int
    var h: Int
    var stride: Int
    var px: List[UInt16]

    def __init__(out self, w: Int, h: Int):
        self.w = w
        self.h = h
        self.stride = w
        self.px = List[UInt16](length=w * h, fill=0)

    def get(self, x: Int, y: Int) -> Int:
        return Int(self.px[y * self.stride + x])

    def set(mut self, x: Int, y: Int, v: Int):
        self.px[y * self.stride + x] = UInt16(v)


struct Frame(Copyable, Movable):
    """CurrFrame of the spec: planes[0] = Y, planes[1] = U, planes[2] = V (monochrome: Y only)."""

    var planes: List[Plane]
    var bit_depth: Int
    var sub_x: Int
    var sub_y: Int

    def __init__(out self, w: Int, h: Int, bit_depth: Int, sub_x: Int, sub_y: Int, num_planes: Int):
        self.planes = List[Plane]()
        self.planes.append(Plane(w, h))
        for _ in range(1, num_planes):
            self.planes.append(Plane((w + sub_x) >> sub_x, (h + sub_y) >> sub_y))
        self.bit_depth = bit_depth
        self.sub_x = sub_x
        self.sub_y = sub_y
