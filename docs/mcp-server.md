# MCP Server Mode

`pippin mcp-server` runs pippin as a [Model Context Protocol](https://modelcontextprotocol.io) server over stdio, so MCP-compatible clients (Claude Code, Claude Desktop, Cursor, and anything else that speaks MCP) can call pippin's features as first-class tools instead of shelling out to the CLI.

## What you get

26 tools spanning the commonly scripted pippin surfaces:

| Area | Tools |
|---|---|
| Mail | `mail_accounts`, `mail_mailboxes`, `mail_list`, `mail_show`, `mail_search` |
| Calendar | `calendar_list`, `calendar_events`, `calendar_today`, `calendar_remaining`, `calendar_upcoming`, `calendar_search`, `calendar_create` |
| Reminders | `reminders_lists`, `reminders_list`, `reminders_show`, `reminders_search`, `reminders_create`, `reminders_complete` |
| Contacts | `contacts_search`, `contacts_show` |
| Notes | `notes_list`, `notes_search`, `notes_show`, `notes_folders` |
| System | `status`, `doctor` |

Destructive actions (`mail send`, `reminders delete`, `calendar delete`) are **not exposed** over MCP yet — they need a confirmation UX story first.

Heavy AI subsystems (`mail index`, `mail triage`, `memos summarize`, `audio transcribe`, browser automation) are also out of scope for the MCP surface. They remain available via the CLI.

## How it works

Each `tools/call` spawns `pippin <subcommand> --format agent` as a child process and returns the child's compact JSON stdout as the tool result. This guarantees the MCP path stays in perfect parity with the existing CLI path used by Talia, the morning-briefing task, and manual invocations.

- Successful tool call → `{"content":[{"type":"text","text":"<agent JSON>"}],"isError":false}`
- Tool failure (bad ID, permission denied, etc.) → same shape with `isError:true` and the pippin `AgentError` JSON as text
- Missing required argument → same shape with `isError:true` and a descriptive message
- Unknown tool name → JSON-RPC `-32601 method not found`

Diagnostics (startup banner, warnings) go to stderr and do not pollute the JSON-RPC transport.

## Wire into Claude Code

Create or edit a `.mcp.json` file in the project root (machine-local, gitignored):

```json
{
  "mcpServers": {
    "pippin": {
      "type": "stdio",
      "command": "/Users/matthewwagner/.local/bin/pippin",
      "args": ["mcp-server"]
    }
  }
}
```

Restart Claude Code (`/exit` then relaunch) — MCP servers load at session start. Verify with:

```bash
claude mcp list
```

pippin should appear with its tool count. Then ask Claude something like _"What's on my calendar today?"_ — it should call the `calendar_today` tool directly rather than running `pippin calendar today` through Bash.

## Wire into Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "pippin": {
      "command": "/opt/homebrew/bin/pippin",
      "args": ["mcp-server"]
    }
  }
}
```

Restart Claude Desktop.

## Debugging

Dump the tool registry without running the server:

```bash
pippin mcp-server --list-tools | jq '.tools[].name'
```

Drive the server manually from the shell to test individual messages:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"status","arguments":{}}}' \
  | pippin mcp-server
```

Each response comes back as a single line of newline-delimited JSON on stdout.

## Known consumers

The morning-briefing scheduled task and Talia (on Raspberry Pi) still shell out to the pippin CLI for now — they have not been migrated to MCP. Both paths will continue to work; MCP is additive.
