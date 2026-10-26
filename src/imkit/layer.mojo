"""GPU side of a Ui (docs/DESIGN.md, Layer): device buffers, the compose launch and the pinned RGBA the window presents,
all allocated once on the app's own DeviceContext. render(ui) after ui.finish() uploads only what the frame used
(n commands, its tile entries, the tile offsets), composes, and copies the layer to `pixels`.

    var layer = Layer(ctx, ui)                 # once: buffers, the font atlas from ui
    layer.render(ui)                           # every frame, after ui.finish()
    win.present(frame, Int(layer.pixels.unsafe_ptr()))
"""
from max.gpu.host import DeviceBuffer, DeviceContext, HostBuffer
from layout import TileTensor, row_major
from .font import AW
from .ui import AH, CW, ISRC, NBIN, NCMD, TX, TY, UH, UW, Ui, compose


struct Layer(Movable):
    var ctx: DeviceContext
    var img: DeviceBuffer[DType.uint32]
    var cmd: DeviceBuffer[DType.uint32]
    var bins: DeviceBuffer[DType.uint16]
    var off: DeviceBuffer[DType.uint32]
    var atlas: DeviceBuffer[DType.uint8]
    var src: DeviceBuffer[DType.uint32]  # image sources (Ui.image): the app writes its RGBA here
    var pixels: HostBuffer[DType.uint32]  # the composed layer, valid after render() returns

    def __init__(out self, ctx: DeviceContext, ui: Ui) raises:
        comptime assert UW > 0 and UH > 0 and UW % 16 == 0 and UH % 16 == 0, "UI_W, UI_H: positive multiples of 16"
        if len(ui.font.atlas) > AW * AH:
            raise Error("Layer: font atlas " + String(len(ui.font.atlas)) + " B over the compose capacity " + String(AW * AH))
        self.ctx = ctx
        self.img = ctx.enqueue_create_buffer[DType.uint32](UW * UH)
        self.cmd = ctx.enqueue_create_buffer[DType.uint32](NCMD * CW)
        self.bins = ctx.enqueue_create_buffer[DType.uint16](NBIN)
        self.off = ctx.enqueue_create_buffer[DType.uint32](TX * TY + 1)
        self.atlas = ctx.enqueue_create_buffer[DType.uint8](AW * AH)
        self.src = ctx.enqueue_create_buffer[DType.uint32](ISRC)
        self.pixels = ctx.enqueue_create_host_buffer[DType.uint32](UW * UH)
        self.src.enqueue_fill(0)
        ctx.enqueue_copy(self.atlas.create_sub_buffer[DType.uint8](0, len(ui.font.atlas)), ui.font.atlas.unsafe_ptr())
        ctx.synchronize()  # the atlas is the caller's

    def launch(self) raises:
        """Compose what was last uploaded (enqueue only; render() does the whole frame)."""
        self.ctx.enqueue_function(self.ctx.compile_function[compose](), TileTensor(self.img, row_major[UW * UH]()),
            TileTensor(self.cmd, row_major[NCMD * CW]()), TileTensor(self.bins, row_major[NBIN]()),
            TileTensor(self.off, row_major[TX * TY + 1]()), TileTensor(self.atlas, row_major[AW * AH]()),
            TileTensor(self.src, row_major[ISRC]()), grid_dim=(UW * UH + 255) // 256, block_dim=256)

    def render(mut self, ui: Ui) raises:
        """Upload the finished frame, compose, copy to pixels; returns when pixels is ready."""
        if ui.binned != ui.n:
            raise Error("Layer.render: call Ui.finish() first")
        if ui.n:
            self.ctx.enqueue_copy(self.cmd.create_sub_buffer[DType.uint32](0, ui.n * CW), ui.cmd.unsafe_ptr())
        var used = Int(ui.off[TX * TY])
        if used:
            self.ctx.enqueue_copy(self.bins.create_sub_buffer[DType.uint16](0, used), ui.bins.unsafe_ptr())
        self.ctx.enqueue_copy(self.off, ui.off.unsafe_ptr())
        self.launch()
        self.ctx.enqueue_copy(self.pixels, self.img)
        self.ctx.synchronize()  # ui's lists are read by the copies above
