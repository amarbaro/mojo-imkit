#!/usr/bin/env bash
# Stage 2 gate (AV1 OBU headers): tests/av1obu_info.mojo prints the parsed headers; they must equal ffmpeg's trace_headers bitstream filter
# (an independent AV1 syntax parser) on every fixture: seq profile, frame size (max_frame_*_minus_1 + 1), tiles (1 << tile_cols_log2 x 1 << tile_rows_log2),
# base_q_idx, and the frame header fields the tile parser reads (screen content, q deltas, qmatrix, segmentation and delta q/lf flags,
# loop filter levels, cdef, tx mode). (A truncated-payload check is not here yet: the bit reader raises on overrun, untested by this gate.)
set -euo pipefail
cd "$(dirname "$0")/.."
F=.work/avif; M=${MOJO:-.venv/bin/mojo}
timeout 300 "$M" build -I src tests/av1obu_info.mojo -o .work/av1obu_info 2> .work/av1obu_info.log || { grep -A6 -m3 error .work/av1obu_info.log | cut -c1-240; echo "FAIL build: tests/av1obu_info.mojo"; exit 1; }
exp() { timeout 30 ffmpeg -v trace -i "$1" -c copy -bsf:v trace_headers -f null - 2>&1 | sed 's/^\[[^]]*\] //' | awk '
  $2=="seq_profile"{p=$NF} $2=="max_frame_width_minus_1"{w=$NF+1} $2=="max_frame_height_minus_1"{h=$NF+1}
  $2=="tile_cols_log2"{c=$NF} $2=="tile_rows_log2"{r=$NF} $2=="base_q_idx" && q==""{q=$NF}
  $2=="high_bitdepth"{hb=$NF} $2=="twelve_bit"{tb=$NF} $2=="mono_chrome"{mo=$NF} $2=="subsampling_x"{sx=$NF} $2=="subsampling_y"{sy=$NF}
  $2=="seq_force_screen_content_tools"{sc=$NF} $2=="allow_screen_content_tools"{sc=$NF} $2=="allow_intrabc"{ib=$NF}
  $2 ~ /^delta_q_[yuv]_(dc|ac)\.delta_q$/{split($2,a,"."); dq[a[1]]=$NF} $2=="diff_uv_delta"{duv=$NF}
  $2=="using_qmatrix"{uq=$NF} $2=="qm_y"{qy=$NF} $2=="qm_u"{qu=$NF}
  $2=="segmentation_enabled"{se=$NF} $2=="delta_q_present"{dp=$NF} $2=="delta_q_res"{dr=$NF} $2=="delta_lf_present"{dl=$NF}
  $2=="loop_filter_level[0]"{l0=$NF} $2=="loop_filter_level[1]"{l1=$NF} $2=="loop_filter_sharpness"{ls=$NF}
  $2=="cdef_damping_minus_3"{cd=$NF+3} $2=="cdef_bits"{cb=$NF} $2=="tx_mode"{tm=$NF} $2=="reduced_tx_set"{rt=$NF}
  END{print "seq profile " p; print "seq depth " (tb == 1 ? 12 : (hb == 1 ? 10 : 8)); print "seq mono " (mo == 1 ? "yes" : "no")
    if (sx == "") { if (mo == 1 || p == 0) { sx = 1; sy = 1 } else if (p == 1) { sx = 0; sy = 0 } else { sx = 1; sy = 0 } }
    print "seq subsampling " sx " " sy; print "frame size " w "x" h; print "tiles " 2^c "x" 2^r; print "base_q_idx " q
    if (sc == 2) sc = "?"; print "screen " (sc+0) " intrabc " (ib+0)
    ud = dq["delta_q_u_dc"]+0; ua = dq["delta_q_u_ac"]+0; vd = ud; va = ua; if (duv == 1) { vd = dq["delta_q_v_dc"]+0; va = dq["delta_q_v_ac"]+0 }
    print "q deltas " (dq["delta_q_y_dc"]+0) " " ud " " ua " " vd " " va
    if (uq == 1) print "qm " qy " " qu; else print "qm off"
    print "seg " (se+0) " delta_q " (dp+0) " " (dr+0) " delta_lf " (dl+0)
    print "lf " (l0+0) " " (l1+0) " sharp " (ls+0); print "cdef " (cd == "" ? 3 : cd) " " (cb+0); print "tx select " (tm == 2 ? 1 : 0) " reduced " (rt+0)}'; }
fails=0
for f in $F/*.avif $F/*.obu; do
  e=$(exp "$f"); g=$(timeout 10 .work/av1obu_info "$f" 2>&1 | grep -E '^(seq profile|seq depth|seq mono|seq subsampling|frame size|tiles|base_q_idx|screen|q deltas|qm|seg|lf|cdef|tx select) ' || true)
  if [ "$e" = "$g" ]; then echo "ok   $f"; else echo "FAIL $f:"; diff <(echo "$e") <(echo "$g") | head -10 || true; timeout 10 .work/av1obu_info "$f" 2>&1 | grep -i error | head -2 || true; fails=$((fails + 1)); fi
done
[ $fails = 0 ] && echo "PASS avif_obu" || { echo "FAIL avif_obu: $fails"; exit 1; }
