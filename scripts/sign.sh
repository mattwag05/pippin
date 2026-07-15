#!/usr/bin/env bash
#
# Sign the pippin binary with a stable code-signing identity so macOS TCC
# permission grants persist across rebuilds and across install paths.
#
# Why this exists: SwiftPM ad-hoc / linker-signs the binary by default, so the
# code identity macOS TCC keys grants on IS the CDHash — a content hash that
# changes on every build. TCC then treats each build as a brand-new app and
# orphans the prior grant (every `make install` / `brew upgrade` re-prompts).
# A stable signature (Developer ID, identifier com.mattwag05.pippin) gives a
# content-independent Designated Requirement, so a grant given once survives
# rebuilds and is shared across both install paths. See
# docs/gotchas/permissions.md (pippin-xzu).
#
# Usage: scripts/sign.sh <path-to-binary>
#
# Env:
#   PIPPIN_SIGN_IDENTITY  Override the signing identity. Default: the first
#                         "Developer ID Application" identity, falling back to
#                         the first "Apple Development" identity in the keychain.
#                         Either gives a content-independent Designated
#                         Requirement (identifier + cert), so a TCC grant given
#                         once survives rebuilds. Developer ID additionally
#                         survives cert *renewal* (team-based DR) and is required
#                         for notarized distribution; Apple Development pins to
#                         the leaf cert, so grants persist only until that cert
#                         is renewed/expires (~1yr) — fine for a local dev loop.
#   PIPPIN_SIGN_HARDENED  Set to 1 to add `--options runtime --timestamp`
#                         (needed only when the binary will be notarized for
#                         distribution to other Macs; not needed for local TCC).
#
# Fallback behavior: if no suitable identity is found, this prints a warning and
# exits 0, leaving the ad-hoc signature in place — so building on a machine
# without the cert (CI, another contributor, the ci-vm) still succeeds.

set -euo pipefail

BIN="${1:-}"
IDENTIFIER="com.mattwag05.pippin"

if [[ -z "$BIN" || ! -f "$BIN" ]]; then
	echo "sign.sh: binary not found: '$BIN'" >&2
	exit 2
fi

# Resolve the identity: explicit override wins, else first Developer ID
# Application, else first Apple Development (the everyday Xcode dev cert — good
# enough for local TCC-grant persistence even though it isn't distributable).
identity="${PIPPIN_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
	# `|| true`: grep returns 1 on no-match and pipefail would otherwise trip
	# `set -e` before the fallback runs.
	identities="$(security find-identity -p codesigning -v 2>/dev/null)" || true
	identity="$(printf '%s\n' "$identities" | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"$/\1/')" || true
	if [[ -z "$identity" ]]; then
		identity="$(printf '%s\n' "$identities" | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"$/\1/')" || true
	fi
fi

if [[ -z "$identity" ]]; then
	echo "sign.sh: no 'Developer ID Application' or 'Apple Development' identity found — leaving the ad-hoc signature." >&2
	echo "         TCC permission grants will NOT persist across rebuilds/upgrades on this machine." >&2
	echo "         Set PIPPIN_SIGN_IDENTITY to sign with a different identity." >&2
	exit 0
fi

args=(--force --sign "$identity" --identifier "$IDENTIFIER")
if [[ "${PIPPIN_SIGN_HARDENED:-0}" == "1" ]]; then
	# Hardened runtime + secure timestamp — required for notarization only.
	args+=(--options runtime --timestamp)
fi

echo "sign.sh: signing $BIN"
echo "         identity:   $identity"
echo "         identifier: $IDENTIFIER"
codesign "${args[@]}" "$BIN"
codesign --verify --strict "$BIN"
echo "sign.sh: signed. $(codesign -dvv "$BIN" 2>&1 | grep -E 'Authority=(Developer ID Application|Apple Development)|Identifier=|TeamIdentifier=' | tr '\n' ' ')"
