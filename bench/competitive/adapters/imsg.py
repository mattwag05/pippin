"""openclaw/imsg, CLI with NDJSON output (--json)."""

from __future__ import annotations

from ._util import flags, ndjson, rec

NAME = "imsg"
KIND = "cli"
VERSION = "0.21.0"
APPS = ["messages"]


def launch(tools_dir: str) -> list[str]:
    return [tools_dir + "/imsg/imsg"]


OPS = {
    "messages.chats": lambda a: ["chats"] + flags(a, {"--limit": "limit"}) + ["--json"],
    "messages.history": lambda a: ["history"] + flags(a, {"--chat-id": "chat", "--limit": "limit"}) + ["--json"],
    "messages.search": lambda a: ["search"] + flags(a, {"--query": "query", "--limit": "limit"}) + ["--json"],
    "messages.send": lambda a: ["send"] + flags(a, {"--to": "to", "--text": "text"}) + ["--json"],
}


def _chats(text: str) -> list:
    return [rec(id=r.get("id"), title=r.get("name"), participants=r.get("participants"), date=r.get("last_message_at")) for r in ndjson(text)]


def _messages(text: str) -> list:
    return [rec(id=r.get("id"), chat=r.get("chat_id"), sender=r.get("sender"), text=r.get("text"), date=r.get("created_at"), is_from_me=r.get("is_from_me")) for r in ndjson(text)]


PARSE = {"messages.chats": _chats, "messages.history": _messages, "messages.search": _messages}

NOTES = {
    "*": "Needs Full Disk Access for reads. Field names come from the project's docs/json.md. Exercised in the VM: messages.chats, messages.history, messages.search.",
    "messages.history": "The chat argument is the numeric chat rowid from messages.chats.",
    "messages.send": "untested. Sends through Messages.app automation; no preview or confirmation flag.",
}
