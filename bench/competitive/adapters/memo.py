"""antoniorodr/memo, CLI for Notes and Reminders. Plain text output only."""

from __future__ import annotations

import re

from ._util import rec

NAME = "memo"
KIND = "cli"
VERSION = "0.6.2"
APPS = ["notes", "reminders"]


def launch(tools_dir: str) -> list[str]:
    return [tools_dir + "/memo/venv/bin/memo"]


OPS = {
    "notes.folders": lambda a: ["notes", "--flist"],
    "notes.list": lambda a: ["notes"] + (["--folder", a["folder"]] if a.get("folder") else []),
    "notes.show": lambda a: ["notes", "--view", str(a["id"])],
    "reminders.list": lambda a: ["rem"],
}


def _folders(text: str) -> list:
    tail = text.split("Notes folder structure:", 1)[-1]
    return [{"id": line.strip(), "title": line.strip()} for line in tail.splitlines() if line.strip()]


def _notes(text: str) -> list:
    found = re.findall(r"^(\d+)\. (.*?) - (.*)$", text, re.M)
    return [{"id": index, "folder": folder, "title": title} for index, folder, title in found]


def _note(text: str) -> list:
    body = text.strip()
    return [rec(title=body.splitlines()[0] if body else None, body=body)]


def _reminders(text: str) -> list:
    out = []
    for index, rest in re.findall(r"^(\d+)\. (.*)$", text, re.M):
        parts = rest.split(" | ")
        out.append(rec(id=index, title=parts[0], due=parts[1] if len(parts) > 1 else None))
    return out


PARSE = {"notes.folders": _folders, "notes.list": _notes, "notes.show": _note, "reminders.list": _reminders}

NOTES = {
    "*": "Plain text output only, no JSON mode. Ids are positions in the current listing, not stable identifiers. Create, edit, delete, move, complete and search are interactive (prompts, $EDITOR, fzf), so they have no entry in OPS. Exercised in the VM: notes.folders, notes.list, notes.show, reminders.list.",
    "notes.folders": "Folder names are used as both id and title; nesting is shown by indentation, which the parser drops.",
    "notes.list": "Reads through memo's notes cache by default. Observed in the VM: a note created by another tool was missing ('No notes found') until memo ran with --no-cache. The adapter uses the default invocation; --no-cache is the tool's documented bypass. A folder name containing ' - ' splits at the first occurrence.",
    "notes.show": "The id is the 1-based position in the unfiltered note listing. Output is the note text with no metadata.",
    "reminders.list": "Lists all reminders; there is no list filter. Lines are 'N. title | due | relative due'; a title containing ' | ' is split.",
}
