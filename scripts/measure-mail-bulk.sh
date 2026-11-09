#!/usr/bin/env bash
# Measures bulk Apple Event reads against the per-message JXA loop on real Mail accounts (pippin-25pr).
# Read-only. Records timings and alignment, never message content.
# Usage: scripts/measure-mail-bulk.sh [out.jsonl] -- "Account|Mailbox" ["Account|Mailbox" ...]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-measure-mail-bulk.jsonl}; shift || true
[ "${1:-}" = "--" ] && shift
[ $# -gt 0 ] || { echo "usage: $0 [out.jsonl] -- 'Account|Mailbox' ..." >&2; exit 64; }

# Preflight: an un-granted Apple Event blocks instead of failing, so cap it (macOS has no timeout).
perl -e 'alarm 20; exec @ARGV' osascript -l JavaScript -e "Application('Mail').accounts.length" >/dev/null \
  || { echo "Mail automation unavailable or not granted" >&2; exit 4; }

for target in "$@"; do
  acct=${target%%|*}; mb=${target#*|}
  echo "measuring $acct / $mb" >&2
  perl -e 'alarm 600; exec @ARGV' osascript -l JavaScript "$here/measure-mail-bulk.js" "$acct" "$mb" 3 200 >> "$out"
done
echo "wrote $out" >&2
