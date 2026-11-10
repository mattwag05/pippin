"""openclaw/remindctl, CLI with JSON output (--json)."""

from __future__ import annotations

import json

from ._util import flags, rec, rows

NAME = "remindctl"
KIND = "cli"
VERSION = "0.3.9"
APPS = ["reminders"]


def launch(tools_dir: str) -> list[str]:
    return [tools_dir + "/remindctl/remindctl"]


def _list(a: dict) -> list:
    target = ["--list-id", a["list_id"]] if a.get("list_id") else [a["list"]]
    return ["list"] + target + ["--json"]


OPS = {
    "reminders.lists": lambda a: ["list", "--json"],
    "reminders.list": _list,
    "reminders.search": lambda a: ["search", a["query"]] + flags(a, {"--list": "list"}) + ["--json"],
    "reminders.create": lambda a: ["add", "--title", a["title"]] + flags(a, {"--list": "list", "--due": "due", "--notes": "notes"}) + ["--json"],
    "reminders.edit": lambda a: ["edit", a["id"]] + flags(a, {"--title": "title", "--due": "due", "--notes": "notes"}) + ["--json"],
    "reminders.complete": lambda a: ["complete", a["id"], "--json"],
    "reminders.delete": lambda a: ["delete", a["id"], "--force", "--json"],
}


def _lists(text: str) -> list:
    return [rec(id=r.get("id"), title=r.get("title")) for r in json.loads(text)]


def _reminders(text: str) -> list:
    return [rec(id=r.get("id"), title=r.get("title"), due=r.get("dueDate"), completed=r.get("isCompleted"), list=r.get("listName"), notes=r.get("notes")) for r in rows(json.loads(text), "reminders", "reminder")]


PARSE = {
    "reminders.lists": _lists,
    "reminders.list": _reminders,
    "reminders.search": _reminders,
    "reminders.create": _reminders,
    "reminders.edit": _reminders,
    "reminders.complete": _reminders,
}

NOTES = {
    "*": "Exercised in the VM: reminders.lists, reminders.list, reminders.search.",
    "reminders.list": "Shows the reminders of one list; completed reminders are not requested separately.",
    "reminders.search": "Searches incomplete reminders by default.",
    "reminders.create": "untested: the JSON shape of the reply is assumed to be the reminder object.",
    "reminders.edit": "untested: reply shape assumed. The id may be a full id or an id prefix.",
    "reminders.complete": "untested: reply shape assumed.",
    "reminders.delete": "untested. --force skips the interactive confirmation, which a non-interactive caller needs; --dry-run exists as the preview path. Reply not parsed.",
}
