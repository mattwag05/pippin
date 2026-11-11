#!/bin/sh
# Run one of the named quality suites by itself.
#
#   scripts/test-suite.sh fuzz    seeded fuzz tests (FuzzTests)
#   scripts/test-suite.sh chaos   process and store fault tests (ChaosTests)
#
# Both suites are also part of `make test`; this exists so CI can show them as
# their own steps and so a failure can be replayed quickly, for example:
#   PIPPIN_FUZZ_SEED=12345 scripts/test-suite.sh fuzz
set -eu
cd "$(dirname "$0")/.."
case "${1:-}" in
    fuzz) filter=FuzzTests ;;
    chaos) filter=ChaosTests ;;
    *) echo "usage: $0 fuzz|chaos" >&2; exit 2 ;;
esac
# Same SDK routing as the Makefile's test target. `swift test --filter` exits 0
# when the filter matches nothing, so a renamed suite would pass without
# running; fail on that explicitly.
out="$(mktemp)"
trap 'rm -f "$out"' EXIT
rc=0
xcrun --sdk macosx swift test --filter "PippinTests.$filter" >"$out" 2>&1 || rc=$?
cat "$out"
[ "$rc" -eq 0 ] || exit "$rc"
if grep -q "No matching test cases were run" "$out" || ! grep -Eq "Executed [1-9][0-9]* tests?" "$out"; then
    echo "error: PippinTests.$filter matched no tests" >&2
    exit 1
fi
