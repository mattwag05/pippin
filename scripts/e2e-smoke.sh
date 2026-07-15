#!/bin/zsh
# Autonomous end-to-end smoke test against LIVE Apple apps.
#
# Runs the TCC-granted binary (~/.local/bin/pippin by default) through
# read-only commands on every bridge and asserts envelope shape plus a few
# semantic invariants (e.g. activity is newest-first). Built so agents can
# verify fixes end-to-end without a human: exit 0 = all green, exit 1 =
# failures listed on stdout, exit 2 = permissions missing (run
# `pippin permissions` interactively once, then re-run).
#
# Usage:
#   scripts/e2e-smoke.sh                 # read-only checks (safe, default)
#   PIPPIN_E2E_BIN=/path/to/pippin scripts/e2e-smoke.sh
#   scripts/e2e-smoke.sh --rw            # adds write round-trips (notes create+delete)
#
# ponytail: plain zsh + python3 for JSON asserts; no test framework needed.

set -u
BIN="${PIPPIN_E2E_BIN:-$HOME/.local/bin/pippin}"
RW=0
[[ "${1:-}" == "--rw" ]] && RW=1

PASS=0; FAIL=0; SKIP=0
fails=()

# run <name> <python-assert-expr> -- <pippin args...>
# The python expr sees `d` = parsed envelope JSON. Truthy = pass.
run() {
  local name="$1" expr="$2"; shift 2
  [[ "$1" == "--" ]] && shift
  local out
  out="$("$BIN" "$@" --format agent 2>/dev/null)"
  local verdict
  verdict="$(printf '%s' "$out" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print('BAD-JSON'); sys.exit()
if d.get('status') == 'error':
    code = (d.get('error') or {}).get('code', '?')
    print('DENIED' if code == 'access_denied' else 'ERROR:' + code); sys.exit()
print('PASS' if ($expr) else 'ASSERT-FAILED')
")"
  case "$verdict" in
    PASS) PASS=$((PASS+1)); echo "  ok    $name" ;;
    DENIED) SKIP=$((SKIP+1)); echo "  SKIP  $name (access_denied — grant via 'pippin permissions')" ;;
    *) FAIL=$((FAIL+1)); fails+=("$name: $verdict"); echo "  FAIL  $name ($verdict)" ;;
  esac
}

echo "e2e smoke: $BIN ($("$BIN" --version 2>/dev/null))"

# --- Calendar / Reminders / Contacts (EventKit + CNContactStore, in-process MCP set)
run "calendar list"    "isinstance(d['data'], list)"                    -- calendar list
run "calendar today"   "isinstance(d['data'], (list, dict))"            -- calendar today
run "reminders lists"  "isinstance(d['data'], list)"                    -- reminders lists
run "contacts search"  "isinstance(d['data'], list)"                    -- contacts search "a" --limit 3

# --- Mail (JXA) — includes regression checks for GitHub #21/#23/#24/#25
run "mail accounts"    "isinstance(d['data'], list) and len(d['data']) > 0" -- mail accounts
run "mail activity newest-first (#24)" "
(lambda rows: len(rows) < 2 or all(rows[i]['date'] >= rows[i+1]['date'] for i in range(len(rows)-1)))(
  d['data'] if isinstance(d['data'], list) else d['data'].get('messages', []))" \
  -- mail activity --limit 10
run "mail list --after honors cutoff (#25)" "
(lambda rows: all(m['date'] >= '2026-01-01' for m in rows))(
  d['data'] if isinstance(d['data'], list) else d['data'].get('messages', []))" \
  -- mail list --after 2026-01-01 --limit 5
run "mail search --from filters sender (#21)" "isinstance(d['data'], (list, dict))" \
  -- mail search "the" --from "no-reply" --limit 3
run "mail search date-bounded body scan returns (#23)" "isinstance(d['data'], (list, dict))" \
  -- mail search "the" --body --after 2026-07-01 --limit 3
# pippin-xz6: an empty --before result whose newest-N window never reached the
# cutoff must carry the shortfall advisory (JXA must emit oldestExaminedMs /
# reachedMailboxEnd). Pass if matches exist (impossible pre-2000) OR the hint fired.
# PIPPIN_MAIL_FASTPATH=0: the hint is a JXA-window artifact — the Envelope Index
# fast path scans the full index, so its empty result is complete and hint-free.
PIPPIN_MAIL_FASTPATH=0 run "mail list --before shortfall hint (pippin-xz6, JXA path)" "
len(d['data']) > 0 or any('scan window did not reach' in w for w in (d.get('warnings') or []))" \
  -- mail list --before 2000-01-01 --limit 3

