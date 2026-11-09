"""Colors by role. Three presets share the roles: glass (dark translucent, indigo accent), neon (near black, cyan and
magenta, outlined, glowing), flat (opaque light, outlined, square-ish). rgba packs r | g << 8 | b << 16 | a << 24; the glass values are the module constants the
widgets use.
"""
from .draw import rgba


@fieldwise_init
struct Theme(Copyable, Movable):
    var panel: UInt32
    var surface: UInt32
    var hover: UInt32
    var accent: UInt32
    var good: UInt32
    var warn: UInt32
    var bad: UInt32
    var text: UInt32
    var on_accent: UInt32  # text on an accent fill (a pressed toggle, a selected row)
    var muted: UInt32
    var shadow: UInt32
    var border_c: UInt32  # outline color of panels and fields (used when border > 0)
    var radius: Float32  # panel corner radius, logical units
    var round: Float32  # control roundness: 1 pill, 0 square (corner radius = height / 2 * round)
    var border: Float32  # outline width, logical units (0: none)
    var blur: Float32  # panel shadow softness


def glass() -> Theme:
    return Theme(rgba(17, 19, 26, 214), rgba(36, 40, 52, 255), rgba(52, 57, 74, 255), rgba(95, 98, 240, 255),
                 rgba(52, 211, 153, 255), rgba(251, 191, 36, 255), rgba(248, 113, 113, 255), rgba(229, 231, 235, 255), rgba(255, 255, 255, 255),
                 rgba(148, 155, 172, 255), rgba(0, 0, 0, 120), rgba(255, 255, 255, 30), 12, 1, 0, 14)


def neon() -> Theme:
    return Theme(rgba(6, 4, 14, 224), rgba(20, 14, 38, 255), rgba(36, 24, 66, 255), rgba(0, 240, 255, 255),
                 rgba(57, 255, 136, 255), rgba(255, 214, 10, 255), rgba(255, 45, 120, 255), rgba(235, 240, 255, 255), rgba(6, 4, 14, 255),
                 rgba(150, 130, 200, 255), rgba(0, 240, 255, 90), rgba(0, 240, 255, 200), 8, 0.5, 1, 24)


def flat() -> Theme:
    return Theme(rgba(246, 247, 249, 255), rgba(226, 229, 234, 255), rgba(208, 213, 222, 255), rgba(37, 99, 235, 255),
                 rgba(21, 128, 61, 255), rgba(180, 83, 9, 255), rgba(220, 38, 38, 255), rgba(17, 24, 39, 255), rgba(255, 255, 255, 255),
                 rgba(100, 108, 122, 255), rgba(0, 0, 0, 40), rgba(176, 184, 198, 255), 4, 0.25, 1, 5)


comptime PANEL = glass().panel
comptime SURFACE = glass().surface
comptime HOVER = glass().hover
comptime ACCENT = glass().accent
comptime GOOD = glass().good
comptime WARN = glass().warn
comptime BAD = glass().bad
comptime TEXT = glass().text
comptime MUTED = glass().muted
comptime SHADOW = glass().shadow
