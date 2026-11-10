"""mattt/iMCP, MCP through a GUI app. Not run: needs interactive approval."""

from __future__ import annotations

NAME = "imcp"
KIND = "mcp"
VERSION = "1.8.3"
APPS = ["calendar", "contacts", "mail", "messages", "notes", "reminders", "memos"]


def launch(tools_dir: str) -> list[str]:
    # iMCP.app must already be running; imcp-server only relays stdio to it.
    return [tools_dir + "/imcp/iMCP.app/Contents/MacOS/imcp-server"]


OPS = {}
PARSE = {}

NOTES = {
    "*": "not run: needs interactive approval. The app installs and launches in the VM and imcp-server starts, but initialize never answers: the app shows a 'Client Connection Request' dialog for every new client (the README says 'Allow' is click-only and the request is denied after two minutes), and every service is off until a person clicks its icon and answers a macOS permission prompt. No tools/list manifest could be captured, so no operation is mapped; the README does not list tool names and arguments completely enough to write them unseen. APPS is the README's claim.",
}
