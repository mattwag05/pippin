"""sweetrb/apple-mail-mcp, MCP server (npm apple-mail-mcp)."""

from __future__ import annotations

import re

from ._util import first_json, named, pick, rec, rows

NAME = "sweetrb-mail"
KIND = "mcp"
VERSION = "2.20.55"
APPS = ["mail"]

MARK = "structuredContent: "


def launch(tools_dir: str) -> list[str]:
    return ["node", tools_dir + "/sweetrb-mail/node_modules/apple-mail-mcp/build/index.js"]


OPS = {
    "mail.accounts": lambda a: ("list-accounts", {}),
    "mail.mailboxes": lambda a: ("list-mailboxes", named(a, {"account": "account"})),
    "mail.list": lambda a: ("list-messages", named(a, {"account": "account", "mailbox": "mailbox", "limit": "limit"})),
    "mail.search": lambda a: ("search-messages", named(a, {"query": "query", "account": "account", "mailbox": "mailbox", "limit": "limit"})),
    "mail.show": lambda a: ("get-message", named(a, {"id": "id", "account": "account", "mailbox": "mailbox"})),
    "mail.send": lambda a: ("send-email", named(a, {"to": "to", "subject": "subject", "body": "body", "account": "account"})),
    "mail.move": lambda a: ("move-message", named(a, {"id": "id", "mailbox": "to_mailbox", "account": "account"})),
    "mail.mark": lambda a: ("mark-as-read" if a.get("read", True) else "mark-as-unread", named(a, {"id": "id"})),
    "mail.attachments": lambda a: ("list-attachments", named(a, {"id": "id"})),
}


def _mirror(text: str, *keys) -> list:
    return rows(first_json(text, MARK) or [], *keys)


# 2.20.55 answers in prose only, one "  - " line per item (seen on the Amendment 4 data, 2026-11-10).
# The JSON mirror is tried first in case a release adds one.
ITEM = re.compile(r"^\s*-\s+(.*?)\s*$", re.M)
MESSAGE = re.compile(r'^\s*-\s*ID:\s*(\S+)\s*\|\s*(.*?)\s*\|\s*(.*)\s+\(from:\s*(.*?)\)\s*(\[unread\])?\s*\|\s*in\s+"(.*?)"\s+\((.*?)\)\s*$', re.M)


def _accounts(text: str) -> list:
    mirrored = _mirror(text, "accounts")
    if mirrored:
        return [rec(id=pick(r, "id", "name"), title=r.get("name"), email=pick(r, "email", "emailAddresses")) for r in mirrored]
    return [rec(id=name, title=name) for name in ITEM.findall(text)]


def _mailboxes(text: str) -> list:
    mirrored = _mirror(text, "mailboxes")
    if mirrored:
        return [rec(id=pick(r, "id", "name"), title=r.get("name"), account=r.get("account"), unread=pick(r, "unreadCount", "unread")) for r in mirrored]
    out = []
    for line in ITEM.findall(text):
        m = re.match(r"(.*?)\s+\((\d+) unread\)$", line)
        out.append(rec(id=m.group(1) if m else line, title=m.group(1) if m else line, unread=int(m.group(2)) if m else None))
    return out


def _mail(text: str) -> list:
    mirrored = _mirror(text, "messages")
    if mirrored:
        return [rec(id=r.get("id"), title=r.get("subject"), sender=pick(r, "sender", "from"), date=pick(r, "date", "dateReceived", "dateSent"), read=pick(r, "isRead", "read"), mailbox=r.get("mailbox"), account=r.get("account"), body=r.get("body")) for r in mirrored]
    return [rec(id=m[0], date=m[1], title=m[2], sender=m[3], read=not m[4], mailbox=m[5], account=m[6]) for m in MESSAGE.findall(text)]


def _attachments(text: str) -> list:
    return [rec(title=r.get("name"), size=r.get("size"), mime=pick(r, "mimeType", "mime")) for r in _mirror(text, "attachments")]


PARSE = {
    "mail.accounts": _accounts,
    "mail.mailboxes": _mailboxes,
    "mail.list": _mail,
    "mail.search": _mail,
    "mail.show": _mail,
    "mail.attachments": _attachments,
}

NOTES = {
    "*": "Parsers first written without data from the tool's published output schemas; on the Amendment 4 mailbox (2026-11-10) 2.20.55 answered in prose only, so prose parsers were added before the scored run. Needs Automation permission for Mail.",
    "mail.accounts": "Ran in the VM: 'No Mail accounts found'.",
    "mail.mailboxes": "Ran in the VM: failed with 'Can't get account \"iCloud\"' when no account exists.",
    "mail.list": "Ran in the VM: 'No messages found'.",
    "mail.search": "Ran in the VM: 'No messages found matching criteria'.",
    "mail.show": "untested.",
    "mail.send": "untested. Sends immediately; the tool's review path is a separate create-draft tool.",
    "mail.move": "untested.",
    "mail.mark": "untested. Two tools: mark-as-read and mark-as-unread, chosen by the read argument.",
    "mail.attachments": "untested.",
}
