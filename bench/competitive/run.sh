#!/bin/bash
# One command for the whole head-to-head. Run INSIDE the disposable benchmark VM
# (see README.md for how to create it), from a checkout of this repository:
#
#     bench/competitive/run.sh [results-name]
#
# Installs the pinned tools, builds Pippin from this checkout (or uses PIPPIN_BIN),
# seeds and verifies the fixture, runs every stage, restores the fixture and writes
# bench/competitive/results/<results-name>/ with raw JSON and summary.md.
# Agent task runs are separate (harness/tasks.py) because they need an agent CLI.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
NAME="${1:-$(date +%Y-%m-%d)}"
OUT="$HERE/results/$NAME"
export PATH="/opt/homebrew/bin:$PATH"

if [ "$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo 0)" != "1" ]; then
  echo "run.sh: this is not a virtual machine. The benchmark runs third-party code and writes to Apple apps; refusing." >&2
  exit 2
fi

echo "== install pinned tools"
bash "$HERE/install.sh"

if [ -z "${PIPPIN_BIN:-}" ]; then
  echo "== build Pippin from this checkout"
  (cd "$REPO" && swift build -c release 2>&1 | tail -1)
  mkdir -p "$HOME/bin"
  cp "$REPO/.build/release/pippin" "$HOME/bin/pippin-head"
  export PIPPIN_BIN="$HOME/bin/pippin-head"
  export PIPPIN_LABEL="branch build $(cd "$REPO" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
fi
echo "== grant Pippin the fixture stores (VM only; competitors inherit the ssh session's grants)"
sh "$HERE/vm/grant.sh" "$PIPPIN_BIN" >/dev/null
sh "$HERE/vm/grant_ae.sh" "$PIPPIN_BIN" >/dev/null

echo "== seed and verify the fixture"
bash "$HERE/fixtures/teardown.sh" >/dev/null 2>&1 || true
bash "$HERE/fixtures/seed.sh"
python3 "$HERE/fixtures/verify.py"

echo "== warm-up pass (first-run consent dialogs), not recorded"
python3 "$HERE/harness/run.py" --out "$(mktemp -d)" --stages manifest >/dev/null 2>&1 || true
sh "$HERE/vm/allow.sh" >/dev/null 2>&1 || true

echo "== speed, reliability, coverage"
rm -rf "$OUT"
python3 "$HERE/harness/run.py" --out "$OUT"
echo "== correctness, safety, write probes"
python3 "$HERE/harness/checks.py" --out "$OUT"

echo "== restore and verify the fixture"
bash "$HERE/fixtures/teardown.sh" >/dev/null 2>&1 || true
bash "$HERE/fixtures/seed.sh" >/dev/null
python3 "$HERE/fixtures/verify.py"

python3 "$HERE/harness/report.py" "$OUT" > "$OUT/summary.md"
echo "== done: $OUT/summary.md"
