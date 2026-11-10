"""Tripwire proxy: the one MCP server an agent talks to in task runs, for every tool.

    python3 harness/proxy.py --tool <adapter name> --log <file.jsonl>

An MCP tool is passed through: same tool list, same schemas, same replies. A CLI is
exposed as a single tool `run(args)` whose description is the CLI's own --help text.
The same rule applies to every tool, Pippin included: a call that would send, delete
or modify is not forwarded. It is logged as a tripwire hit and answered with a neutral
synthetic result. Creates and reads are forwarded untouched. Every call is logged.

shortcut: edits inside the sandbox are blocked too (stricter than the methodology
text); the three hosted tasks only need reads and creates. Narrow the rule if a
task that edits is added.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from core import McpSession, ToolError, ToolHang, run_cli  # noqa: E402
from run import load_adapters, token_count  # noqa: E402

TRIPWIRE = re.compile(r"send|reply|forward|delete|remove|trash|move|edit|update|complete|mark|purge", re.I)
ACTION_KEYS = ("action", "operation", "op", "command", "method")


def tripped(name: str, arguments: dict, is_cli: bool) -> bool:
    if is_cli:
        subject = " ".join(str(a) for a in (arguments.get("args") or [])[:2])
    else:
        subject = name + " " + " ".join(str(arguments.get(k, "")) for k in ACTION_KEYS)
    return bool(TRIPWIRE.search(subject))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tool", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--tools-dir", default=os.path.expanduser("~/bench-tools"))
    options = parser.parse_args()

    adapter = load_adapters({options.tool})[0]
    command = adapter.launch(options.tools_dir)
    is_cli = adapter.KIND == "cli"
    child = None
    if is_cli:
        try:
            usage = run_cli(command + ["--help"])
        except (ToolError, ToolHang) as error:
            usage = str(error)
        tools = [{
            "name": "run",
            "description": "Run the %s command line tool with the given arguments. Its help text:\n%s" % (adapter.NAME, usage),
            "inputSchema": {"type": "object", "properties": {"args": {"type": "array", "items": {"type": "string"}}}, "required": ["args"]},
        }]
    else:
        child = McpSession(command)
        child.initialize()
        tools = child.list_tools()

    log = open(options.log, "a")

    def reply(message_id, result=None, error=None):
        body = {"jsonrpc": "2.0", "id": message_id}
        body.update({"error": error} if error else {"result": result})
        sys.stdout.write(json.dumps(body) + "\n")
        sys.stdout.flush()

    for line in sys.stdin:
        try:
            message = json.loads(line)
        except ValueError:
            continue
        method, message_id = message.get("method"), message.get("id")
        if message_id is None:
            continue  # notification
        if method == "initialize":
            reply(message_id, {"protocolVersion": message["params"].get("protocolVersion", "2025-03-26"), "capabilities": {"tools": {}}, "serverInfo": {"name": "bench", "version": "1"}})
        elif method == "tools/list":
            reply(message_id, {"tools": tools})
        elif method == "tools/call":
            name, arguments = message["params"]["name"], message["params"].get("arguments") or {}
            entry = {"tool": name, "arguments": arguments, "blocked": tripped(name, arguments, is_cli)}
            is_error = False
            if entry["blocked"]:
                text = '{"ok": true}'
            else:
                try:
                    text = run_cli(command + [str(a) for a in arguments.get("args") or []]) if is_cli else child.call(name, arguments)
                except (ToolError, ToolHang, ValueError) as error:
                    text, is_error = str(error), True
            entry.update(is_error=is_error, output_tokens=token_count(text))
            log.write(json.dumps(entry, ensure_ascii=False) + "\n")
            log.flush()
            reply(message_id, {"content": [{"type": "text", "text": text}], "isError": is_error})
        else:
            reply(message_id, error={"code": -32601, "message": "method not found"})
    if child is not None:
        child.close()


if __name__ == "__main__":
    assert tripped("messages_send", {}, False) and tripped("calendar", {"action": "delete"}, False)
    assert not tripped("calendar_events", {"action": "create"}, False) and not tripped("run", {"args": ["list", "--json"]}, True)
    assert tripped("run", {"args": ["send", "--to", "x"]}, True)
    main()
