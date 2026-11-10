"""Pippin, through its public MCP server (`pippin mcp-server`). No special casing."""

from __future__ import annotations

import json
import os

from ._util import named, pick, rec, rows, values

NAME = "pippin"
KIND = "mcp"
def _version() -> str:
    """The binary under test names itself; PIPPIN_LABEL adds what the version string cannot (a branch build)."""
    import subprocess

    try:
        reported = subprocess.run([os.environ.get("PIPPIN_BIN", "pippin"), "--version"], capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        reported = "unknown"
    label = os.environ.get("PIPPIN_LABEL")
    return "%s (%s)" % (reported, label) if label else reported


VERSION = _version()
APPS = ["reminders", "calendar", "contacts", "notes", "messages", "mail", "memos"]


def launch(tools_dir: str) -> list[str]:
    return [os.environ.get("PIPPIN_BIN", "pippin"), "mcp-server"]


def _confirmed(a: dict, mapping: dict) -> dict:
    return dict(named(a, mapping), confirm=True)


OPS = {
    "reminders.lists": lambda a: ("reminders_lists", {}),
    "reminders.list": lambda a: ("reminders_list", named(a, {"list": "list_id", "completed": "include_completed", "limit": "limit"})),
    "reminders.search": lambda a: ("reminders_search", named(a, {"query": "query", "list": "list_id", "limit": "limit"})),
    "reminders.create": lambda a: ("reminders_create", named(a, {"title": "title", "list": "list", "due": "due", "notes": "notes"})),
    "reminders.edit": lambda a: ("reminders_edit", named(a, {"id": "id", "title": "title", "due": "due", "notes": "notes"})),
    "reminders.complete": lambda a: ("reminders_complete", named(a, {"id": "id"})),
    "reminders.delete": lambda a: ("reminders_delete", _confirmed(a, {"id": "id"})),
    "calendar.calendars": lambda a: ("calendar_list", {}),
    "calendar.events": lambda a: ("calendar_events", named(a, {"from": "start", "to": "end", "calendar": "calendar_id", "limit": "limit"})),
    "calendar.search": lambda a: ("calendar_search", named(a, {"query": "query", "from": "start", "to": "end", "limit": "limit"})),
    "calendar.create": lambda a: ("calendar_create", named(a, {"title": "title", "start": "start", "end": "end", "calendar": "calendar_id", "location": "location", "notes": "notes", "allDay": "all_day"})),
    "calendar.edit": lambda a: ("calendar_edit", named(a, {"id": "id", "title": "title", "start": "start", "end": "end", "location": "location", "notes": "notes"})),
    "calendar.delete": lambda a: ("calendar_delete", _confirmed(a, {"id": "id"})),
    "contacts.list": lambda a: ("contacts_list", {}),
    "contacts.search": lambda a: ("contacts_search", named(a, {"query": "query"})),
    "contacts.show": lambda a: ("contacts_show", named(a, {"identifier": "id"})),
    "contacts.create": lambda a: ("contacts_create", named(a, {"first": "first", "last": "last", "email": "email", "phone": "phone", "organization": "organization"})),
    "contacts.edit": lambda a: ("contacts_edit", named(a, {"identifier": "id", "first": "first", "last": "last", "email": "email", "phone": "phone", "organization": "organization"})),
    "contacts.delete": lambda a: ("contacts_delete", _confirmed(a, {"identifier": "id"})),
    "contacts.groups": lambda a: ("contacts_groups", {}),
    "notes.folders": lambda a: ("notes_folders", {}),
    "notes.list": lambda a: ("notes_list", named(a, {"folder": "folder", "limit": "limit"})),
    "notes.search": lambda a: ("notes_search", named(a, {"query": "query", "folder": "folder", "limit": "limit"})),
    "notes.show": lambda a: ("notes_show", named(a, {"id": "id"})),
    "notes.create": lambda a: ("notes_create", named(a, {"title": "title", "body": "body", "folder": "folder"})),
    "notes.edit": lambda a: ("notes_edit", named(a, {"id": "id", "title": "title", "body": "body"})),
    "notes.delete": lambda a: ("notes_delete", _confirmed(a, {"id": "id"})),
    "messages.chats": lambda a: ("messages_list", named(a, {"limit": "limit", "sinceHours": "hours"})),
    "messages.history": lambda a: ("messages_show", named(a, {"conversationId": "chat", "limit": "limit"})),
    "messages.search": lambda a: ("messages_search", named(a, {"query": "query", "limit": "limit", "sinceHours": "hours"})),
    "messages.send": lambda a: ("messages_send", named(a, {"to": "to", "body": "text"})),
    "mail.accounts": lambda a: ("mail_accounts", {}),
    "mail.mailboxes": lambda a: ("mail_mailboxes", named(a, {"account": "account"})),
    "mail.list": lambda a: ("mail_list", named(a, {"account": "account", "mailbox": "mailbox", "limit": "limit"})),
    "mail.search": lambda a: ("mail_search", named(a, {"query": "query", "account": "account", "mailbox": "mailbox", "limit": "limit"})),
    "mail.show": lambda a: ("mail_show", named(a, {"messageId": "id"})),
    "mail.send": lambda a: ("mail_send", _confirmed(a, {"to": "to", "subject": "subject", "body": "body", "from": "account"})),
    "mail.move": lambda a: ("mail_move", named(a, {"messageId": "id", "to": "to_mailbox"})),
    "mail.mark": lambda a: ("mail_mark", named(a, {"messageId": "id", "read": "read"})),
    "mail.attachments": lambda a: ("mail_attachments", named(a, {"messageId": "id"})),
    "memos.list": lambda a: ("memos_list", named(a, {"limit": "limit"})),
    "memos.show": lambda a: ("memos_info", named(a, {"id": "id"})),
    "memos.transcribe": lambda a: ("memos_transcribe", named(a, {"id": "id"})),
    "memos.delete": lambda a: ("memos_delete", _confirmed(a, {"id": "id"})),
}


def _data(text: str, *keys) -> list:
    return rows(json.loads(text).get("data"), *keys)


def _titled(text: str) -> list:
    return [rec(id=r.get("id"), title=pick(r, "title", "name")) for r in _data(text)]


def _reminders(text: str) -> list:
    return [rec(id=r.get("id"), title=r.get("title"), due=r.get("dueDate"), completed=r.get("isCompleted"), list=r.get("listTitle"), notes=r.get("notes")) for r in _data(text)]


def _events(text: str) -> list:
    return [rec(id=r.get("id"), title=r.get("title"), start=r.get("startDate"), end=r.get("endDate"), calendar=r.get("calendarTitle"), all_day=r.get("isAllDay"), location=r.get("location"), notes=r.get("notes")) for r in _data(text)]


def _contacts(text: str) -> list:
    return [rec(id=r.get("id"), title=r.get("fullName"), first=r.get("givenName"), last=r.get("familyName"), emails=values(r.get("emails")), phones=values(r.get("phones"))) for r in _data(text)]


def _notes(text: str) -> list:
    return [rec(id=r.get("id"), title=r.get("title"), folder=r.get("folder"), modified=r.get("modifiedAt"), body=r.get("plainText")) for r in _data(text)]


def _chats(text: str) -> list:
    return [rec(id=r.get("id"), title=r.get("display_name"), participants=[p.get("handle") for p in r.get("participants", [])], date=r.get("last_message_at"), unread=r.get("unread_count")) for r in _data(text)]


def _messages(text: str) -> list:
    return [rec(id=r.get("id"), chat=r.get("conversation_id"), sender=r.get("from_handle"), text=r.get("text"), date=r.get("date"), is_from_me=r.get("is_from_me")) for r in _data(text, "messages", "matches")]


def _mail(text: str) -> list:
    return [rec(id=r.get("id"), title=r.get("subject"), sender=r.get("from"), date=r.get("date"), read=r.get("read"), mailbox=r.get("mailbox"), account=r.get("account"), body=r.get("body")) for r in _data(text)]


def _accounts(text: str) -> list:
    return [rec(id=r.get("name"), title=r.get("name"), email=r.get("email")) for r in _data(text)]


def _mailboxes(text: str) -> list:
    return [rec(id=r.get("name"), title=r.get("name"), account=r.get("account"), unread=r.get("unreadCount")) for r in _data(text)]


def _attachments(text: str) -> list:
    return [rec(title=r.get("name"), size=r.get("size"), mime=r.get("mimeType")) for r in _data(text, "attachments")]


def _memos(text: str) -> list:
    return [rec(id=r.get("id"), title=r.get("title"), date=pick(r, "createdAt", "created_at"), duration=pick(r, "durationSeconds", "duration_seconds"), text=pick(r, "transcription", "text")) for r in _data(text)]


def _written(text: str) -> list:
    """Create, edit, complete, delete: the affected record from data.details."""
    out = []
    for r in _data(text):
        d = r.get("details") or r
        out.append(rec(id=d.get("id"), title=pick(d, "title", "fullName")))
    return out


PARSE = {
    "reminders.lists": _titled,
    "reminders.list": _reminders,
    "reminders.search": _reminders,
    "calendar.calendars": _titled,
    "calendar.events": _events,
    "calendar.search": _events,
    "contacts.list": _contacts,
    "contacts.search": _contacts,
    "contacts.show": _contacts,
    "contacts.groups": _titled,
    "notes.folders": _titled,
    "notes.list": _notes,
    "notes.search": _notes,
    "notes.show": _notes,
    "messages.chats": _chats,
    "messages.history": _messages,
    "messages.search": _messages,
    "mail.accounts": _accounts,
    "mail.mailboxes": _mailboxes,
    "mail.list": _mail,
    "mail.search": _mail,
    "mail.show": _mail,
    "mail.attachments": _attachments,
    "memos.list": _memos,
    "memos.show": _memos,
    "memos.transcribe": _memos,
}
for _op in ("reminders.create", "reminders.edit", "reminders.complete", "reminders.delete", "calendar.create", "calendar.edit", "calendar.delete",
            "contacts.create", "contacts.edit", "contacts.delete", "notes.create", "notes.edit", "notes.delete"):
    PARSE[_op] = _written

NOTES = {
    "*": "Exercised in the VM: reminders.lists/list/search, calendar.calendars/events/search, contacts.list/search/show/groups, notes.folders/list/search/show, messages.chats/history/search. Pippin is its own responsible process for privacy permissions, so grants belong to the pippin binary, not to the launching app.",
    "reminders.list": "The list filter takes a list id (list_id), not a name.",
    "reminders.create": "untested through the adapter (the seed call used the same tool directly).",
    "calendar.events": "The calendar filter takes a calendar id (calendar_id).",
    "calendar.create": "Takes a calendar id (calendar_id); a calendar name is rejected with calendar_not_found.",
    "reminders.delete": "confirm=true is a required argument; untested through the adapter.",
    "calendar.delete": "confirm=true is a required argument; untested through the adapter.",
    "contacts.delete": "confirm=true is a required argument; untested through the adapter.",
    "notes.delete": "confirm=true is a required argument; untested through the adapter.",
    "memos.delete": "confirm=true is a required argument; untested.",
    "mail.send": "The adapter passes confirm=true (a real send); without it the tool returns a preview and sends nothing. untested.",
    "messages.send": "untested.",
    "messages.chats": "The default field set returned no participants in the VM (empty list).",
    "messages.history": "The chat argument is the conversation id from messages.chats. sender is the tool's from_handle as given.",
    "mail.accounts": "untested: no Mail account in the VM (the call failed with 'Mail not ready: no accounts visible').",
    "mail.mailboxes": "untested: no Mail account in the VM.",
    "mail.list": "untested: no Mail account in the VM.",
    "mail.search": "untested: no Mail account in the VM.",
    "mail.show": "untested: no Mail account in the VM. The id is a compound account||mailbox||numericId.",
    "mail.move": "untested.",
    "mail.mark": "untested.",
    "mail.attachments": "untested.",
    "memos.list": "untested: no Voice Memos database in the VM (database_not_found).",
    "memos.show": "untested: no Voice Memos database in the VM.",
    "memos.transcribe": "untested; needs mlx-audio.",
}
