"""sweetrb/apple-mail-mcp, MCP server (npm apple-mail-mcp)."""

from __future__ import annotations

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


def _accounts(text: str) -> list:
    return [rec(id=pick(r, "id", "name"), title=r.get("name"), email=pick(r, "email", "emailAddresses")) for r in _mirror(text, "accounts")]


def _mailboxes(text: str) -> list:
    return [rec(id=pick(r, "id", "name"), title=r.get("name"), account=r.get("account"), unread=pick(r, "unreadCount", "unread")) for r in _mirror(text, "mailboxes")]


def _mail(text: str) -> list:
    return [rec(id=r.get("id"), title=r.get("subject"), sender=pick(r, "sender", "from"), date=pick(r, "date", "dateReceived", "dateSent"), read=pick(r, "isRead", "read"), mailbox=r.get("mailbox"), account=r.get("account"), body=r.get("body")) for r in _mirror(text, "messages")]


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
    "*": "untested on real data: the VM has no Mail account, so every parser here is written from the tool's published output schemas and from the sibling apple-notes-mcp reply format (prose plus a 'structuredContent: ' JSON mirror). With no data the tool answers in prose only and the parsers return an empty list. Needs Automation permission for Mail.",
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
