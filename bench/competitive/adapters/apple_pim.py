"""omarshahine/apple-pim, through its MCP server (node mcp-server/dist/server.js)."""

from __future__ import annotations

import re

from ._util import first_json, named, pick, rec, rows, values

NAME = "apple-pim"
KIND = "mcp"
VERSION = "3.19.2"
APPS = ["reminders", "calendar", "contacts", "mail"]

# The server wraps every third-party string in "[UNTRUSTED_<DOMAIN>_DATA_<nonce>] ... [/...]".
_WRAP = re.compile(r"\[/?UNTRUSTED_[A-Z-]+_DATA_[A-Z0-9]+\]")


def launch(tools_dir: str) -> list[str]:
    return ["node", tools_dir + "/apple-pim/src/mcp-server/dist/server.js"]


def _call(tool: str, action: str, mapping: dict, **fixed):
    return lambda a: (tool, dict(named(a, mapping), action=action, **fixed))


OPS = {
    "reminders.lists": _call("reminder", "lists", {}),
    "reminders.list": _call("reminder", "items", {"list": "list", "completed": "include_completed", "limit": "limit"}),
    "reminders.search": _call("reminder", "search", {"query": "query", "list": "list", "limit": "limit"}),
    "reminders.create": _call("reminder", "create", {"title": "title", "list": "list", "due": "due", "notes": "notes"}),
    "reminders.edit": _call("reminder", "update", {"id": "id", "title": "title", "due": "due", "notes": "notes"}),
    "reminders.complete": _call("reminder", "complete", {"id": "id"}),
    "reminders.delete": _call("reminder", "delete", {"id": "id"}),
    "calendar.calendars": _call("calendar", "list", {}),
    "calendar.events": _call("calendar", "events", {"from": "start", "to": "end", "calendar": "calendar", "limit": "limit"}),
    "calendar.search": _call("calendar", "search", {"query": "query", "from": "start", "to": "end", "limit": "limit"}),
    "calendar.create": _call("calendar", "create", {"title": "title", "start": "start", "end": "end", "calendar": "calendar", "location": "location", "notes": "notes", "allDay": "all_day"}),
    "calendar.edit": _call("calendar", "update", {"id": "id", "title": "title", "start": "start", "end": "end", "location": "location", "notes": "notes"}),
    "calendar.delete": _call("calendar", "delete", {"id": "id"}),
    "contacts.list": _call("contact", "list", {"limit": "limit"}),
    "contacts.search": _call("contact", "search", {"query": "query", "limit": "limit"}),
    "contacts.show": _call("contact", "get", {"id": "id"}),
    "contacts.create": _call("contact", "create", {"firstName": "first", "lastName": "last", "email": "email", "phone": "phone", "organization": "organization"}),
    "contacts.edit": _call("contact", "update", {"id": "id", "firstName": "first", "lastName": "last", "email": "email", "phone": "phone", "organization": "organization"}),
    "contacts.delete": _call("contact", "delete", {"id": "id"}),
    "contacts.groups": _call("contact", "groups", {}),
    "mail.accounts": _call("mail", "accounts", {}),
    "mail.mailboxes": _call("mail", "mailboxes", {"account": "account"}),
    "mail.list": _call("mail", "messages", {"account": "account", "mailbox": "mailbox", "limit": "limit"}),
    "mail.search": _call("mail", "search", {"query": "query", "account": "account", "mailbox": "mailbox", "limit": "limit"}),
    "mail.show": _call("mail", "get", {"id": "id", "account": "account", "mailbox": "mailbox"}),
    "mail.send": _call("mail", "send", {"to": "to", "subject": "subject", "body": "body", "from": "account"}),
    "mail.move": _call("mail", "move", {"id": "id", "toMailbox": "to_mailbox", "account": "account"}),
    "mail.mark": _call("mail", "update", {"id": "id", "read": "read", "account": "account"}),
}


def _clean(value):
    if isinstance(value, str):
        return _WRAP.sub("", value).strip()
    if isinstance(value, list):
        return [_clean(v) for v in value]
    if isinstance(value, dict):
        return {k: _clean(v) for k, v in value.items()}
    return value


def _rows(text: str, *keys) -> list:
    return rows(_clean(first_json(text) or []), *keys)


def _titled(text: str) -> list:
    return [rec(id=pick(r, "id", "name"), title=pick(r, "title", "name")) for r in _rows(text, "lists", "calendars", "groups")]


