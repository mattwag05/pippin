"""carterlasalle/mac_messages_mcp, MCP server (PyPI mac-messages-mcp). Plain text output only."""

from __future__ import annotations

from ._util import named

NAME = "mac-messages"
KIND = "mcp"
VERSION = "1.1.0"
APPS = ["messages"]


def launch(tools_dir: str) -> list[str]:
    return [tools_dir + "/mac-messages/venv/bin/mac-messages-mcp"]


OPS = {
    "messages.chats": lambda a: ("tool_get_chats", {}),
    "messages.history": lambda a: ("tool_get_recent_messages", named(a, {"contact": "contact", "hours": "hours"}) if a.get("contact") else named(a, {"chat_id": "chat", "hours": "hours"})),
    "messages.search": lambda a: ("tool_fuzzy_search_messages", named(a, {"search_term": "query", "hours": "hours"})),
    "messages.send": lambda a: ("tool_send_message", named(a, {"recipient": "to", "message": "text"})),
}

def _chats(text: str) -> list:
    import re

    return [{"id": m.group(2), "title": m.group(1)} for m in re.finditer(r"^\d+\. (.*) \(ID: ([^)]+)\)$", text, re.M)]


PARSE = {"messages.chats": _chats}

NOTES = {
    "*": "Plain text output only, wrapped in <untrusted-mcp-output>; only the chat listing has a parser. Needs Full Disk Access. serverInfo reports the MCP SDK version (1.30.0), not the package version (1.1.0). Exercised in the VM: messages.chats, messages.history, messages.search.",
    "messages.chats": "Lists named group chats only, not one-to-one conversations.",
    "messages.history": "Windowed by hours (default 24, maximum 87600), not by message count; the chat argument is a group chat id. One-to-one history takes the contact argument, which the adapter passes when the canonical call carries one.",
    "messages.search": "Fuzzy text match inside an hours window (default 720).",
    "messages.send": "untested. Sends immediately; no preview or confirmation argument.",
}
