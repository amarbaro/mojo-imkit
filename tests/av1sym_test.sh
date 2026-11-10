#!/usr/bin/env bash
# Stage 3 gate (AV1 symbol decoder): tests/av1sym_test.mojo round-trips random streams through libaom's encoder
# (tests/av1sym_enc.mojo) and src/imkit/av1sym.mojo. Then each mutant of the decoder must make the round trip FAIL,
# which proves the gate sees that class of bug. MUTANTS=0 skips the mutants.
set -euo pipefail
cd "$(dirname "$0")/.."
M=${MOJO:-.venv/bin/mojo}; W=.work/av1sym
mkdir -p $W
build() { timeout 300 "$M" build -I "$1" -I tests tests/av1sym_test.mojo -o "$2" 2> "$2.log" || { grep -A6 -m3 error "$2.log" | cut -c1-240; echo "FAIL build: $2"; exit 1; }; }
build src $W/test
timeout 60 $W/test || { echo "FAIL av1sym: round trip"; exit 1; }
[ "${MUTANTS:-1}" = 0 ] && exit 0
# each line: description | sed expression applied to av1sym.mojo
mutants=(
  "EC_MIN_PROB 4 -> 3|s/^comptime EC_MIN_PROB = 4/comptime EC_MIN_PROB = 3/"
  "adaptation rate +1|s/min(floor_log2(n), 2)/min(floor_log2(n), 2) + 1/"
  "adaptation target i < symbol -> i <= symbol|s/if i < symbol:/if i <= symbol:/"
  "counter cap 32 -> 31|s/^comptime CDF_COUNT_MAX = 32/comptime CDF_COUNT_MAX = 31/"
  "renormalize xor without +1|s/((self.symbol_value + 1) << bits) - 1/(self.symbol_value << bits) - 1/"
  "init value not inverted|s/self.symbol_value = ((1 << 15) - 1) ^ padded/self.symbol_value = padded/"
  "symbol EC_MIN_PROB term n - symbol|s/EC_MIN_PROB \* (n - symbol - 1)/EC_MIN_PROB * (n - symbol)/"
  "bool cur without EC_MIN_PROB|s/^        cur += EC_MIN_PROB$/        cur += 0/"
  "literal reads n - 1 bits|/def read_literal/,/return x/ s/range(n)/range(n - 1)/"
  "exit trailing position off by one|s/var trailing = self.bit_pos - min(15/var trailing = self.bit_pos + 1 - min(15/"
)
fails=0
for m in "${mutants[@]}"; do
  d=${m%%|*}; e=${m#*|}
  rm -rf $W/mut; cp -r src $W/mut
  sed -i "$e" $W/mut/imkit/av1sym.mojo
  if cmp -s src/imkit/av1sym.mojo $W/mut/imkit/av1sym.mojo; then echo "FAIL mutant did not apply: $d"; fails=$((fails + 1)); continue; fi
  build $W/mut $W/mtest
  if AV1SYM_STREAMS=${MUT_STREAMS:-500} timeout 60 $W/mtest > $W/mtest.out 2>&1; then echo "FAIL mutant survived: $d"; fails=$((fails + 1)); else echo "killed  $d ($(grep -m1 '^FAIL stream' $W/mtest.out | cut -c1-90))"; fi
done
[ $fails = 0 ] && echo "PASS av1sym mutants ${#mutants[@]}/${#mutants[@]}" || { echo "FAIL av1sym mutants: $fails"; exit 1; }
