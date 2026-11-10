"""keith/reminders-cli, CLI with JSON output on read and add (--format json)."""

from __future__ import annotations

import json

from ._util import flags, rec, rows

NAME = "reminders-cli"
KIND = "cli"
VERSION = "2.5.1"
APPS = ["reminders"]


def launch(tools_dir: str) -> list[str]:
    return [tools_dir + "/reminders-cli/reminders"]


OPS = {
    "reminders.lists": lambda a: ["show-lists", "--format", "json"],
    "reminders.list": lambda a: ["show", a["list"]] + (["--include-completed"] if a.get("include_completed") else []) + ["--format", "json"],
    "reminders.create": lambda a: ["add", a["list"], a["title"]] + flags(a, {"--due-date": "due", "--notes": "notes"}) + ["--format", "json"],
    "reminders.edit": lambda a: ["edit", a["list"], a["id"]] + flags(a, {"--notes": "notes"}) + ([a["title"]] if a.get("title") else []),
    "reminders.complete": lambda a: ["complete", a["list"], a["id"]],
    "reminders.delete": lambda a: ["delete", a["list"], a["id"]],
}


def _lists(text: str) -> list:
    return [{"id": name, "title": name} for name in json.loads(text)]


def _reminders(text: str) -> list:
    return [rec(id=r.get("externalId"), title=r.get("title"), due=r.get("dueDate"), completed=r.get("isCompleted"), list=r.get("list"), notes=r.get("notes")) for r in rows(json.loads(text))]


PARSE = {"reminders.lists": _lists, "reminders.list": _reminders, "reminders.create": _reminders}

NOTES = {
    "*": "Exercised in the VM: reminders.lists, reminders.list. Has no --version flag; the version is the release tag.",
    "reminders.lists": "Lists are names only: the list name is used as both id and title.",
    "reminders.create": "untested: reply shape assumed to be the reminder object.",
    "reminders.edit": "untested. Changes title and notes only; a due date cannot be edited. Plain text output only. Every write needs the list name and takes an index or id.",
    "reminders.complete": "untested. Plain text output only.",
    "reminders.delete": "untested. Plain text output only; no confirmation and no preview.",
}
