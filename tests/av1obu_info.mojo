"""Print the AV1 sequence / frame header facts of an AVIF file.

Usage: av1obu_info FILE
"""

from std.sys import argv
from imkit.avif import avif_info
from imkit.av1obu import parse_av1


def main() raises:
    var args = argv()
    if len(args) < 2:
        print("usage: av1obu_info FILE")
        return
    var f = open(args[1], "r")
    var data = f.read_bytes()
    f.close()
    var payload = List[UInt8]()
    if args[1].endswith(".obu"):  # raw OBUs (aomenc via ffmpeg -f obu)
        payload = data^
    else:
        var info = avif_info(Span(data))
        if info.primary_len <= 0:
            raise Error("av1obu: empty primary item")
        for i in range(info.primary_len):
            payload.append(data[info.primary_off + i])
    var st = parse_av1(Span(payload))

    print("seq profile " + String(st.seq.profile))
    print("seq depth " + String(st.seq.bit_depth))

    var mono = "no"
    if st.seq.mono_chrome:
        mono = "yes"
    print("seq mono " + mono)

    var sx = 0
    if st.seq.subsampling_x:
        sx = 1
    var sy = 0
    if st.seq.subsampling_y:
        sy = 1
    print("seq subsampling " + String(sx) + " " + String(sy))

    var ftype = "KEY"
    if st.frame.frame_type == 2:
        ftype = "INTRA_ONLY"
    print("frame type " + ftype)

    print("frame size " + String(st.frame.upscaled_width) + "x" + String(st.frame.height))
    print("tiles " + String(st.frame.tile_info.cols) + "x" + String(st.frame.tile_info.rows))
    print("base_q_idx " + String(st.frame.base_q_idx))

    var fr = st.frame.copy()
    print("screen " + String(Int(fr.allow_screen_content_tools)) + " intrabc " + String(Int(fr.allow_intrabc)))
    print("q deltas " + String(fr.delta_q_y_dc) + " " + String(fr.delta_q_u_dc) + " " + String(fr.delta_q_u_ac) + " " + String(fr.delta_q_v_dc) + " " + String(fr.delta_q_v_ac))
    var qm = "qm off"
    if fr.using_qmatrix:
        qm = "qm " + String(fr.qm_y) + " " + String(fr.qm_u)
    print(qm)
    print("seg " + String(Int(fr.segmentation_enabled)) + " delta_q " + String(Int(fr.delta_q_present)) + " " + String(fr.delta_q_res) + " delta_lf " + String(Int(fr.delta_lf_present)))
    print("lf " + String(fr.loop_filter_level0) + " " + String(fr.loop_filter_level1) + " sharp " + String(fr.loop_filter_sharpness))
    print("cdef " + String(fr.cdef_damping) + " " + String(fr.cdef_bits))
    print("tx select " + String(Int(fr.tx_mode_select)) + " reduced " + String(Int(fr.reduced_tx_set)))

    var line = "tile_bytes "
    for i in range(len(st.tile_sizes)):
        if i > 0:
            line += ","
        line += String(st.tile_sizes[i])
    print(line)
