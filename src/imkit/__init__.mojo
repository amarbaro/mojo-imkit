"""imkit: an immediate-mode GUI for Mojo apps, composed on the GPU (docs/design.md).

    window   SDL3 window, input, present (system libSDL3 through FFI)
    font     glyph atlas from a TrueType font (system libfreetype through FFI)
    draw     the draw list, tile binning and the compose kernel -> an RGBA layer over the app's frame
    theme    colors by role: glass, neon, flat
    ui       widgets that append to the draw list
"""
