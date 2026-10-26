"""imkit: an immediate-mode GUI for Mojo apps, composed on the GPU (docs/DESIGN.md).

    window   SDL3 window, input, present (system libSDL3 through FFI)
    font     glyph atlas from a TrueType font (system libfreetype through FFI)
    ui       widgets -> one draw list -> the compose kernel -> an RGBA layer over the app's frame
"""
