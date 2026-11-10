#!/usr/bin/python3
"""Latency bench for read-only pippin commands. Prints timings, counts and
hashes only: command output is parsed in memory and never printed or stored.

usage: bench-latency.py <binary> <out.json> [runs] [name-filter]
"""
import hashlib, json, os, statistics, subprocess, sys, time

binary, out_path = sys.argv[1], sys.argv[2]
runs = int(sys.argv[3]) if len(sys.argv) > 3 else 5
only = sys.argv[4] if len(sys.argv) > 4 else None
env = dict(os.environ, PIPPIN_NO_DISCLAIM="1")

VOLATILE = {"generatedAt", "generated_at", "duration_ms", "durationMs", "elapsed_ms"}


def scrub(v):
    if isinstance(v, dict):
        return {k: scrub(x) for k, x in sorted(v.items()) if k not in VOLATILE}
    if isinstance(v, list):
        return [scrub(x) for x in v]
    return v


def run(args):
    t = time.perf_counter()
    p = subprocess.run([binary] + args + ["--format", "agent"], env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    ms = (time.perf_counter() - t) * 1000
    try:
        doc = json.loads(p.stdout)
    except Exception:
        doc = None
    return ms, p.returncode, doc


def describe(doc):
    if not isinstance(doc, dict):
        return {"status": "unparsed"}
    data = doc.get("data")
    d = {"status": doc.get("status"),
         "code": (doc.get("error") or {}).get("code"),
         "rows": len(data) if isinstance(data, list) else None,
         "warnings": len(doc.get("warnings") or []),
         "timed_out": doc.get("timed_out", doc.get("timedOut")),
         "hash": hashlib.sha256(json.dumps(scrub(doc), sort_keys=True).encode()).hexdigest()[:12]}
    return d


# A conversation id for `messages show`, held in memory only.
_, _, convs = run(["messages", "list", "--limit", "1", "--fields", "all"])
conv_id = None
if isinstance(convs, dict) and isinstance(convs.get("data"), list) and convs["data"]:
    row = convs["data"][0]
    conv_id = row.get("id") or row.get("guid") or row.get("conversationId")

COMMANDS = [
    ("status", ["status"]),
    ("doctor", ["doctor"]),
    ("digest", ["digest"]),
    ("mail accounts", ["mail", "accounts"]),
    ("mail mailboxes", ["mail", "mailboxes"]),
    ("mail list --limit 20", ["mail", "list", "--limit", "20"]),
    ("mail list --limit 20 --no-contacts", ["mail", "list", "--limit", "20", "--no-contacts"]),
    ("mail search the --limit 10", ["mail", "search", "the", "--limit", "10"]),
    ("mail activity --preview 0", ["mail", "activity", "--preview", "0"]),
    ("calendar today", ["calendar", "today"]),
    ("calendar events --range week", ["calendar", "events", "--range", "week"]),
    ("calendar search meeting", ["calendar", "search", "meeting"]),
    ("reminders list --limit 20", ["reminders", "list", "--limit", "20"]),
    ("reminders search call", ["reminders", "search", "call"]),
    ("contacts list", ["contacts", "list"]),
    ("contacts search john", ["contacts", "search", "john"]),
    ("messages list --limit 10", ["messages", "list", "--limit", "10"]),
    ("messages list --limit 10 --no-contacts", ["messages", "list", "--limit", "10", "--no-contacts"]),
    ("messages search the", ["messages", "search", "the"]),
    ("memos list --limit 10", ["memos", "list", "--limit", "10"]),
    ("notes list --limit 50", ["notes", "list", "--limit", "50"]),
]
if conv_id:
    COMMANDS.insert(19, ("messages show <id>", ["messages", "show", conv_id]))

results = {}
for name, args in COMMANDS:
    if only and only not in name:
        continue
    times, last, code = [], None, None
    hashes = set()
    for _ in range(runs):
        ms, code, doc = run(args)
        times.append(ms)
        last = describe(doc)
        hashes.add(last.get("hash"))
    results[name] = {"median_ms": round(statistics.median(times)), "max_ms": round(max(times)),
                     "min_ms": round(min(times)), "exit": code, "stable_hash": len(hashes) == 1, **last}
    r = results[name]
    print(f"{name:42s} med {r['median_ms']:6d} max {r['max_ms']:6d} exit {code} "
          f"{r['status']} {r['code'] or ''} rows={r['rows']} warn={r['warnings']} to={r['timed_out']} "
          f"hash={r['hash']} stable={r['stable_hash']}", flush=True)

json.dump(results, open(out_path, "w"), indent=1)
