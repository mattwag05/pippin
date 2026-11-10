#!/usr/bin/env python3
"""Build the synthetic Messages store from manifest.json and install it. Run ONLY inside the disposable benchmark VM.

  make_chatdb.py install <manifest.json> [--db PATH] [--pb-seed PATH]   prints state JSON
  make_chatdb.py restore [--db PATH]                                    puts chat.db.orig back

The schema (tables, indexes, triggers) is copied from the real, empty chat.db that Messages created on this
macOS version, kept beside it as chat.db.orig. Nothing here signs in to iMessage or sends anything.
Standard library only, Python 3.9.
"""
import argparse
import json
import os
import sqlite3
import subprocess
import sys
import uuid

DEFAULT_DB = os.path.expanduser("~/Library/Messages/chat.db")
DEFAULT_PB_SEED = os.path.expanduser("~/bench/bin/pb-seed")
SYNTHETIC_KEY = "PippinBenchSynthetic"
ACCOUNT = "E:pippinbench@example.invalid"
ACCOUNT_GUID = "5E5E5E5E-0000-4000-8000-00000000BE4C"
OBJECT_REPLACEMENT = "￼"


def is_synthetic(path):
    con = sqlite3.connect("file:%s?mode=ro" % path, uri=True)
    try:
        return con.execute("SELECT count(*) FROM _SqliteDatabaseProperties WHERE key = ?", (SYNTHETIC_KEY,)).fetchone()[0] > 0
    except sqlite3.Error:
        return False
    finally:
        con.close()


