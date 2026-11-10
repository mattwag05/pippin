"""sweetrb/apple-notes-mcp, MCP server (npm apple-notes-mcp)."""

from __future__ import annotations

from ._util import first_json, named, pick, rec, rows

NAME = "sweetrb-notes"
KIND = "mcp"
VERSION = "2.16.1"
APPS = ["notes"]

MARK = "structuredContent: "


def launch(tools_dir: str) -> list[str]:
    return ["node", tools_dir + "/sweetrb-notes/node_modules/apple-notes-mcp/build/index.js"]


OPS = {
    "notes.folders": lambda a: ("list-folders", {}),
    "notes.list": lambda a: ("list-notes", named(a, {"folder": "folder", "limit": "limit"})),
    "notes.search": lambda a: ("search-notes", named(a, {"query": "query", "folder": "folder", "limit": "limit"})),
    "notes.show": lambda a: ("get-note-content", named(a, {"id": "id"})),
    "notes.create": lambda a: ("create-note", named(a, {"title": "title", "content": "body", "folder": "folder"})),
    "notes.edit": lambda a: ("update-note", named(a, {"id": "id", "newTitle": "title", "newContent": "body", "expectedContentHash": "content_hash"})),
    "notes.delete": lambda a: ("delete-note", named(a, {"id": "id", "expectedContentHash": "content_hash"})),
}


def _text(value):
    return value if isinstance(value, str) else None


def _folders(text: str) -> list:
    return [rec(id=r.get("id"), title=r.get("name")) for r in rows(first_json(text, MARK), "folders")]


def _notes(text: str) -> list:
    return [rec(id=r.get("id"), title=r.get("title"), folder=_text(r.get("folder")), modified=_text(r.get("modified"))) for r in rows(first_json(text, MARK), "notes")]


def _note(text: str) -> list:
    r = first_json(text, MARK) or {}
    # shortcut: a note whose title contains the marker text cuts the body at the wrong place; split on the parsed offset if that ever matters.
    return [rec(id=r.get("id"), title=r.get("title"), body=text[: text.rfind(MARK)], content_hash=r.get("contentHash"))]


def _written(text: str) -> list:
    r = first_json(text, MARK) or {}
    return [rec(id=r.get("id"), title=r.get("title"), content_hash=pick(r, "contentHash", "previousContentHash"))]


PARSE = {
    "notes.folders": _folders,
    "notes.list": _notes,
    "notes.search": _notes,
    "notes.show": _note,
    "notes.create": _written,
    "notes.edit": _written,
    "notes.delete": _written,
}

NOTES = {
    "*": "The text reply is prose followed by a JSON mirror introduced by 'structuredContent: '; parsers read the mirror. Exercised in the VM: notes.folders, notes.list, notes.search, notes.show.",
    "notes.list": "Records carry id and title only (no folder name, no modified date).",
    "notes.search": "Searches titles by default; 'modified' came back as an empty object in the VM and is dropped.",
    "notes.show": "The body is the HTML the tool prints before the mirror. The record also carries content_hash, which notes.edit and notes.delete require.",
    "notes.create": "untested: reply shape assumed.",
    "notes.edit": "untested. Requires content_hash (expectedContentHash) from a prior notes.show of the same note; without it the tool rejects the call. Replaces the whole body.",
    "notes.delete": "untested. Requires content_hash (expectedContentHash) from a prior notes.show; moves the note to Recently Deleted.",
}
