#!/bin/sh
# Seeds the PippinBench fixture state. Run ONLY inside the disposable benchmark VM, never on a real Mac.
# Idempotent: removes prior PippinBench containers first, so a second run leaves exactly one copy.
# Writes ~/bench/state.json (native identifier of every created object, keyed by manifest key).
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
BENCH="$HOME/bench"
BIN="$BENCH/bin/pb-seed"
PARTS="$BENCH/state.d"
MANIFEST="$HERE/manifest.json"
CHATDB="$HOME/Library/Messages/chat.db"

# Every command that touches an app or a privacy-gated store gets a wall-clock limit: first-run dialogs hang forever.
limit() { secs=$1; shift; perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; }

if [ "$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo 0)" != "1" ] && [ "${PIPPINBENCH_ALLOW_HOST:-}" != "yes-this-is-disposable" ]; then
  echo "seed.sh: this is not a virtual machine; refusing to seed Apple apps here" >&2
  exit 2
fi

mkdir -p "$BENCH/bin" "$PARTS"

echo "seed: building pb-seed"
if [ ! -x "$BIN" ] || [ "$HERE/seed.swift" -nt "$BIN" ]; then
  swiftc -O -o "$BIN" "$HERE/seed.swift"
fi
[ -f "$HOME/grant.sh" ] && sh "$HOME/grant.sh" "$BIN" >/dev/null

echo "seed: calendar, reminders, contacts (EventKit and Contacts)"
limit 180 "$BIN" seed "$MANIFEST" > "$PARTS/eventkit.json"

echo "seed: notes (osascript)"
notes_ready() { limit 30 osascript -e 'tell application "Notes" to count of accounts' >/dev/null 2>&1; }
if ! notes_ready; then
  # The "Welcome to Notes" sheet blocks every Apple event until it is dismissed.
  defaults write com.apple.Notes hasShownWelcomeScreen -bool true
  limit 20 osascript -e 'tell application "System Events" to tell process "Notes" to click button "Continue" of sheet 1 of window 1' >/dev/null 2>&1 || true
  sleep 2
  if ! notes_ready; then
    echo "seed.sh: Notes does not answer Apple events (welcome sheet or missing Automation grant for the ssh session); see README.md" >&2
    exit 1
  fi
fi
limit 300 osascript -l JavaScript "$HERE/notes.js" seed "$MANIFEST" > "$PARTS/notes.json"

echo "seed: synthetic Messages store"
if [ ! -f "$CHATDB" ] && [ ! -f "$CHATDB.orig" ]; then
  # Messages creates the real, empty store on first launch. No sign-in happens.
  limit 30 open -gj -a Messages || true
  n=0
  while [ ! -f "$CHATDB" ] && [ "$n" -lt 30 ]; do sleep 1; n=$((n + 1)); done
  killall Messages 2>/dev/null || true
fi
limit 120 python3 "$HERE/make_chatdb.py" install "$MANIFEST" --pb-seed "$BIN" > "$PARTS/messages.json"

python3 - "$PARTS" "$MANIFEST" "$BENCH/state.json" <<'PY'
import hashlib, json, sys
parts, manifest, out = sys.argv[1:4]
state = {"manifest_sha256": hashlib.sha256(open(manifest, "rb").read()).hexdigest()}
for name in ("eventkit", "notes", "messages"):
    state.update(json.load(open("%s/%s.json" % (parts, name), encoding="utf-8")))
json.dump(state, open(out, "w", encoding="utf-8"), indent=1, sort_keys=True)
print("seed: wrote %s (%d events, %d reminders, %d contacts, %d notes, %d messages)" % (
    out, len(state["events"]), len(state["reminders"]), len(state["contacts"]), len(state["notes"]),
    state["messages"]["message_count"]))
PY
