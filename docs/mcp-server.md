# MCP Server Mode

`pippin mcp-server` runs pippin as a [Model Context Protocol](https://modelcontextprotocol.io) server over stdio, so MCP-compatible clients (Claude Code, Claude Desktop, Cursor, and anything else that speaks MCP) can call pippin's features as first-class tools instead of shelling out to the CLI.

## What you get

44 tools spanning the commonly scripted pippin surfaces:

| Area | Tools |
|---|---|
| Mail | `mail_accounts`, `mail_mailboxes`, `mail_list`, `mail_activity`, `mail_show`, `mail_search`, `mail_attachments` |
| Calendar | `calendar_list`, `calendar_events`, `calendar_today`, `calendar_remaining`, `calendar_upcoming`, `calendar_search`, `calendar_create` |
| Reminders | `reminders_lists`, `reminders_list`, `reminders_show`, `reminders_search`, `reminders_create`, `reminders_complete` |
| Contacts | `contacts_search`, `contacts_show` |
| Notes | `notes_list`, `notes_search`, `notes_show`, `notes_folders` |
| Messages | `messages_list`, `messages_search`, `messages_show`, `messages_send` (gated — see [README § Messages](../README.md#messages)) |
| Memos | `memos_list`, `memos_info`, `memos_export`, `memos_transcribe`, `memos_capture_to_reminders`, `memos_summarize` |
| System | `status`, `doctor`, `digest` |
| Jobs  | `job_run`, `job_show`, `job_list`, `job_wait` — detach long-running work (see below) |
| Batch | `batch` — fan out N pippin commands concurrently in one tool call (see below) |

### `job_*` — background pippin subprocesses

`tools/call` is synchronous — a slow sub-command (e.g. `mail index`, `actions extract`) blocks the MCP session for its entire runtime. `job_run` forks a detached child, writes state to `~/.cache/pippin/jobs/<id>/status.json`, and returns `{job_id, pid, status:"running"}` immediately. The caller then polls `job_show` or blocks on `job_wait`.

Typical flow:

```
job_run    argv=["mail","index"]           → { "id": "01a3…", "status": "running" }
job_wait   id="01a3", timeout=600          → { "status": "done", "duration_ms": 47230 }
job_show   id="01a3"                       → { "status":"done", "stdout_tail":"…" }
```

IDs are 16-char hex (millisecond timestamp + 20-bit random), and `job_show` / `job_wait` accept any unambiguous prefix — pass the first 6–8 chars to save tokens. Jobs persist across pippin restarts; `job_list` finds prior work and `pippin job gc --older-than 7d` prunes terminal state.

Status values: `running`, `done` (exit 0), `error` (non-zero exit), `killed` (terminated by signal). Pipe `job_show` under MCP or drop into `pippin job logs <id> --stream` at the CLI to tail stdout/stderr live.

### `batch` — parallel sub-command dispatch

MCP serializes `tools/call` (one tool runs at a time per session). The `batch` tool is the only way to run several pippin commands in parallel from one MCP call. Useful for "fetch mail + calendar + reminders simultaneously" patterns where the alternative is N sequential round-trips.

Input shape:

```json
{
  "entries": [
    {"cmd": "mail",      "args": ["list", "--account", "icloud", "--limit", "5"]},
    {"cmd": "calendar",  "args": ["today"]},
    {"cmd": "reminders", "args": ["lists"]}
  ],
  "concurrency": 4
}
```

Output is an envelope whose `data` is an array of per-entry envelopes (each child runs with `--format agent`, so each entry has its own `{v, status, duration_ms, data|error}`). Order matches the input array.

Same shape is available from the CLI — pipe a JSON array into `pippin batch`:

```bash
echo '[{"cmd":"calendar","args":["today"]},{"cmd":"reminders","args":["lists"]}]' \
  | pippin batch --format agent --concurrency 2
```

Destructive actions (`mail send`, `reminders delete`, `calendar delete`, `memos delete`) are **not exposed** over MCP yet — they need a confirmation UX story first.

Heavy AI subsystems (`mail index`, `mail triage`, `audio transcribe`, browser automation) remain out of scope — they need longer-running or streaming UX than the one-shot `tools/call` flow supports. Memos transcription/summarization are exposed because they're single-shot per memo and agents reach for them often enough that the heavyweight cost is worth the ergonomics.

## How it works

Each `tools/call` spawns `pippin <subcommand> --format agent` as a child process and returns the child's compact JSON stdout as the tool result. This guarantees the MCP path stays in perfect parity with the existing CLI path used by the morning-briefing task and manual invocations.

- Successful tool call → `{"content":[{"type":"text","text":"<agent JSON>"}],"isError":false}`
- Tool failure (bad ID, permission denied, etc.) → same shape with `isError:true` and the pippin `AgentError` JSON as text
- Missing required argument → same shape with `isError:true` and a descriptive message
- Unknown tool name → JSON-RPC `-32601 method not found`

Diagnostics (startup banner, warnings) go to stderr and do not pollute the JSON-RPC transport.

## Envelope v1 (breaking change, 2026-04-20)

Every `--format agent` stdout is now wrapped in a versioned envelope. The MCP tool-result text field carries the envelope verbatim — clients that parse pippin JSON must reach one level deeper.

**Ok shape:**
```json
{"v":1,"status":"ok","duration_ms":234,"data":<original payload>}
```

**Error shape:**
```json
{"v":1,"status":"error","duration_ms":12,"error":{"code":"access_denied","message":"…","remediation":{…}?}}
```

Fields:
- `v` — envelope schema version. `1` is the first enveloped shape, introduced in [pippin-xy0](https://github.com/mattwag05/pippin/issues). Future breakage bumps this.
- `status` — `"ok"` or `"error"`.
- `duration_ms` — wall-clock milliseconds from command construction to JSON serialization.
- `data` — the previous raw payload, shape unchanged.
- `error` — the `AgentError.ErrorPayload` (`code`, `message`, optional `remediation`), previously emitted at the top level.

**Migration for MCP/CLI consumers:**

| Before envelope v1 | After envelope v1 |
|---|---|
| `jq '.' <output>` → array/object | `jq '.data' <output>` → same array/object |
| `jq '.error.code' <output>` | Same path — `error` is still the child key, just nested in the envelope |
| `jq 'length' on a list command` | `jq '.data \| length'` |
| Parser asserts top-level array | Parse top-level object, then read `.data` |

The inner `data` / `error` shapes are unchanged, so single-field extractions like `.error.code` and `.error.message` keep working unchanged. Only consumers that iterate the top-level response (expecting a bare array or a specific object shape) need to rebind one level deeper.

## Exit codes

On failure, the `pippin` child process exits with a typed code derived from the same `error.code` in the envelope, so a calling shell or orchestrator can branch on the failure *class* without parsing JSON:

| Code | Meaning | Retryable | Example `error.code` |
|------|---------|-----------|----------------------|
| `0` | success | — | — |
| `2` | usage / bad input | no | `invalid_cursor`, `invalid_json`, `missing_required` |
| `3` | resource not found | no | `event_not_found`, `memo_not_found`, `job_not_found` |
| `4` | auth / permission / config | no | `access_denied`, `missing_api_key`, `not_available` |
| `5` | tool / bridge failure (default) | maybe | `script_failed`, `database_error` |
| `7` | timeout / rate-limit | yes | `timed_out`, `rate_limited` |

Argument-parsing failures keep ArgumentParser's `64` (usage). The MCP server passes the child's exit code through verbatim, so MCP clients see the same codes. The mapping lives in [`pippin/Formatting/PippinExitCode.swift`](../pippin/Formatting/PippinExitCode.swift).

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

- **Talia (Hermes-Agent on M5)** — registers `pippin mcp-server` as a stdio MCP and drives the 44 tools natively (see the operator's Hermes setup notes).
- **Claude Code / Claude Desktop** — register via `claude mcp add` or the desktop config JSON; both pick up tools automatically on restart.
- **Morning-briefing scheduled task** — still shells out to the pippin CLI directly (no migration planned; the task is single-shot enough that MCP doesn't add value).

All CLI and MCP consumers receive envelope v1 responses (see above) as of 2026-04-20.
