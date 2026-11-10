"""Imports every adapter and asserts the declarative interface.

Run: python3 bench/competitive/adapters/_selfcheck.py
"""

from __future__ import annotations

import importlib
import os
import sys

CANONICAL_OPS = """
reminders.lists reminders.list reminders.search reminders.create reminders.edit reminders.complete reminders.delete
calendar.calendars calendar.events calendar.search calendar.create calendar.edit calendar.delete
contacts.list contacts.search contacts.show contacts.create contacts.edit contacts.delete contacts.groups
notes.folders notes.list notes.search notes.show notes.create notes.edit notes.delete
messages.chats messages.history messages.search messages.send
mail.accounts mail.mailboxes mail.list mail.search mail.show mail.send mail.move mail.mark mail.attachments
memos.list memos.show memos.transcribe memos.delete
""".split()

ADAPTERS = ["pippin", "imcp", "imsg", "remindctl", "reminders_cli", "memo", "sweetrb_mail", "pf_mail", "sweetrb_notes", "apple_events", "mac_messages", "apple_pim"]

# Enough canonical arguments to call every builder once.
SAMPLE = {
    "id": "X1", "list": "L", "list_id": "L1", "title": "T", "due": "2026-12-01T10:00:00Z", "notes": "N", "query": "Q", "limit": 5,
    "calendar": "C", "calendar_id": "C1", "start": "2026-12-01T15:00:00Z", "end": "2026-12-01T16:00:00Z", "location": "Room",
    "first": "F", "last": "L", "email": "a@example.invalid", "phone": "+15555550100", "organization": "O",
    "folder": "Notes", "body": "B", "content_hash": "sha256:0", "chat": "1", "to": ["a@example.invalid"], "text": "hi", "hours": 24,
    "account": "A", "mailbox": "INBOX", "to_mailbox": "Archive", "subject": "S", "read": True,
}


def check(name: str) -> int:
    m = importlib.import_module("adapters." + name)
    assert isinstance(m.NAME, str) and m.NAME, name
    assert m.KIND in ("mcp", "cli"), name
    assert isinstance(m.VERSION, str) and m.VERSION, name
    assert isinstance(m.APPS, list) and all(isinstance(a, str) for a in m.APPS), name
    cmd = m.launch("/tools")
    assert isinstance(cmd, list) and cmd and all(isinstance(c, str) for c in cmd), name
    for attr in ("OPS", "PARSE", "NOTES"):
        assert isinstance(getattr(m, attr), dict), (name, attr)
    assert "*" in m.NOTES or m.NOTES == {}, name
    for op, build in m.OPS.items():
        assert op in CANONICAL_OPS, (name, op)
        assert op.split(".")[0] in m.APPS, (name, op)
        args = dict(SAMPLE, to="+15555550100") if op == "messages.send" else SAMPLE
        built = build(args)
        if m.KIND == "mcp":
            assert isinstance(built, tuple) and len(built) == 2 and isinstance(built[0], str) and isinstance(built[1], dict), (name, op, built)
        else:
            assert isinstance(built, list) and all(isinstance(x, str) for x in built), (name, op, built)
    for op, parse in m.PARSE.items():
        assert op in m.OPS and callable(parse), (name, op)
    for op, note in m.NOTES.items():
        assert (op == "*" or op in CANONICAL_OPS) and isinstance(note, str), (name, op)
    return len(m.OPS)


if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    assert len(CANONICAL_OPS) == len(set(CANONICAL_OPS)) == 44
    for adapter in ADAPTERS:
        print("%-14s ok, %d ops" % (adapter, check(adapter)))
    print("adapter self-check ok")
