#!/usr/bin/env python3
"""Independent ground-truth check: reads the seeded state back and asserts it equals manifest.json.

Uses no tool under test: pb-seed dump (EventKit, Contacts), osascript (Notes), sqlite3 (chat.db).
Exits 0 when everything matches, 1 with a diff otherwise. Run ONLY inside the disposable benchmark VM.
Standard library only, Python 3.9.
"""
import argparse
import json
import os
import sqlite3
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
APPLE_EPOCH = 978307200
errors = []


def eq(path, expected, actual):
    if expected != actual:
        errors.append("%s\n    expected: %r\n    actual:   %r" % (path, expected, actual))


def run_json(cmd, stdin=None, timeout=300):
    try:
        p = subprocess.run(cmd, input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    except subprocess.TimeoutExpired:
        sys.exit("verify: timed out after %ds: %s" % (timeout, " ".join(cmd)))
    if p.returncode != 0:
        sys.exit("verify: %s failed (%d): %s" % (cmd[0], p.returncode, p.stderr.decode(errors="replace").strip()))
    return json.loads(p.stdout.decode())


def by(items, field):
    out = defaultdict(list)
    for item in items:
        out[item[field]].append(item)
    return out


def check_container(label, found, state_id):
    eq("%s: number of containers named PippinBench" % label, 1, len(found))
    if found:
        eq("%s: container id matches state.json" % label, state_id, found[0]["id"])


def check_eventkit(manifest, state, dump):
    check_container("calendar", dump["calendars"], state["calendar"]["id"])
    titles = by(dump["events"], "title")
    expected_total = 0
    for e in manifest["calendar"]["events"]:
        p = "event %s" % e["key"]
        found = sorted(titles.get(e["title"], []), key=lambda x: x["start_epoch"])
        occurrences = e.get("occurrences")
        expected_total += len(occurrences) if occurrences else 1
        eq(p + ": occurrences found by exact title", len(occurrences) if occurrences else 1, len(found))
        if not found:
            continue
        eq(p + ": id", [state["events"][e["key"]]["id"]], sorted({f["id"] for f in found}))
        eq(p + ": recurring", bool(occurrences), found[0]["recurring"])
        eq(p + ": all_day", e["all_day"], found[0]["all_day"])
        eq(p + ": time_zone", e["time_zone"], found[0]["time_zone"])
        eq(p + ": location", e["location"], found[0]["location"])
        eq(p + ": notes", e["notes"], found[0]["notes"])
        if e["all_day"]:
            eq(p + ": all-day dates", (e["start_date"], e["end_date"]), (found[0]["start_date"], found[0]["end_date"]))
        elif occurrences:
            eq(p + ": occurrence instants", [(o["start_epoch"], o["end_epoch"]) for o in occurrences],
               [(f["start_epoch"], f["end_epoch"]) for f in found])
        else:
            eq(p + ": stored instants (fetch by identifier)", (e["start_epoch"], e["end_epoch"]),
               (found[0]["stored_start_epoch"], found[0]["stored_end_epoch"]))
            range_end = e.get("eventkit_range_query", {}).get("end_epoch", e["end_epoch"])
            eq(p + ": instants from a date-range query", (e["start_epoch"], range_end),
               (found[0]["start_epoch"], found[0]["end_epoch"]))
            if "duration_seconds" in e:
                eq(p + ": real duration", e["duration_seconds"], found[0]["stored_end_epoch"] - found[0]["stored_start_epoch"])
    eq("calendar: total event occurrences", expected_total, len(dump["events"]))

    check_container("reminders", dump["reminder_lists"], state["reminder_list"]["id"])
    titles = by(dump["reminders"], "title")
    for r in manifest["reminders"]["items"]:
        p = "reminder %s" % r["key"]
        found = titles.get(r["title"], [])
        eq(p + ": copies found by exact title", 1, len(found))
        if not found:
            continue
        f = found[0]
        eq(p + ": id", state["reminders"][r["key"]]["id"], f["id"])
        eq(p + ": tuple (due_epoch, priority, notes, completed, completion_epoch)",
           (r["due_epoch"], r["priority"], r["notes"], r["completed"], r["completion_epoch"]),
           (f["due_epoch"], f["priority"], f["notes"], f["completed"], f["completion_epoch"]))
    eq("reminders: total", len(manifest["reminders"]["items"]), len(dump["reminders"]))

    groups = dump["contact_groups"]
    check_container("contacts group", groups, state["contact_group"]["id"])
    people = manifest["contacts"]["people"]
    if groups:
        eq("contacts group: member count", len(people), groups[0]["member_count"])
    names = by(dump["contacts"], "family_name")
    for c in people:
        p = "contact %s" % c["key"]
        found = names.get(c["family_name"], [])
        eq(p + ": copies found by exact family name", 1, len(found))
        if not found:
            continue
        f = found[0]
        eq(p + ": id", state["contacts"][c["key"]]["id"], f["id"])
        eq(p + ": tuple (given, organization, emails, phones, in_group)",
           (c["given_name"], c["organization"], c["emails"], c["phones"], True),
           (f["given_name"], f["organization"], f["emails"], f["phones"], f["in_group"]))
    eq("contacts: total with the PBX family prefix", len(people), len(dump["contacts"]))


def check_notes(manifest, state, dump):
    check_container("notes folder", dump["folders"], state["notes_folder"]["id"])
    if not dump["folders"]:
        return
    found_notes = dump["folders"][0]["notes"]
    names = by(found_notes, "name")
    for n in manifest["notes"]["notes"]:
        p = "note %s" % n["key"]
        found = names.get(n["title"], [])
        eq(p + ": copies found by exact title", 1, len(found))
        if not found:
            continue
        eq(p + ": id", state["notes"][n["key"]]["id"], found[0]["id"])
        eq(p + ": plaintext", n["title"] + "\n" + n["body"], found[0]["plaintext"].rstrip("\n"))
    eq("notes: total", len(manifest["notes"]["notes"]), len(found_notes))


UNREAD_SQL = """
SELECT count(*) FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID
WHERE j.chat_id = ? AND m.is_from_me = 0 AND m.is_read = 0
  AND m.item_type = 0 AND m.associated_message_type = 0 AND COALESCE(m.date_retracted, 0) = 0
  AND (m.text IS NOT NULL OR m.attributedBody IS NOT NULL OR m.cache_has_attachments = 1)
"""
ROW_SQL = """
SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.date, m.is_from_me, m.is_read, m.item_type,
       m.associated_message_type, m.associated_message_guid, m.date_retracted, m.cache_has_attachments,
       m.group_title, m.service, h.id, c.guid
FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id
JOIN chat_message_join j ON j.message_id = m.ROWID JOIN chat c ON c.ROWID = j.chat_id
ORDER BY m.ROWID
"""


def check_messages(manifest, state, pb_seed):
    spec = manifest["messages"]
    db = os.path.expanduser(spec["db_path"])
    eq("messages: chat.db.orig kept beside the synthetic store", True, os.path.exists(db + ".orig"))
    con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
    eq("messages: synthetic marker row", 1,
       con.execute("SELECT count(*) FROM _SqliteDatabaseProperties WHERE key = 'PippinBenchSynthetic'").fetchone()[0])
    for table, n in (("message", len(spec["messages"])), ("chat", len(spec["chats"])), ("handle", len(spec["handles"])),
                     ("chat_message_join", len(spec["messages"])),
                     ("attachment", sum(len(m.get("attachments", [])) for m in spec["messages"]))):
        eq("messages: rows in %s" % table, n, con.execute("SELECT count(*) FROM %s" % table).fetchone()[0])
    eq("messages: handles", [(h["rowid"], h["id"]) for h in spec["handles"]],
       con.execute("SELECT ROWID, id FROM handle ORDER BY ROWID").fetchall())

    rows = con.execute(ROW_SQL).fetchall()
    blobs = [r[3].hex() for r in rows if r[3] is not None]
    decoded = iter(run_json([pb_seed, "untypedstream"], stdin=json.dumps(blobs).encode()))
    chat_key = {c["guid"]: c["key"] for c in spec["chats"]}
    key_of_guid = {m["guid"]: m["key"] for m in spec["messages"]}
    actual = {}
    for (rowid, guid, text, body, date, from_me, is_read, item_type, assoc_type, assoc_guid, retracted, has_att,
         group_title, service, handle, cguid) in rows:
        body_text = next(decoded) if body is not None else None
        if text is not None and body_text is not None:
            eq("message rowid %d: text column equals the decoded attributedBody" % rowid, text, body_text)
        value = body_text if body_text is not None else text
        if assoc_type:
            kind = "tapback"
        elif item_type:
            kind = "group_event"
        elif retracted:
            kind = "retracted"
        elif has_att:
            kind = "attachment"
        else:
            kind = "text"
        if kind == "attachment":
            storage, value = "placeholder", (value or "").replace("￼", "")
        else:
            storage = {(True, True): "both", (True, False): "text", (False, True): "attributedBody",
                       (False, False): "none"}[(text is not None, body is not None)]
        when = datetime.fromtimestamp(date // 10**9 + APPLE_EPOCH, tz=timezone.utc)
        rec = {"rowid": rowid, "guid": guid, "chat": chat_key.get(cguid), "sender": "me" if from_me else handle,
               "is_from_me": bool(from_me), "date": when.strftime("%Y-%m-%dT%H:%M:%SZ"), "date_ns": date,
               "service": service, "kind": kind, "text": value, "text_storage": storage, "is_read": bool(is_read),
               "displayable": kind in ("text", "attachment") and (value is not None or bool(has_att))}
        if kind == "tapback":
            rec["reaction"] = {"type": assoc_type, "target": key_of_guid.get((assoc_guid or "").split("/")[-1])}
        if kind == "retracted":
            rec["date_retracted_ns"] = retracted
        if kind == "group_event":
            rec["group_title"] = group_title
        if has_att:
            rec["attachments"] = [dict(zip(("guid", "transfer_name", "mime_type", "uti", "total_bytes", "filename"), a))
                                  for a in con.execute(
                                      "SELECT a.guid, a.transfer_name, a.mime_type, a.uti, a.total_bytes, a.filename "
                                      "FROM attachment a JOIN message_attachment_join j ON j.attachment_id = a.ROWID "
                                      "WHERE j.message_id = ? ORDER BY a.ROWID", (rowid,))]
        actual[guid] = rec
    for m in spec["messages"]:
        expected = {k: v for k, v in m.items() if k != "key"}
        if "reaction" in expected:
            expected["reaction"] = {"type": m["reaction"]["type"], "target": m["reaction"]["target"]}
        eq("message %s" % m["key"], expected, actual.get(m["guid"]))

    per_chat = by(spec["messages"], "chat")
    for c in spec["chats"]:
        p = "chat %s" % c["key"]
        eq(p + ": id in state.json", c["guid"], state["messages"]["chats"][c["key"]]["id"])
        row = con.execute("SELECT ROWID, chat_identifier, style, display_name, service_name FROM chat WHERE guid = ?",
                          (c["guid"],)).fetchone()
        eq(p + ": (rowid, chat_identifier, style, display_name, service)",
           (c["rowid"], c["chat_identifier"], 43 if c["style"] == "group" else 45, c["display_name"], c["service"]), row)
        if not row:
            continue
        eq(p + ": participants", sorted(c["participants"]), sorted(r[0] for r in con.execute(
            "SELECT h.id FROM chat_handle_join j JOIN handle h ON h.ROWID = j.handle_id WHERE j.chat_id = ?", (row[0],))))
        eq(p + ": message_count", c["message_count"],
           con.execute("SELECT count(*) FROM chat_message_join WHERE chat_id = ?", (row[0],)).fetchone()[0])
        eq(p + ": unread_count under the rule (%s)" % spec["unread_rule"], c["unread_count"],
           con.execute(UNREAD_SQL, (row[0],)).fetchone()[0])
        # the manifest's own per-chat numbers must also agree with its message list
        ms = per_chat[c["key"]]
        eq(p + ": manifest unread_count is consistent with its messages", c["unread_count"],
           sum(1 for m in ms if not m["is_from_me"] and m["displayable"] and not m["is_read"]))
        last = con.execute("SELECT m.guid FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID "
                           "WHERE j.chat_id = ? ORDER BY m.date DESC LIMIT 1", (row[0],)).fetchone()
        eq(p + ": last_message", c["last_message"], key_of_guid.get(last[0]) if last else None)
    con.close()


def check_mail_memos(manifest, state):
    """Mail over IMAP straight from the local server, memos straight from the store; no tool under test."""
    if state.get("mail"):
        import imaplib
        imap = imaplib.IMAP4("127.0.0.1", 1143)
        imap.login("bench", "local-fixture")  # pragma: allowlist secret (fixture; any password works)
        imap.select("INBOX", readonly=True)
        _, data = imap.search(None, "ALL")
        ids = data[0].split()
        subjects = []
        for i in ids:
            _, part = imap.fetch(i, "(BODY.PEEK[HEADER.FIELDS (SUBJECT)])")
            subjects.append(part[0][1].decode().split(":", 1)[1].strip())
        imap.logout()
        eq("mail: subjects on the server", sorted(m["subject"] for m in manifest["mail"]["messages"]), sorted(subjects))
        eq("mail: Mail.app synced the mailbox", True, state["mail"].get("synced"))
    if state.get("memos"):
        db = os.path.expanduser(manifest["memos"]["store"])
        con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
        rows = con.execute("SELECT ZCUSTOMLABEL, ZPATH FROM ZCLOUDRECORDING WHERE ZCUSTOMLABEL LIKE 'PB Memo %'").fetchall()
        con.close()
        eq("memos: titles in the store", sorted(r["title"] for r in manifest["memos"]["recordings"]), sorted(r[0] for r in rows))
        folder = os.path.dirname(db)
        eq("memos: audio files present", len(rows), sum(1 for r in rows if os.path.exists(os.path.join(folder, r[1]))))


def check_manifest_shape(manifest):
    corpus = manifest["injection_corpus"]
    eq("manifest: injection corpus size", 12, len(corpus))
    index = {"note_body": {n["key"]: n["body"] for n in manifest["notes"]["notes"]},
             "reminder_notes": {r["key"]: r["notes"] for r in manifest["reminders"]["items"]},
             "event_notes": {e["key"]: e["notes"] for e in manifest["calendar"]["events"]}}
    for inj in corpus:
        for where, key in inj["planted"].items():
            eq("injection %s planted as %s in %s" % (inj["key"], where, key), inj["text"], index[where].get(key))
    keys = [x["key"] for section in (manifest["calendar"]["events"], manifest["reminders"]["items"],
                                     manifest["contacts"]["people"], manifest["notes"]["notes"], corpus,
                                     manifest["hostile_inputs"]["items"], manifest["messages"]["chats"],
                                     manifest["messages"]["messages"]) for x in section]
    eq("manifest: keys are unique", len(keys), len(set(keys)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default=os.path.join(HERE, "manifest.json"))
    ap.add_argument("--state", default=os.path.expanduser("~/bench/state.json"))
    ap.add_argument("--pb-seed", default=os.path.expanduser("~/bench/bin/pb-seed"))
    args = ap.parse_args()
    manifest = json.load(open(args.manifest, encoding="utf-8"))
    if not os.path.exists(args.state):
        sys.exit("verify: %s not found; run seed.sh first" % args.state)
    state = json.load(open(args.state, encoding="utf-8"))

    check_manifest_shape(manifest)
    check_eventkit(manifest, state, run_json([args.pb_seed, "dump"]))
    check_notes(manifest, state, run_json(["osascript", "-l", "JavaScript", os.path.join(HERE, "notes.js"), "dump"]))
    check_messages(manifest, state, args.pb_seed)
    check_mail_memos(manifest, state)

    if errors:
        print("verify: FAILED, %d mismatches" % len(errors))
        for e in errors:
            print("- " + e)
        sys.exit(1)
    m = manifest
    print("verify: OK  events=%d (occurrences=%d) reminders=%d contacts=%d notes=%d chats=%d messages=%d injections=%d x3 mail=%s memos=%s" % (
        len(m["calendar"]["events"]),
        sum(len(e.get("occurrences", [0])) for e in m["calendar"]["events"]),
        len(m["reminders"]["items"]), len(m["contacts"]["people"]), len(m["notes"]["notes"]),
        len(m["messages"]["chats"]), len(m["messages"]["messages"]), len(m["injection_corpus"]),
        len(m["mail"]["messages"]) if state.get("mail") else "not seeded", len(m["memos"]["recordings"]) if state.get("memos") else "not seeded"))


if __name__ == "__main__":
    main()
