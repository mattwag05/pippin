#!/bin/sh
# Removes exactly what ~/bench/state.json lists and verifies by identifier that each object is gone.
# Run ONLY inside the disposable benchmark VM.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BENCH="$HOME/bench"
BIN="$BENCH/bin/pb-seed"
STATE="${1:-$BENCH/state.json}"

limit() { secs=$1; shift; perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; }

if [ ! -f "$STATE" ]; then
  echo "teardown.sh: $STATE not found; nothing to remove" >&2
  exit 1
fi

rc=0
echo "teardown: calendar, reminders, contacts"
limit 180 "$BIN" teardown "$STATE" || rc=1
echo "teardown: notes"
limit 180 osascript -l JavaScript "$HERE/notes.js" teardown "$STATE" || rc=1
echo "teardown: Messages store"
limit 60 python3 "$HERE/make_chatdb.py" restore || rc=1
python3 - "$STATE" <<'PY' || rc=1
import json, os, sqlite3, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))["messages"]
con = sqlite3.connect("file:%s?mode=ro" % m["db"], uri=True)
left = [c["id"] for c in m["chats"].values() if con.execute("SELECT 1 FROM chat WHERE guid = ?", (c["id"],)).fetchone()]
print(json.dumps({"checked": len(m["chats"]), "remaining": left, "orig_left_behind": os.path.exists(m["orig"])}))
sys.exit(1 if left else 0)
PY

if [ "$rc" -eq 0 ]; then
  rm -f "$STATE"
  rm -rf "$BENCH/state.d"
  echo "teardown: OK, everything listed in state.json is gone"
else
  echo "teardown: FAILED, state.json kept" >&2
fi
exit "$rc"