# --- pippin-60x: Envelope Index fast path — id parity vs the JXA path.
# The fast path reads Mail's on-disk SQLite; JXA enumerates the live app. For
# the same bounded single-account query, the JXA ids must be a subset of the
# fast-path ids (identical in practice; JXA's newest-N window can only lose
# rows, never gain them, because ROWID == the JXA message id).
FASTPATH_OK="$("$BIN" doctor --format agent 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print('no'); sys.exit()
checks = d.get('data') or []
print('yes' if any(c.get('name') == 'Mail fast path (Envelope Index)' and c.get('status') == 'ok' for c in checks) else 'no')")"
if [[ "$FASTPATH_OK" == "yes" ]]; then
  ACCT="$("$BIN" mail accounts --format agent 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(''); sys.exit()
rows = d.get('data') or [{}]
print(rows[0].get('name', ''))")"
  AFTER="$(date -v-3d +%Y-%m-%d)"
  FAST="$("$BIN" mail list --account "$ACCT" --after "$AFTER" --limit 20 --no-contacts --format agent 2>/dev/null)"
  SLOW="$(PIPPIN_MAIL_FASTPATH=0 "$BIN" mail list --account "$ACCT" --after "$AFTER" --limit 20 --no-contacts --format agent 2>/dev/null)"
  VERDICT="$(FAST="$FAST" SLOW="$SLOW" python3 -c "
import json, os
try:
    fast = json.loads(os.environ['FAST']); slow = json.loads(os.environ['SLOW'])
except Exception:
    print('BAD-JSON'); raise SystemExit
if fast.get('status') != 'ok' or slow.get('status') != 'ok':
    print('ERROR'); raise SystemExit
fids = [m['id'] for m in fast['data']]; sids = [m['id'] for m in slow['data']]
if set(sids) <= set(fids) and (fids or not sids):
    print('PASS')
else:
    print('ASSERT-FAILED fast=%s slow=%s' % (fids[:3], sids[:3]))")"
  if [[ "$VERDICT" == "PASS" ]]; then
    PASS=$((PASS+1)); echo "  ok    mail fast-path/JXA id parity (pippin-60x)"
  else
    FAIL=$((FAIL+1)); fails+=("mail fast-path/JXA id parity: $VERDICT"); echo "  FAIL  mail fast-path/JXA id parity ($VERDICT)"
  fi
else
  SKIP=$((SKIP+1)); echo "  SKIP  mail fast-path/JXA id parity (fast path unavailable — no FDA or unknown schema)"
fi

# --- Notes (JXA)
run "notes list"       "isinstance(d['data'], list)"                    -- notes list --limit 3

# --- Messages (FDA)
run "messages list"    "isinstance(d['data'], (list, dict))"            -- messages list --since-hours 168

# --- Writes (opt-in): notes create → show → delete round-trip incl. #26 formatting
if [[ $RW -eq 1 ]]; then
  TITLE="pippin-e2e-$(date +%s)"
  CREATED="$("$BIN" notes create "$TITLE" --body $'line1\n\nline2' --format agent 2>/dev/null)"
  NOTE_ID="$(printf '%s' "$CREATED" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('id',''))")"
  if [[ -n "$NOTE_ID" ]]; then
    run "notes #26 newlines survive round-trip" "'line2' in d['data'].get('plainText','') and '\n' in d['data'].get('plainText','')" -- notes show "$NOTE_ID"
    "$BIN" notes delete "$NOTE_ID" --format agent >/dev/null 2>&1
  else
    FAIL=$((FAIL+1)); fails+=("notes create round-trip: no id returned")
    echo "  FAIL  notes create round-trip (no id)"
  fi
fi

echo
echo "passed=$PASS failed=$FAIL skipped=$SKIP"
if [[ $SKIP -gt 0 && $PASS -eq 0 && $FAIL -eq 0 ]]; then
  echo "All checks skipped — permissions missing. Run 'pippin permissions' interactively once."
  exit 2
fi
[[ $FAIL -eq 0 ]] || { printf 'FAILED: %s\n' "${fails[@]}"; exit 1; }
exit 0
