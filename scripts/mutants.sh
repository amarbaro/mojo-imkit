#!/usr/bin/env bash
# Mutants of the v0.7.0 additions: each breaks one rule in a copy of src and the matching test must fail. A mutant that
# survives, or a sed that changes nothing, fails this script. Needs a display for the window mutant (window_test, ~2 s).
set -euo pipefail
cd "$(dirname "$0")/.."
M=.venv/bin/mojo
export IMKIT_FONT="${IMKIT_FONT:-/usr/share/fonts/TTF/Roboto-Medium.ttf}"
mutant() {  # name file sed-expression test
  local name=$1 file=$2 expr=$3 test=$4 d=.work/mutant
  rm -rf "$d"; mkdir -p "$d"; cp -r src "$d/src"
  sed -i "$expr" "$d/src/imkit/$file"
  cmp -s "src/imkit/$file" "$d/src/imkit/$file" && { echo "FAIL $name: sed changed nothing"; exit 1; }
  if timeout 300 $M run -I "$d/src" "tests/$test.mojo" > "$d/out.txt" 2>&1; then
    echo "FAIL $name: $test still passes"; exit 1
  fi
  grep -m1 '^FAIL' "$d/out.txt" || { echo "FAIL $name: $test failed without a FAIL line, see $d/out.txt"; exit 1; }
  echo "KILLED $name"
}
mutant "field ignores max" ui.mojo 's/ and buf.byte_length() < max//' ui_cpu_test
mutant "merge drops text" window.mojo '/self.text += o.text/d' window_test
mutant "push text dies before poll" window.mojo 's/            self.keep.append(buf^)/            self.keep.clear()\n            self.keep.append(buf^)/' window_test
echo "PASS mutants"
