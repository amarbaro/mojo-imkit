#!/usr/bin/env bash
# One lane step's gate: local_gate (GPU via gpu-wait) plus the CPU Ui check, receipt in .work/gate-<name>.txt.
# usage: scripts/gate_step.sh B2
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p .work
out=".work/gate-$1.txt"
{ GPU_WRAP="gpu-wait run --timeout 600 --" scripts/local_gate.sh \
  && .venv/bin/mojo build -I src tests/ui_cpu_test.mojo -o .work/ui_cpu_test > .work/ui_cpu_test.build.log 2>&1 \
  && .work/ui_cpu_test; } > "$out" 2>&1
rc=$?
echo "exit $rc  tree $(git rev-parse --short HEAD)+$(git diff HEAD | sha1sum | cut -c1-8)" >> "$out"
grep -E "^(FAIL|PASS local_gate|PASS ui_cpu_test|exit)" "$out"
exit $rc
