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

# run_err <name> <want_code> <want_exit> -- <pippin args...>
# Asserts a command FAILS with error.code==want_code, exit==want_exit, and a
# real duration_ms (> 0). Skips on access_denied so ungranted CI still passes.
run_err() {
  local name="$1" want_code="$2" want_exit="$3"; shift 3
  [[ "$1" == "--" ]] && shift
  local out rc
  out="$("$BIN" "$@" --format agent 2>/dev/null)"; rc=$?
  local verdict
  verdict="$(RC="$rc" WANT_CODE="$want_code" WANT_EXIT="$want_exit" python3 -c "
import json, os, sys
rc = int(os.environ['RC']); want_code = os.environ['WANT_CODE']; want_exit = int(os.environ['WANT_EXIT'])
try:
    d = json.load(sys.stdin)
except Exception:
    print('BAD-JSON'); sys.exit()
code = (d.get('error') or {}).get('code', '?')
if code == 'access_denied':
    print('DENIED'); sys.exit()
if d.get('status') != 'error': print('NOT-ERROR:status=%s' % d.get('status')); sys.exit()
if code != want_code: print('CODE:%s!=%s' % (code, want_code)); sys.exit()
if rc != want_exit: print('EXIT:%s!=%s' % (rc, want_exit)); sys.exit()
if not isinstance(d.get('duration_ms'), int) or d.get('duration_ms') < 0: print('DUR:%s' % d.get('duration_ms')); sys.exit()
print('PASS')
" <<<"$out")"
  case "$verdict" in
    PASS) PASS=$((PASS+1)); echo "  ok    $name" ;;
    DENIED) SKIP=$((SKIP+1)); echo "  SKIP  $name (access_denied)" ;;
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
# pippin-jum: agent list is body-less (HTML body only via `notes show`) and
# carries the v2 date-field names.
run "notes list is body-less + v2 fields (pippin-jum)" "
len(d['data']) == 0 or (
  'body' not in d['data'][0]
  and 'plainText' in d['data'][0]
  and 'modifiedAt' in d['data'][0]
  and 'modificationDate' not in d['data'][0])" \
  -- notes list --limit 3

# --- Messages (FDA) — v2 bare array + no tapback rows (pippin-4ke)
run "messages list is bare array (v2)" "isinstance(d['data'], list)"   -- messages list --since-hours 168
run "messages list drops tapbacks (pippin-4ke)" "
__import__('re').compile(r'^(Loved|Liked|Laughed at|Emphasized|Disliked|Questioned) [“\"]') is not None and
all(not __import__('re').match(r'^(Loved|Liked|Laughed at|Emphasized|Disliked|Questioned) [“\"]', (c.get('last_message_preview') or c.get('lastMessagePreview') or '')) for c in d['data'])" \
  -- messages list --since-hours 168

# --- Audit regression: typed not-found → exit 3, usage → exit 2, real duration_ms
run_err "notes show not-found → note_not_found/3"  note_not_found  3 -- notes show "x-coredata://bogus/ICNote/p999999"
run_err "mail show not-found → message_not_found/3" message_not_found 3 -- mail show "iCloud||INBOX||99999999"
run_err "calendar name miss → calendar_not_found/3" calendar_not_found 3 -- calendar events --calendar-name "ZZZNoSuchCal-e2e"
run_err "mail --account miss → account_not_found/3" account_not_found 3 -- mail list --account "ZZZNoSuchAccount-e2e" --limit 1
run_err "mail --limit 0 → usage/2"                 command_error   2 -- mail list --limit 0

# --- MCP stdio smoke (pippin-c6r): initialize → tools/list → read call → unknown-tool error
MCP_VERDICT="$(BIN="$BIN" python3 - <<'PY' 2>/dev/null
import json, os, subprocess, sys
bin = os.environ['BIN']
p = subprocess.Popen([bin, "mcp-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL, text=True, bufsize=1)
def send(obj):
    p.stdin.write(json.dumps(obj) + "\n"); p.stdin.flush()
def recv():
    line = p.stdout.readline()
    return json.loads(line) if line else None
try:
    send({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}})
    init = recv()
    send({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}})
    tl = recv()
    ntools = len(((tl or {}).get("result") or {}).get("tools") or [])
    send({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"calendar_today","arguments":{}}})
    call = recv()
    ok = not ((call or {}).get("result") or {}).get("isError", True)
    send({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}})
    unk = recv()
    err_code = ((unk or {}).get("error") or {}).get("code")
    if init and ntools >= 40 and ok and err_code == -32601:
        print("PASS")
    else:
        print("FAIL: init=%s ntools=%s call_ok=%s unk=%s" % (bool(init), ntools, ok, err_code))
finally:
    try: p.stdin.close()
    except Exception: pass
    p.terminate()
    try: p.wait(timeout=5)
    except Exception: p.kill()
PY
)"
if [[ "$MCP_VERDICT" == "PASS" ]]; then
  PASS=$((PASS+1)); echo "  ok    mcp-server stdio (initialize/tools.list/call/-32601)"
elif [[ -z "$MCP_VERDICT" ]]; then
  SKIP=$((SKIP+1)); echo "  SKIP  mcp-server stdio (driver produced no output)"
else
  FAIL=$((FAIL+1)); fails+=("mcp-server stdio: $MCP_VERDICT"); echo "  FAIL  mcp-server stdio ($MCP_VERDICT)"
fi

# --- Writes (opt-in): notes create → show → delete round-trip incl. #26 formatting
if [[ $RW -eq 1 ]]; then
  TITLE="pippin-e2e-$(date +%s)"
  CREATED="$("$BIN" notes create "$TITLE" --body $'line1\n\nline2' --format agent 2>/dev/null)"
  # notes create result shape: {data:{action,success,details:{title,id}}}
  NOTE_ID="$(printf '%s' "$CREATED" | python3 -c "import json,sys; d=json.load(sys.stdin); print(((d.get('data') or {}).get('details') or {}).get('id',''))")"
  if [[ -n "$NOTE_ID" ]]; then
    run "notes #26 newlines survive round-trip" "'line2' in d['data'].get('plainText','') and '\n' in d['data'].get('plainText','')" -- notes show "$NOTE_ID"
    "$BIN" notes delete "$NOTE_ID" --force --format agent >/dev/null 2>&1
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
