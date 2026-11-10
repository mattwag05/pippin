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
# Same SDK routing as the Makefile's test target.
exec xcrun --sdk macosx swift test --filter "PippinTests.$filter"
