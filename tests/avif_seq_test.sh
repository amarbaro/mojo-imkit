#!/usr/bin/env bash
# Stage 8 gate (AVIF image sequences): tests/avif_seq_info.mojo must print what `avifdec --info` reports for every animation fixture:
# repeat count, timescale, total duration in timescales, frame count, and per frame pts / duration (timescales) and size. Each sample's
# first OBU must be a temporal delimiter (0x12 = 18), which proves the stsz / stsc / stco walk lands on the AV1 data.
# Frames after the first are inter frames and are NOT decoded (out of scope: the decoder is intra only).
set -euo pipefail
cd "$(dirname "$0")/.."
F=.work/avif; M=${MOJO:-.venv/bin/mojo}; W=.work/avifseq; mkdir -p $W
timeout 300 "$M" build -I src tests/avif_seq_info.mojo -o $W/info 2> $W/build.log || { grep -A6 -m3 error $W/build.log | cut -c1-240; echo "FAIL build: avif_seq_info"; exit 1; }
for r in 0 2; do
  [ -f $F/anim_r$r.avif ] || timeout 60 avifenc -y 420 -q 50 -s 6 --timescale 30 --duration 4 --repetition-count $r $F/src-320.png --duration 7 $F/src-b.png -o $F/anim_r$r.avif > /dev/null
done
exp() { avifdec --info "$1" 2>/dev/null | awk '
  /Repeat Count/{r = tolower($NF); print "repeat " r}
  /timescales per second/{ts = $2; match($0, /\(([0-9]+) timescales\), ([0-9]+) frames/, m); print "timescale " ts " duration " m[1] " frames " m[2]}
  /Decoded frame/{match($0, /frame \[([0-9]+)\] \[pts [0-9.]+ \(([0-9]+) timescales\)\] \[duration [0-9.]+ \(([0-9]+) timescales\)\] \[([0-9x]+)\]/, m); print "frame " m[1] " pts " m[2] " duration " m[3] " " m[4] " obu0 18"}'; }
fails=0
for f in $F/anim.avif $F/anim_r0.avif $F/anim_r2.avif; do
  e=$(exp "$f"); g=$(timeout 10 $W/info "$f" 2>&1)
  if [ "$e" = "$g" ]; then echo "ok   $f"; else echo "FAIL $f:"; diff <(echo "$e") <(echo "$g") | head -8 || true; fails=$((fails + 1)); fi
done
if timeout 10 $W/info $F/lossless.avif > /dev/null 2>&1; then echo "FAIL: a still image has no sequence and must raise"; fails=$((fails + 1)); else echo "ok   still image raised"; fi
head -c 400 $F/anim.avif > $W/trunc.avif
if timeout 10 $W/info $W/trunc.avif > /dev/null 2>&1; then echo "FAIL: truncated file accepted"; fails=$((fails + 1)); else echo "ok   truncated file raised"; fi
[ $fails = 0 ] || { echo "FAIL avif_seq: $fails"; exit 1; }
echo "PASS avif_seq"
[ "${MUTANTS:-1}" = 0 ] && exit 0
# each mutant of avifseq.mojo must break the comparison on some fixture
mutants=(
  "repeat count off by one|s/info.repeat_count = tdur \\/\\/ seg - 1/info.repeat_count = tdur \\/\\/ seg/"
  "stsc run starts at chunk ch not ch + 1|s/<= ch + 1:/<= ch:/"
  "mdhd v1 timescale offset|s/mdhd\\[0\\] + (20 if/mdhd[0] + (24 if/"
  "pts forgets the previous frame|s/                t += delta$/                t = delta/"
  "stsz entry offset|s/stsz\\[0\\] + 12 + i \\* 4/stsz[0] + 16 + i * 4/"
  "elst repeat flag inverted|s/\\& 1) == 1:$/\\& 1) == 0:/"
)
mf=0
for m in "${mutants[@]}"; do
  dsc=${m%%|*}; e=${m#*|}; md=$W/mut; rm -rf $md; mkdir -p $md; cp -r src $md/src
  sed -i "$e" $md/src/imkit/avifseq.mojo
  if cmp -s src/imkit/avifseq.mojo $md/src/imkit/avifseq.mojo; then echo "FAIL mutant did not apply: $dsc"; mf=$((mf + 1)); continue; fi
  if ! timeout 300 "$M" build -I $md/src tests/avif_seq_info.mojo -o $md/info 2> $md/build.log; then echo "killed  $dsc (build error)"; continue; fi
  surv=1
  for f in $F/anim.avif $F/anim_r0.avif $F/anim_r2.avif; do
    [ "$(exp "$f")" = "$(timeout 10 $md/info "$f" 2>&1)" ] || surv=0
  done
  if [ $surv = 1 ]; then echo "FAIL mutant survived: $dsc"; mf=$((mf + 1)); else echo "killed  $dsc"; fi
done
[ $mf = 0 ] && echo "PASS avif_seq mutants ${#mutants[@]}/${#mutants[@]}" || { echo "FAIL avif_seq mutants: $mf"; exit 1; }
