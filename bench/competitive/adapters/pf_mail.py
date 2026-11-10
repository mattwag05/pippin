"""patrickfreyer/apple-mail-mcp, MCP server (PyPI mcp-apple-mail)."""

from __future__ import annotations

from ._util import first_json, named, pick, rec, rows

NAME = "pf-mail"
KIND = "mcp"
VERSION = "3.3.0"
APPS = ["mail"]


def launch(tools_dir: str) -> list[str]:
    return [tools_dir + "/pf-mail/venv/bin/mcp-apple-mail"]


def _json(a: dict, mapping: dict) -> dict:
    return dict(named(a, mapping), output_format="json")


def _ids(a: dict, mapping: dict) -> dict:
    return dict(named(a, mapping), message_ids=[a["id"]])


OPS = {
    "mail.accounts": lambda a: ("list_accounts", {}),
    "mail.mailboxes": lambda a: ("list_mailboxes", named(a, {"account": "account"})),
    "mail.list": lambda a: ("list_inbox_emails", _json(a, {"account": "account", "max_emails": "limit"})),
    "mail.search": lambda a: ("search_emails", _json(a, {"subject_keyword": "query", "account": "account", "mailbox": "mailbox", "limit": "limit"})),
    "mail.show": lambda a: ("read_email", _json(a, {"message_id": "id", "account": "account", "mailbox": "mailbox"})),
    "mail.send": lambda a: ("compose_email", dict(named(a, {"account": "account", "subject": "subject", "body": "body"}), to=", ".join(a["to"]))),
    "mail.move": lambda a: ("move_email", _ids(a, {"account": "account", "to_mailbox": "to_mailbox"})),
    "mail.mark": lambda a: ("update_email_status", dict(_ids(a, {"account": "account"}), action="mark_read" if a.get("read", True) else "mark_unread")),
    "mail.attachments": lambda a: ("list_email_attachments", named(a, {"account": "account", "message_id": "id", "mailbox": "mailbox"})),
}


def _mail(text: str) -> list:
    out = []
    for r in rows(first_json(text) or [], "items", "emails", "email"):
        out.append(rec(id=pick(r, "id", "message_id"), title=r.get("subject"), sender=pick(r, "sender", "from"), date=pick(r, "date", "date_received", "date_sent"),
                       read=pick(r, "is_read", "read"), mailbox=r.get("mailbox"), account=r.get("account"), body=pick(r, "body", "content")))
    return out


PARSE = {"mail.list": _mail, "mail.search": _mail, "mail.show": _mail}

NOTES = {
    "*": "untested on real data: the VM has no Mail account. Record field names are assumed and read tolerantly. Every write tool requires the account name. serverInfo reports the FastMCP version (4.1.7), not the package version (3.3.0).",
    "mail.accounts": "Plain text output only, so no parser. Ran in the VM: empty reply with no accounts.",
    "mail.mailboxes": "Plain text output only, so no parser. Ran in the VM: header line only.",
    "mail.list": "Inbox only (list_inbox_emails has no mailbox argument). Ran in the VM with output_format=json: '[]'.",
    "mail.search": "The query is passed as subject_keyword; body search is a separate, slower argument (body_text). Ran in the VM with output_format=json: an envelope with an empty items list.",
    "mail.show": "untested. Needs account and the numeric id from mail.search.",
    "mail.send": "untested. compose_email defaults to mode=send (immediate); 'draft' and 'open' are the review modes. Recipients are one comma-separated string. Plain text reply, no parser.",
    "mail.move": "untested. Called with message_ids=[id]. Plain text reply, no parser.",
    "mail.mark": "untested. Called with message_ids=[id] and action mark_read or mark_unread. Plain text reply, no parser.",
    "mail.attachments": "untested. Plain text reply, no parser.",
}