def stop_messages():
    # Nothing is signed in, so these only hold the file open; they restart on demand.
    subprocess.run(["killall", "Messages", "imagent", "IMDPersistenceAgent"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def swap_in(new, db):
    stop_messages()
    for suffix in ("", "-wal", "-shm"):
        if os.path.exists(db + suffix):
            os.remove(db + suffix)
    os.replace(new, db)


def typedstreams(pb_seed, texts):
    out = subprocess.run([pb_seed, "typedstream"], input=json.dumps(texts).encode(), stdout=subprocess.PIPE, check=True).stdout
    return [bytes.fromhex(h) for h in json.loads(out)]


def insert(con, table, row):
    cols = {r[1] for r in con.execute("PRAGMA table_info(%s)" % table)}
    row = {k: v for k, v in row.items() if k in cols}  # tolerate columns missing on another macOS version
    con.execute("INSERT INTO %s (%s) VALUES (%s)" % (table, ", ".join(row), ", ".join("?" * len(row))), list(row.values()))


def install(args):
    db, orig = args.db, args.db + ".orig"
    spec = json.load(open(args.manifest, encoding="utf-8"))["messages"]
    if not os.path.exists(orig):
        if not os.path.exists(db):
            sys.exit("make_chatdb: %s does not exist; launch Messages once so it creates the store" % db)
        if is_synthetic(db):
            sys.exit("make_chatdb: %s is already synthetic and chat.db.orig is missing; refusing to lose the original" % db)
        src, dst = sqlite3.connect("file:%s?mode=ro" % db, uri=True), sqlite3.connect(orig)
        src.backup(dst)
        # A WAL store with no -shm file cannot be opened read-only, so both copies use a rollback journal.
        dst.execute("PRAGMA journal_mode = DELETE")
        src.close()
        dst.close()
        for suffix in ("-wal", "-shm"):
            if os.path.exists(orig + suffix):
                os.remove(orig + suffix)

    new = db + ".pippinbench-new"
    for suffix in ("", "-wal", "-shm"):
        if os.path.exists(new + suffix):
            os.remove(new + suffix)
    src = sqlite3.connect("file:%s?mode=ro" % orig, uri=True)
    schema = src.execute("SELECT type, sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'").fetchall()
    props = src.execute("SELECT key, value FROM _SqliteDatabaseProperties").fetchall()
    user_version = src.execute("PRAGMA user_version").fetchone()[0]
    src.close()

    con = sqlite3.connect(new)
    for kind in ("table", "index"):
        for t, sql in schema:
            if t == kind:
                con.execute(sql)
    con.executemany("INSERT INTO _SqliteDatabaseProperties (key, value) VALUES (?, ?)", props)
    con.execute("INSERT INTO _SqliteDatabaseProperties (key, value) VALUES (?, '1')", (SYNTHETIC_KEY,))
    con.execute("PRAGMA user_version = %d" % user_version)

    handle_rowid = {h["id"]: h["rowid"] for h in spec["handles"]}
    for h in spec["handles"]:
        insert(con, "handle", {"ROWID": h["rowid"], "id": h["id"], "country": "us", "service": "iMessage",
                               "uncanonicalized_id": h["id"]})
    chats = {c["key"]: c for c in spec["chats"]}
    msgs = spec["messages"]
    by_key = {m["key"]: m for m in msgs}
    for c in spec["chats"]:
        group = c["style"] == "group"
        read_dates = [m["date_ns"] for m in msgs if m["chat"] == c["key"] and not m["is_from_me"] and m["is_read"]]
        insert(con, "chat", {
            "ROWID": c["rowid"], "guid": c["guid"], "style": 43 if group else 45, "state": 3, "account_id": ACCOUNT_GUID,
            "chat_identifier": c["chat_identifier"], "service_name": "iMessage",
            "room_name": c["chat_identifier"] if group else None, "account_login": ACCOUNT, "is_archived": 0,
            "last_addressed_handle": spec["self_handle"], "display_name": c["display_name"],
            "group_id": str(uuid.uuid5(uuid.NAMESPACE_URL, c["guid"])).upper(), "is_filtered": 0, "successful_query": 1,
            "last_read_message_timestamp": max(read_dates) if read_dates else 0,
        })
        insert(con, "chat_service", {"service": "iMessage", "chat": c["rowid"]})
        for p in c["participants"]:
            insert(con, "chat_handle_join", {"chat_id": c["rowid"], "handle_id": handle_rowid[p]})

    def stored_text(m):
        return OBJECT_REPLACEMENT if m["kind"] == "attachment" else m["text"]

    with_blob = [m for m in msgs if m["text_storage"] in ("both", "attributedBody", "placeholder")]
    blobs = dict(zip((m["key"] for m in with_blob), typedstreams(args.pb_seed, [stored_text(m) for m in with_blob])))
    attachment_rowid = 0
    for m in msgs:
        c = chats[m["chat"]]
        group = c["style"] == "group"
        if m["is_from_me"]:
            handle = 0 if group else handle_rowid[c["participants"][0]]
        else:
            handle = handle_rowid[m["sender"]]
        row = {
            "ROWID": m["rowid"], "guid": m["guid"],
            "text": stored_text(m) if m["text_storage"] in ("both", "text", "placeholder") else None,
            "attributedBody": blobs.get(m["key"]), "handle_id": handle, "service": "iMessage", "account": ACCOUNT,
            "account_guid": ACCOUNT_GUID, "date": m["date_ns"],
            "date_read": m["date_ns"] + 60 * 10**9 if (m["is_read"] and not m["is_from_me"]) else 0,
            "date_delivered": m["date_ns"] + 10**9 if m["is_from_me"] else 0,
            "is_delivered": 1, "is_finished": 1, "is_from_me": int(m["is_from_me"]), "is_read": int(m["is_read"]),
            "is_sent": int(m["is_from_me"]), "cache_roomnames": c["chat_identifier"] if group else None,
            "destination_caller_id": spec["self_handle"], "part_count": 1, "item_type": 0,
        }
        if m["kind"] == "tapback":
            r = m["reaction"]
            target = by_key[r["target"]]
            row.update({"associated_message_guid": "p:0/" + r["target_guid"], "associated_message_type": r["type"],
                        "associated_message_range_location": 0, "associated_message_range_length": len(target["text"])})
        elif m["kind"] == "attachment":
            row["cache_has_attachments"] = 1
        elif m["kind"] == "retracted":
            row.update({"date_retracted": m["date_retracted_ns"], "date_edited": m["date_retracted_ns"], "is_empty": 1})
        elif m["kind"] == "group_event":
            row.update({"item_type": 2, "group_title": m["group_title"], "group_action_type": 0})
        insert(con, "message", row)
        insert(con, "chat_message_join", {"chat_id": c["rowid"], "message_id": m["rowid"], "message_date": m["date_ns"]})
        for a in m.get("attachments", []):
            attachment_rowid += 1
            insert(con, "attachment", {
                "ROWID": attachment_rowid, "guid": a["guid"], "original_guid": a["guid"], "created_date": m["date_ns"] // 10**9,
                "filename": a["filename"], "uti": a["uti"], "mime_type": a["mime_type"], "transfer_state": 5,
                "is_outgoing": 0, "transfer_name": a["transfer_name"], "total_bytes": a["total_bytes"]})
            insert(con, "message_attachment_join", {"message_id": m["rowid"], "attachment_id": attachment_rowid})
    # Triggers go in last: several call functions that only Messages registers, so they cannot fire during the load.
    for t, sql in schema:
        if t == "trigger":
            con.execute(sql)
    con.commit()
    con.close()
    swap_in(new, db)
    json.dump({"messages": {"db": db, "orig": orig, "message_count": len(msgs),
                            "chats": {c["key"]: {"id": c["guid"]} for c in spec["chats"]}}}, sys.stdout, indent=1)
    print()


def restore(args):
    db, orig = args.db, args.db + ".orig"
    if not os.path.exists(orig):
        sys.exit("make_chatdb: %s is missing; nothing to restore" % orig)
    if os.path.exists(db) and not is_synthetic(db):
        sys.exit("make_chatdb: %s is not the synthetic store; refusing to replace it" % db)
    swap_in(orig, db)
    if is_synthetic(db):
        sys.exit("make_chatdb: restore failed, the synthetic store is still installed")
    print(json.dumps({"restored": db}))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["install", "restore"])
    ap.add_argument("manifest", nargs="?")
    ap.add_argument("--db", default=DEFAULT_DB)
    ap.add_argument("--pb-seed", default=DEFAULT_PB_SEED)
    args = ap.parse_args()
    if args.mode == "install":
        if not args.manifest:
            ap.error("install needs the manifest path")
        install(args)
    else:
        restore(args)


if __name__ == "__main__":
    main()
