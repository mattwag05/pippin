"""Correctness, safety and write-probe stages. Same adapters and driver as run.py;
these stages additionally need the fixture manifest (ground truth).

    python3 harness/checks.py --out results/<date> [--only pippin] [--stages correctness,safety,writes]

Stages (methodology axis in brackets):
    correctness  [correctness] every read operation compared to the seeded ground truth
    safety       [safety]      hostile strings as queries; a canary file must never appear
    writes       [coverage, correctness, safety] create, read back, delete in the fixture
                 containers, with a plain, a quoting and a shell-injection title

Run ONLY inside the disposable benchmark VM: the writes stage creates and deletes records.
Re-seed the fixture afterwards (fixtures/seed.sh) so leftovers cannot skew a later run.
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import re
import subprocess
import sys
import tempfile
import unicodedata
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from core import timed  # noqa: E402
from run import Driver, load_adapters, resolve  # noqa: E402

SEARCH_OPS = ["reminders.search", "notes.search", "contacts.search", "calendar.search", "messages.search"]


def norm(text) -> str:
    return unicodedata.normalize("NFC", str(text or "")).strip()


def epoch(value):
    """An instant from whatever a tool printed. Naive strings are read as local time. None when unparseable."""
    if isinstance(value, (int, float)):
        return float(value)
    text = str(value).strip().replace("Z", "+00:00")
    text = re.sub(r"(\.\d{1,6})\d*", r"\1", text)  # 3.9 fromisoformat takes at most 6 fraction digits
    text = re.sub(r"\.(\d{1,5})(?=[+-]|$)", lambda m: "." + m.group(1).ljust(6, "0"), text)
    text = re.sub(r"([+-]\d{2})(\d{2})$", r"\1:\2", text)
    try:
        return datetime.fromisoformat(text).astimezone().timestamp()
    except ValueError:
        return None


def call(driver: Driver, op: str, args: dict):
    """(outcome, records or None, raw text). ValueError covers argv that cannot carry the value (NUL)."""
    try:
        _, outcome, value = timed(lambda: driver.call(op, args))
    except ValueError as error:
        return "not_passable", None, str(error)
    if outcome == "hang":
        driver.close()
    records = None
    if outcome == "ok" and op in getattr(driver.adapter, "PARSE", {}):
        try:
            records = driver.adapter.PARSE[op](value)
        except Exception as error:  # a parser that cannot read the reply is an adapter gap, recorded as such
            return "unparsed", None, str(error)[:200]
    return outcome, records, str(value)


def compare(records: list, must: list, allowed: list, key: str = "title") -> dict:
    got = collections.Counter(norm(r.get(key)) for r in records)
    need = collections.Counter(norm(t) for t in must)
    ok = set(got) if allowed is None else set(need) | {norm(t) for t in allowed}
    return {
        "expected": sum(need.values()),
        "returned": sum(got.values()),
        "missing": sorted((need - got).elements()),
        "unexpected": sorted(t for t in got if t not in ok),
        "duplicated": sorted(t for t in need if got[t] > need[t]),
    }


def has(query: str, *fields) -> bool:
    return any(query.lower() in (f or "").lower() for f in fields)


def expectations(manifest: dict, read_args: dict) -> dict:
    """op -> (must titles, also-allowed titles, key). Built only from manifest.json."""
    reminders = manifest["reminders"]["items"]
    events = manifest["calendar"]["events"]
    notes = manifest["notes"]["notes"]
    people = [norm(p["given_name"] + " " + p["family_name"]) for p in manifest["contacts"]["people"]]
    occurrences = [e["title"] for e in events for _ in (e.get("occurrences") or [0])]
    out = {
        "reminders.list": ([r["title"] for r in reminders if not r["completed"]], [r["title"] for r in reminders], "title"),
        "calendar.events": (occurrences, [], "title"),
        "contacts.list": (people, None, "title"),  # unscoped: the machine may hold other contacts
        "contacts.search": (people, [], "title"),
        "notes.list": ([n["title"] for n in notes], [], "title"),
    }
    q = read_args.get("reminders.search", {}).get("query", "")
    out["reminders.search"] = ([r["title"] for r in reminders if has(q, r["title"]) and not r["completed"]], [r["title"] for r in reminders if has(q, r["title"], r.get("notes"))], "title")
    q = read_args.get("calendar.search", {}).get("query", "")
    out["calendar.search"] = ([e["title"] for e in events if has(q, e["title"]) for _ in (e.get("occurrences") or [0])], [e["title"] for e in events if has(q, e["title"], e.get("notes"), e.get("location"))], "title")
    q = read_args.get("notes.search", {}).get("query", "")
    out["notes.search"] = ([n["title"] for n in notes if has(q, n["title"])], [n["title"] for n in notes if has(q, n["title"], n["body"])], "title")
    limit = read_args.get("messages.history", {}).get("limit", 50)
    chat_a = [m for m in manifest["messages"]["messages"] if m["chat"] == "chat-a" and m["displayable"]]
    # a displayable message can be attachment-only, so empty text is allowed and takes a slot in the window
    out["messages.history"] = ([m["text"] for m in chat_a[-limit:] if m.get("text")], [m.get("text") or "" for m in chat_a], "text")
    # Amendment 4: mail and voice memos, from the manifest's seeded mailbox and store.
    if "mail" in manifest:
        mails = sorted(manifest["mail"]["messages"], key=lambda m: -m["date_epoch"])
        limit = read_args.get("mail.list", {}).get("limit", 20)
        out["mail.list"] = ([m["subject"] for m in mails[:limit]], [m["subject"] for m in mails], "title")
        q = read_args.get("mail.search", {}).get("query", "")
        out["mail.search"] = ([m["subject"] for m in mails if has(q, m["subject"])], [m["subject"] for m in mails if has(q, m["subject"], m["body"], m["from"], m["from_name"])], "title")
    if "memos" in manifest:
        out["memos.list"] = ([r["title"] for r in manifest["memos"]["recordings"]], [], "title")
    return out


def date_checks(op: str, records: list, manifest: dict) -> dict | None:
    """Instants a tool reported against the seeded instants, matched by title."""
    if op == "reminders.list":
        truth = {norm(r["title"]): {r["due_epoch"]} for r in manifest["reminders"]["items"] if r.get("due_epoch")}
        field = "due"
    elif op == "calendar.events":
        truth = collections.defaultdict(set)
        for e in manifest["calendar"]["events"]:
            for o in e.get("occurrences") or ([e] if e.get("start_epoch") else []):
                truth[norm(e["title"])].add(o["start_epoch"])
        field = "start"
    else:
        return None
    result = {"checked": 0, "wrong": [], "unparsed": 0}
    for r in records:
        want = truth.get(norm(r.get("title")))
        if not want or r.get(field) is None:
            continue
        got = epoch(r[field])
        if got is None:
            result["unparsed"] += 1
            continue
        result["checked"] += 1
        if not any(abs(got - w) < 1 for w in want):
            result["wrong"].append({"title": r.get("title"), "reported": r[field]})
    return result


def stage_correctness(driver: Driver, read_args: dict, manifest: dict) -> dict:
    out = {}
    for op, (must, allowed, key) in expectations(manifest, read_args).items():
        if op not in driver.adapter.OPS or op not in read_args:
            continue
        outcome, records, raw = call(driver, op, read_args[op])
        if records is None:
            # plain-text replies have no parser: recorded, and not scored either way
            out[op] = {"outcome": "not_machine_readable" if outcome == "ok" else outcome, "detail": raw[:200]}
            continue
        out[op] = {"outcome": "ok", **compare(records, must, allowed, key)}
        dates = date_checks(op, records, manifest)
        if dates:
            out[op]["dates"] = dates
        if op == "messages.history":
            other = manifest["messages"]["chats"][0]["participants"][0]
            out[op]["outgoing_with_recipient_as_sender"] = sum(1 for r in records if r.get("is_from_me") and r.get("sender") == other)
    if "messages.chats" in driver.adapter.OPS and "messages.chats" in read_args:
        outcome, records, raw = call(driver, "messages.chats", read_args["messages.chats"])
        if records is not None:
            unread = {}
            for chat in manifest["messages"]["chats"]:
                hit = [r for r in records if chat["chat_identifier"] in json.dumps(r) or (chat["display_name"] and chat["display_name"] in json.dumps(r, ensure_ascii=False))]
                unread[chat["key"]] = {"found": bool(hit), "expected_unread": chat["unread_count"], "reported_unread": hit[0].get("unread") if hit else None}
            out["messages.chats"] = {"outcome": "ok", "chats": unread}
    driver.close()
    return out


def stage_safety(driver: Driver, read_args: dict, manifest: dict) -> dict:
    ops = [op for op in SEARCH_OPS if op in driver.adapter.OPS and op in read_args]
    if not ops:
        return {"not_run": "no search operation to carry a hostile query"}
    canary = os.path.join(tempfile.mkdtemp(prefix="pb-canary-"), "canary")
    out = {"ops": ops, "items": {}, "canary_created": []}
    for item in manifest["hostile_inputs"]["items"]:
        raw = item["value"]
        if isinstance(raw, dict):  # {"repeat": "A", "times": 10000}
            raw = raw["repeat"] * raw["times"]
        value = raw.replace(manifest["hostile_inputs"]["canary_placeholder"], canary)
        outcomes = {}
        for op in ops:
            outcomes[op] = call(driver, op, {**read_args[op], "query": value})[0]
            if os.path.exists(canary):
                out["canary_created"].append({"item": item["key"], "op": op})  # dealbreaker: executed attacker text
                os.remove(canary)
        out["items"][item["key"]] = {"class": item["class"], "outcomes": outcomes}
    # the tool must still answer a normal call after the hostile ones
    out["alive_after"] = {op: call(driver, op, read_args[op])[0] for op in ops}
    driver.close()
    return out


def stage_writes(driver: Driver, read_args: dict, state: dict) -> dict:
    canary = "/tmp/pbc%d" % os.getpid()  # short: Notes truncates long titles, which would hide a faithful round trip
    titles = {
        "plain": "PBW plain probe",
        "quoting": "PBW it's \"quoted\" \\ backé \U0001f9ea",
        "injection": "PBW $(touch %s) `touch %s`" % (canary, canary),
    }
    lid, cid = (state.get("reminder_list") or {}).get("id"), (state.get("calendar") or {}).get("id")
    domains = {
        "reminders": ("reminders.list", lambda t: {"list": "PippinBench", "list_id": lid, "title": t}, {"list": "PippinBench"}),
        "calendar": ("calendar.events", lambda t: {"calendar": "PippinBench", "calendar_id": cid, "title": t, "start": "2027-03-12T15:00:00-05:00", "end": "2027-03-12T15:30:00-05:00"}, {}),
        "notes": ("notes.list", lambda t: {"folder": "PippinBench", "title": t, "body": "probe body"}, {}),
        "contacts": ("contacts.search", lambda t: {"first": "Probe", "last": t}, {}),
    }
    out = {}
    for domain, (list_op, create_args, id_extra) in domains.items():
        create_op, delete_op = domain + ".create", domain + ".delete"
        if create_op not in driver.adapter.OPS:
            continue
        list_args = {"query": "PBW"} if domain == "contacts" else read_args.get(list_op)
        out[domain] = {}
        for label, title in titles.items():
            created = call(driver, create_op, create_args(title))
            step = {"create": created[0]}
            if created[0] != "ok":
                step["create_detail"] = created[2][:200]
            _, records, _ = call(driver, list_op, list_args) if list_args is not None and list_op in driver.adapter.OPS else (None, None, None)
            mine = [r for r in records or [] if "PBW" in norm(r.get("title"))]
            step["read_back"] = bool(mine)
            step["title_exact"] = any(title in norm(r.get("title")) for r in mine)
            if os.path.exists(canary):
                step["canary_created"] = True
                os.remove(canary)
            if delete_op in driver.adapter.OPS:
                for r in mine:  # also clears leftovers of an earlier label whose delete failed
                    args = {"id": r.get("id"), **id_extra}
                    if domain == "notes" and "notes.show" in driver.adapter.OPS:
                        shown = call(driver, "notes.show", {"id": r.get("id")})[1] or [{}]
                        if shown[0].get("content_hash"):
                            args["content_hash"] = shown[0]["content_hash"]
                    step["delete"] = call(driver, delete_op, args)[0]
                after = call(driver, list_op, list_args)[1] if mine else None
                step["gone"] = after is not None and not [r for r in after if "PBW" in norm(r.get("title"))]
            out[domain][label] = step
    driver.close()
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tools-dir", default=os.path.expanduser("~/bench-tools"))
    parser.add_argument("--out", required=True)
    parser.add_argument("--state", default=os.path.expanduser("~/bench/state.json"))
    parser.add_argument("--only", default="")
    parser.add_argument("--stages", default="correctness,safety,writes")
    options = parser.parse_args()

    if subprocess.run(["sysctl", "-n", "kern.hv_vmm_present"], capture_output=True, text=True).stdout.strip() != "1":
        sys.exit("checks.py creates and deletes records: run it only inside the disposable benchmark VM")
    with open(os.path.join(ROOT, "ops_args.json")) as handle:
        ops_args = json.load(handle)
    with open(os.path.join(ROOT, "fixtures", "manifest.json")) as handle:
        manifest = json.load(handle)
    with open(options.state) as handle:
        state = json.load(handle)
    stages = set(options.stages.split(","))
    os.makedirs(options.out, exist_ok=True)

    for adapter in load_adapters(set(options.only.split(",")) if options.only else None):
        driver = Driver(adapter, options.tools_dir)
        record = {"tool": adapter.NAME, "version": adapter.VERSION}
        try:
            read_args = resolve(driver, ops_args["read"], state)
            if "correctness" in stages:
                record["correctness"] = stage_correctness(driver, read_args, manifest)
            if "safety" in stages:
                record["safety"] = stage_safety(driver, read_args, manifest)
            if "writes" in stages:
                record["writes"] = stage_writes(driver, read_args, state)
        except Exception as error:  # one tool's failure must not stop the others
            record["checks_failed"] = repr(error)[:300]
        finally:
            driver.close()
        with open(os.path.join(options.out, adapter.NAME + ".checks.json"), "w") as handle:
            json.dump(record, handle, indent=2, ensure_ascii=False)
        print(adapter.NAME, "checked", flush=True)


if __name__ == "__main__":
    assert epoch("2027-03-08T09:00:00-05:00") == epoch("2027-03-08T14:00:00Z") == epoch("2027-03-08T14:00:00.000+0000") == 1804514400
    assert compare([{"title": "a"}, {"title": "x"}], ["a", "b"], []) == {"expected": 2, "returned": 2, "missing": ["b"], "unexpected": ["x"], "duplicated": []}
    main()
