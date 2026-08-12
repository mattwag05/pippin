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
# pippin-1son: a clean (non-timed-out) result must NOT carry the partial marker,
# and --preview must inline bodyPreview snippets on the hits.
run "mail search clean result has no partial flag (pippin-1son)" "d.get('partial') is None" \
  -- mail search "the" --limit 3
run "mail search --preview fills bodyPreview (pippin-1son)" "
len(d['data']) == 0 or any(isinstance(m.get('bodyPreview'), str) and m['bodyPreview'] for m in d['data'])" \
  -- mail search "the" --limit 3 --preview 120

# pippin-1son: batch mail show — 2+ ids → one batched fetch, array output;
# single id keeps the original single-object shape.
IDS=($("$BIN" mail list --limit 2 --no-contacts --format agent 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    rows = d['data'] if isinstance(d['data'], list) else d['data'].get('messages', [])
    print('\n'.join(r['id'] for r in rows[:2]))
except Exception:
    pass"))
if [[ ${#IDS[@]} -eq 2 ]]; then
  run "mail show 2 ids returns array (pippin-1son)" "
isinstance(d['data'], list) and len(d['data']) == 2 and all(isinstance(m.get('body'), str) for m in d['data'])" \
    -- mail show "${IDS[1]}" "${IDS[2]}"
  run "mail show 1 id keeps object shape (pippin-1son)" "isinstance(d['data'], dict)" \
    -- mail show "${IDS[1]}"
else
  SKIP=$((SKIP+1)); echo "  SKIP  mail show batch (need 2 message ids)"
fi
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

# --- pippin-z0f6: no account's inbox may be silently empty on the fast path.
# Gmail stores INBOX as a LABEL over [Gmail]/All Mail, so the fast path's
# mailbox match found zero rows and returned `status: ok, data: []` — a real
# inbox reported as empty, on every Gmail-family account. Per-account because
# the pippin-60x parity check above samples ONE account and missed this for
# months. Fast-path [] + JXA non-empty is the failure; both empty is a real
# empty inbox and passes.
if [[ "$FASTPATH_OK" == "yes" ]]; then
  ACCTS="$("$BIN" mail accounts --format agent 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit()
for r in (d.get('data') or []):
    if r.get('name'): print(r['name'])")"
  EMPTY_ACCTS=()
  while IFS= read -r acct; do
    [[ -z "$acct" ]] && continue
    NFAST="$("$BIN" mail list --account "$acct" --mailbox INBOX --limit 5 --fields id --no-contacts --format agent 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(-1); sys.exit()
print(len(d.get('data') or []) if d.get('status') == 'ok' else -1)")"
    [[ "$NFAST" != "0" ]] && continue
    NSLOW="$(PIPPIN_MAIL_FASTPATH=0 "$BIN" mail list --account "$acct" --mailbox INBOX --limit 5 --fields id --no-contacts --format agent 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(-1); sys.exit()
print(len(d.get('data') or []) if d.get('status') == 'ok' else -1)")"
    [[ "$NSLOW" -gt 0 ]] && EMPTY_ACCTS+=("$acct($NSLOW via JXA)")
  done <<< "$ACCTS"
  if [[ ${#EMPTY_ACCTS[@]} -eq 0 ]]; then
    PASS=$((PASS+1)); echo "  ok    no account's inbox is silently empty on the fast path (pippin-z0f6)"
  else
    FAIL=$((FAIL+1))
    fails+=("fast path returns an empty inbox for: ${EMPTY_ACCTS[*]}")
    echo "  FAIL  fast-path inbox empty for: ${EMPTY_ACCTS[*]}"
  fi
else
  SKIP=$((SKIP+1)); echo "  SKIP  fast-path inbox non-empty check (fast path unavailable)"
fi

# --- pippin-37az: paginated agent output keeps `data` an array (envelope v3).
# `--page` used to switch `data` to {items, next_cursor} with no version change,
# so a consumer iterating `.data` got dict KEYS ("items") instead of rows. Run
# here because every paginated command is permission-gated: the XCTest sweep can
# only reach 2 of 6 (grants attach to the launching process), while this script
# runs the granted binary from a terminal and reaches all six.
PAGE_BAD=()
PAGE_OK=0
for spec in "mail list" "notes list" "reminders list" "calendar events" "contacts search a" "memos list"; do
  # shellcheck disable=SC2086
  VERDICT="$("$BIN" ${=spec} --page 1 --page-size 2 --format agent 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print('SKIP'); sys.exit()
if d.get('status') != 'ok':
    print('SKIP'); sys.exit()
data = d.get('data')
if isinstance(data, dict):
    print('NESTED')          # the v2 shape — cursor re-nested inside data
elif not isinstance(data, list):
    print('NOT-A-LIST')
elif 'next_cursor' in d and not isinstance(d['next_cursor'], str):
    print('BAD-CURSOR')
else:
    print('PASS')")"
  case "$VERDICT" in
    PASS) PAGE_OK=$((PAGE_OK+1)) ;;
    SKIP) ;;
    *) PAGE_BAD+=("$spec:$VERDICT") ;;
  esac
done
if [[ ${#PAGE_BAD[@]} -gt 0 ]]; then
  FAIL=$((FAIL+1)); fails+=("paginated data shape: ${PAGE_BAD[*]}")
  echo "  FAIL  paginated agent data must stay an array (${PAGE_BAD[*]})"
elif [[ "$PAGE_OK" -eq 0 ]]; then
  SKIP=$((SKIP+1)); echo "  SKIP  paginated agent data shape (no paginated command reachable)"
else
  PASS=$((PASS+1)); echo "  ok    paginated agent data stays an array, cursor top-level ($PAGE_OK/6) (pippin-37az)"
fi

# --- pippin-ml9: mail verify — baseline report shape on a live message
VID="$("$BIN" mail list --limit 1 --no-contacts --format agent 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    rows = d['data'] if isinstance(d['data'], list) else d['data'].get('messages', [])
    print(rows[0]['id'] if rows else '')
except Exception:
    print('')")"
if [[ -n "$VID" ]]; then
  run "mail verify report shape (pippin-ml9)" "
isinstance(d['data'].get('verdict'), str)
and isinstance(d['data'].get('dimensions'), list)
and len(d['data']['dimensions']) == 7
and all('current' in x and 'prior' in x and 'deviation' in x for x in d['data']['dimensions'])" \
    -- mail verify "$VID"
  # pippin-fwa: deep auth-chain parse from raw source — a real synced message
  # must yield at least one Received hop (chain absent = source fetch broke).
  run "mail verify auth chain (pippin-fwa)" "
isinstance(d['data'].get('authChain'), dict)
and isinstance(d['data']['authChain'].get('received'), list)
and len(d['data']['authChain']['received']) >= 1
and isinstance(d['data']['authChain'].get('authenticationResults'), list)" \
    -- mail verify "$VID"
else
  SKIP=$((SKIP+1)); echo "  SKIP  mail verify (no message id available)"
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
import json, os, subprocess, sys, time
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
    # pippin-9urs: a delete tool called without confirm must fail in buildArgs,
    # BEFORE the child spawns. `contacts delete` blocks on readLine() without
    # --force, so a gate that let the omission through would hang this call for
    # the full 60s child timeout. Timing is the assertion: a pre-spawn throw is
    # instant, a hang is not.
    t0 = time.monotonic()
    send({"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"contacts_delete","arguments":{"identifier":"e2e-nonexistent"}}})
    noconfirm = recv()
    gate_secs = time.monotonic() - t0
    gate_ok = ((noconfirm or {}).get("result") or {}).get("isError") is True and gate_secs < 10
    if init and ntools >= 70 and ok and err_code == -32601 and gate_ok:
        print("PASS")
    else:
        print("FAIL: init=%s ntools=%s call_ok=%s unk=%s confirm_gate=%s (%.1fs)"
              % (bool(init), ntools, ok, err_code, gate_ok, gate_secs))
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
    # pippin-cxd: a soft-deleted note must disappear from show AND list (Notes
    # `delete` only moves it to Recently Deleted, which we now filter out).
    run_err "notes delete → show not-found (pippin-cxd)" note_not_found 3 -- notes show "$NOTE_ID"
    run "notes delete → gone from list (pippin-cxd)" "'$NOTE_ID' not in [n.get('id') for n in d['data']]" -- notes list --limit 100
  else
    FAIL=$((FAIL+1)); fails+=("notes create round-trip: no id returned")
    echo "  FAIL  notes create round-trip (no id)"
  fi

  # pippin-9urs: mail mark read/unread round-trip. Flips the newest INBOX
  # message and restores its original state, so the mailbox is unchanged on
  # exit. `mail list` reports LIVE read state (the cached MailMessage.read is a
  # fetch-time snapshot), so it is the only honest way to verify the flip.
  MSG="$("$BIN" mail list --limit 1 --format agent 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); m=(d.get('data') or [{}])[0]; print(m.get('id',''), str(m.get('read','')).lower())")"
  MSG_ID="${MSG%% *}"; WAS_READ="${MSG##* }"
  if [[ -n "$MSG_ID" && ( "$WAS_READ" == "true" || "$WAS_READ" == "false" ) ]]; then
    if [[ "$WAS_READ" == "true" ]]; then FLIP="--unread"; WANT="False"; else FLIP="--read"; WANT="True"; fi
    "$BIN" mail mark "$MSG_ID" $FLIP --format agent >/dev/null 2>&1
    run "mail mark flips live read state" \
      "[m['read'] for m in d['data'] if m['id'] == '$MSG_ID'] == [$WANT]" \
      -- mail list --limit 1
    # Restore. Verified below so a failed restore is a FAIL, not silent drift.
    if [[ "$WAS_READ" == "true" ]]; then "$BIN" mail mark "$MSG_ID" --read --format agent >/dev/null 2>&1
    else "$BIN" mail mark "$MSG_ID" --unread --format agent >/dev/null 2>&1; fi
    run "mail mark restores original state" \
      "[str(m['read']).lower() for m in d['data'] if m['id'] == '$MSG_ID'] == ['$WAS_READ']" \
      -- mail list --limit 1
  else
    SKIP=$((SKIP+1)); echo "  SKIP  mail mark round-trip (no INBOX message to flip)"
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