def _reminders(text: str) -> list:
    return [rec(id=r.get("id"), title=r.get("title"), due=r.get("dueDate"), completed=r.get("isCompleted"), list=r.get("list"), notes=r.get("notes")) for r in _rows(text, "reminders", "reminder")]


def _events(text: str) -> list:
    return [rec(id=r.get("id"), title=r.get("title"), start=r.get("startDate"), end=r.get("endDate"), calendar=r.get("calendar"), all_day=r.get("isAllDay"),
                location=r.get("location"), notes=r.get("notes")) for r in _rows(text, "events", "event")]


def _contacts(text: str) -> list:
    return [rec(id=r.get("id"), title=r.get("fullName"), first=r.get("givenName"), last=r.get("familyName"), emails=values(r.get("emails")), phones=values(r.get("phones"))) for r in _rows(text, "contacts", "contact")]


def _accounts(text: str) -> list:
    return [rec(id=pick(r, "id", "name"), title=r.get("name"), email=pick(r, "email", "emails")) for r in _rows(text, "accounts")]


def _mailboxes(text: str) -> list:
    return [rec(id=r.get("name"), title=r.get("name"), account=r.get("account"), unread=r.get("unreadCount")) for r in _rows(text, "mailboxes")]


def _mail(text: str) -> list:
    return [rec(id=pick(r, "id", "messageId"), title=r.get("subject"), sender=pick(r, "sender", "from"), date=pick(r, "dateReceived", "date", "dateSent"), read=pick(r, "isRead", "read"),
                mailbox=r.get("mailbox"), account=r.get("account"), body=pick(r, "content", "body")) for r in _rows(text, "messages", "message")]


PARSE = {
    "reminders.lists": _titled,
    "reminders.list": _reminders,
    "reminders.search": _reminders,
    "reminders.create": _reminders,
    "reminders.edit": _reminders,
    "reminders.complete": _reminders,
    "calendar.calendars": _titled,
    "calendar.events": _events,
    "calendar.search": _events,
    "calendar.create": _events,
    "calendar.edit": _events,
    "contacts.list": _contacts,
    "contacts.search": _contacts,
    "contacts.show": _contacts,
    "contacts.create": _contacts,
    "contacts.edit": _contacts,
    "contacts.groups": _titled,
    "mail.accounts": _accounts,
    "mail.mailboxes": _mailboxes,
    "mail.list": _mail,
    "mail.search": _mail,
    "mail.show": _mail,
}

NOTES = {
    "*": "The text reply is a fixed warning paragraph followed by JSON. Third-party strings are wrapped in '[UNTRUSTED_<DOMAIN>_DATA_<nonce>] ... [/...]' markers; the parsers strip the markers so values can be compared. Built from source (ad hoc signed CLIs in swift/.build/release). Exercised in the VM: reminders.lists/list/search, calendar.calendars/events/search, contacts.list/search/show/groups, mail.accounts, mail.mailboxes.",
    "reminders.list": "Reminder dueDate is local wall-clock text ('YYYY-MM-DD HH:mm') with no zone.",
    "contacts.list": "List and search rows carry emails and phones as plain strings; contacts.show carries {label, value}. Both are normalized to strings.",
    "reminders.create": "untested: reply shape assumed.",
    "reminders.edit": "untested.",
    "reminders.complete": "untested.",
    "reminders.delete": "untested. Not parsed.",
    "calendar.create": "untested. calendar accepts a name or an id.",
    "calendar.edit": "untested.",
    "calendar.delete": "untested. Not parsed.",
    "contacts.create": "untested.",
    "contacts.edit": "untested.",
    "contacts.delete": "untested. Not parsed.",
    "mail.accounts": "Ran in the VM with no Mail account: empty list. Parser untested on real rows.",
    "mail.mailboxes": "Ran in the VM (direct SQLite read): one system mailbox row.",
    "mail.list": "untested on real data: with no account the call fails with 'Mailbox not found: INBOX'. Field names assumed.",
    "mail.search": "untested. Field names assumed.",
    "mail.show": "untested. The id is the RFC 2822 message id.",
    "mail.send": "untested. Not parsed. The account argument is passed as the sender address (from). A dryRun argument exists as the preview path.",
    "mail.move": "untested. Not parsed.",
    "mail.mark": "untested. Implemented as update with read=true or false. Not parsed.",
    "mail.attachments": "Not mapped: the tool offers save_attachment (writes a file) and attachment metadata inside mail.show, but no listing call.",
}
