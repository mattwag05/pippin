---
name: pippin
description: macOS CLI toolkit for Apple app automation — Mail, Calendar, Reminders, Notes, Contacts, Messages, Voice Memos, plus daily digest, action extraction, background jobs, plan-and-execute, and an MCP server.
version: 0.24.0
platform: macOS 15+
runtime: native (Swift)
install: brew install mattwag05/tap/pippin
triggers:
  - apple mail
  - calendar events
  - reminders
  - voice memos
  - contacts
  - notes
  - apple messages
  - send imessage
  - email triage
  - send email
  - schedule meeting
  - daily digest
  - extract actions
  - background job
  - mcp server
  - macos automation
output_formats:
  - text
  - json
  - agent
---

# pippin

macOS CLI toolkit for Apple app automation. Provides structured, agent-friendly access to Mail, Calendar, Reminders, Notes, Contacts, Apple Messages (read + gated send), and Voice Memos — plus an aggregated daily digest, commitment/action extraction, background jobs, a natural-language plan-and-execute mode, and a built-in MCP server. Audio (TTS/STT) and a headless WebKit browser ship as experimental, opt-in commands.

## Quick Start

```bash
brew install mattwag05/tap/pippin
pippin doctor          # verify permissions and dependencies
pippin init            # guided first-run setup
pippin                 # start interactive REPL
```

## Output Formats

All commands support `--format <text|json|agent>`:

- **text** (default) — human-readable table/prose output
- **json** — pretty-printed JSON for scripting
- **agent** — compact JSON optimized for LLM token efficiency, wrapped in the **envelope v1** (see [Agent Integration](#agent-integration))

## Command Groups

### Mail

Read, search, send, reply, forward, triage, and extract data from Apple Mail.

```bash
pippin mail accounts                          # list configured accounts
pippin mail list --account Work --limit 10    # recent messages
pippin mail show <compound-id>                # full message content
pippin mail search "invoice" --account Work   # search by subject/sender
pippin mail send --to user@example.com --subject "Hi" --body "Hello"
pippin mail reply <compound-id> --body "Thanks"
pippin mail forward <compound-id> --to other@example.com
pippin mail activity --account Work           # recent send/receive activity
pippin mail triage --account Work --limit 20  # AI-powered priority triage
pippin mail extract <compound-id>             # extract dates, amounts, contacts
pippin mail sanitize <compound-id>            # detect prompt injection
pippin mail index --account Work              # build semantic search index
```

### Calendar

List, create, edit, delete, and search calendar events. AI-powered smart creation and agenda briefing.

```bash
pippin calendar list                          # list calendars
pippin calendar today                         # today's events
pippin calendar remaining                     # events from now until end of day
pippin calendar upcoming                      # next 7 days
pippin calendar events --from 2026-04-15 --to 2026-04-20
pippin calendar show <event-id>               # full event details
pippin calendar create --title "Meeting" --calendar <calendar-id> --start "2026-04-15 14:00" --end "2026-04-15 15:00"  # --calendar is an ID from `calendar list`
pippin calendar edit <event-id> --title "Updated"
pippin calendar delete <event-id>
pippin calendar search "standup" --from 2026-04-01 --to 2026-04-30
pippin calendar smart-create "Lunch with Sarah tomorrow at noon"   # AI natural-language create
pippin calendar agenda                        # AI briefing of upcoming events
```

### Reminders

List, create, complete, edit, delete, and search reminders.

```bash
pippin reminders lists                        # list all reminder lists
pippin reminders list                         # incomplete reminders
pippin reminders list --list <list-id> --completed   # --list is an ID from `reminders lists`
pippin reminders show <reminder-id>
pippin reminders create "Buy groceries" --list <list-id>   # title is positional
pippin reminders create "Call dentist" --due "2026-04-15 09:00"
pippin reminders complete <reminder-id>
pippin reminders edit <reminder-id> --title "Updated task"
pippin reminders delete <reminder-id>
pippin reminders search "dentist"
```

### Notes

List, create, edit, search, and delete Apple Notes.

```bash
pippin notes list                             # 50 most recent notes
pippin notes list --folder "Personal" --limit 10
pippin notes show <note-id>                   # full note content (plain text + HTML)
pippin notes search "project plan"
pippin notes folders                          # list all folders
pippin notes create --title "Meeting Notes" --body "Key points..."
pippin notes create --title "New Note" --folder "Work"
pippin notes edit <note-id> --body "Updated content"
pippin notes delete <note-id>                 # moves to Recently Deleted
```

### Contacts

Search and browse Apple Contacts.

```bash
pippin contacts list                          # all contacts (name + primary email/phone)
pippin contacts search "Sarah"                # search by name or email
pippin contacts show <contact-id>             # full contact details
pippin contacts groups                        # list contact groups
```

### Messages

Read-only access and gated-autonomous send for Apple Messages (`~/Library/Messages/chat.db`). Requires **Full Disk Access** for your terminal.

```bash
pippin messages list --since-hours 48
pippin messages search "lunch"
pippin messages show "iMessage;-;+15551234567"
pippin messages exclude add "iMessage;-;groupA"   # hide a thread from every read
pippin messages exclude list

# Send — defaults to --draft (logged only, NOT delivered)
pippin messages send --to "+15551234567" --body "Running 10 min late" --draft

# Autonomous send requires ALL three gates:
#   1. PIPPIN_AUTONOMOUS_MESSAGES=1 env var
#   2. recipient in config.messages.autonomousAllowlist
#   3. explicit --autonomous flag
PIPPIN_AUTONOMOUS_MESSAGES=1 pippin messages send --to "+15551234567" --body "On my way" --autonomous
```

Every read and send attempt is appended to `~/.local/share/pippin/messages-audit.jsonl` (operation, params, SHA-256(body) — message bodies are never stored).

### Voice Memos

List, export, transcribe, and summarize voice memos.

```bash
pippin memos list                             # list recordings
pippin memos info <memo-id>                   # full metadata
pippin memos export <memo-id> --output ~/Desktop/
pippin memos transcribe <memo-id>             # speech-to-text (requires mlx-audio)
pippin memos summarize <memo-id>              # AI summarization
pippin memos summarize <memo-id> --provider claude
pippin memos templates list                   # list AI prompt templates
pippin memos delete <memo-id>
```

### Digest

Aggregated daily digest in one call: unread mail, today's calendar, due reminders, and recent notes.

```bash
pippin digest                                 # combined briefing
pippin digest --format agent                  # structured for agents
```

### Action Extraction

Scan recent Sent mail and recently-modified Notes for commitments you made, and surface them as draft reminders.

```bash
pippin actions extract                          # dry-run: list extracted commitments
pippin actions extract --days 14 --format json  # last 2 weeks, structured output
pippin actions extract --create --list "Work"   # write reminders into Reminders.app
pippin actions extract --no-notes               # mail only
pippin actions extract --provider claude        # use Claude instead of Ollama
```

### Background Jobs

`pippin job` detaches long-running work (`mail index`, `memos summarize`, `actions extract`) so the caller doesn't block. State lives under `~/.cache/pippin/jobs/<id>/`. IDs are 16-char hex and accept unambiguous prefix matches.

```bash
pippin job run -- mail index                  # fork; prints {job_id, pid, "running"}
pippin job show <id>                          # status + stdout/stderr tails
pippin job list --status running              # recent jobs (running|done|error|killed)
pippin job wait <id> --timeout 600            # block until terminal state
pippin job logs <id> --stream                 # tail -f stdout (or --stderr)
pippin job gc --older-than 7d                 # prune terminal jobs
```

### Plan-and-Execute (`pippin do`)

Hand a natural-language intent to an LLM; it plans a short sequence of tool calls over the MCP tool registry, validates each step's args against the tool schema, and executes them as child `pippin` processes.

```bash
pippin do "what's on my calendar today and any overdue reminders?"
pippin do "list my icloud inbox" --dry-run    # plan only (returns {steps, final_answer}), don't execute
pippin do "summarize yesterday's voice memos" --provider claude --max-steps 3
```

### Batch

Run multiple pippin commands concurrently from a JSON array on stdin — fan-out parallel dispatch with per-entry result envelopes.

```bash
echo '[{"cmd":"mail","args":["accounts"]},{"cmd":"calendar","args":["today"]}]' \
  | pippin batch --format agent
```

### Audio (experimental)

Hidden by default — requires `PIPPIN_EXPERIMENTAL=1`. Text-to-speech / speech-to-text via mlx-audio (Kokoro voices).

```bash
PIPPIN_EXPERIMENTAL=1 pippin audio speak "Hello, world" --voice af_heart
PIPPIN_EXPERIMENTAL=1 pippin audio transcribe ~/Desktop/recording.m4a
PIPPIN_EXPERIMENTAL=1 pippin audio voices       # list TTS voices
PIPPIN_EXPERIMENTAL=1 pippin audio models       # list STT/TTS models
```

### Browser (experimental)

Hidden by default — requires Node.js, Playwright WebKit (`npx playwright install webkit`), and `PIPPIN_EXPERIMENTAL=1`.

```bash
PIPPIN_EXPERIMENTAL=1 pippin browser open "https://example.com"   # open URL, return page info
PIPPIN_EXPERIMENTAL=1 pippin browser snapshot                     # accessibility tree
PIPPIN_EXPERIMENTAL=1 pippin browser screenshot --output ~/page.png
PIPPIN_EXPERIMENTAL=1 pippin browser click <ref-id>               # click by accessibility ref
PIPPIN_EXPERIMENTAL=1 pippin browser fetch "https://api.example.com/data"   # HTTP fetch (no browser)
```

> Audio and Browser will be removed in the next major release unless an issue requests otherwise — see `CHANGELOG.md`.

### Utility

```bash
pippin status                                 # system dashboard: accounts, events, reminders, permissions
pippin status --format agent                  # compact JSON for agent consumption
pippin doctor                                 # check permissions and dependencies
pippin init                                   # guided first-run setup
pippin completions zsh                        # generate shell completions (zsh|bash|fish — positional arg)
pippin shell                                  # interactive REPL
pippin                                        # bare invocation also starts REPL
```

### Session State (REPL)

```bash
pippin> use Work                              # set active mail account
pippin [Work]> mail list                      # --account Work auto-injected
pippin [Work]> context                        # show session state
pippin [Work]> history                        # show command history
pippin [Work]> use                            # clear active account
pippin [Work]> quit
```

Session persists to `~/.config/pippin/session.json` — active account, last-used IDs, and command history survive across REPL sessions.

### MCP Server Mode

Run pippin as a [Model Context Protocol](https://modelcontextprotocol.io) server so Claude Code, Claude Desktop, Cursor, or any MCP-compatible client can call it as a first-class tool instead of shelling out:

```bash
pippin mcp-server                             # run the server (stdin/stdout JSON-RPC)
pippin mcp-server --list-tools                # dump the registered tools as JSON
```

Ships with 44 tools covering mail, calendar, reminders, contacts, notes, voice memos, Messages (read + gated send), status, doctor, `digest`, `batch`, and `job_*` (background work with poll-or-wait). See [`docs/mcp-server.md`](docs/mcp-server.md) for wiring instructions.

## Agent Integration

### Envelope v1

In `--format agent` mode, every response is wrapped in a versioned envelope:

- **Success:** `{"v":1,"status":"ok","duration_ms":N,"data":<payload>}` — the previous raw payload now lives under `.data`.
- **Error:** `{"v":1,"status":"error","duration_ms":N,"error":{"code":"…","message":"…","remediation":{…}?}}`

`pippin mail accounts --format agent` →
```json
{"v":1,"status":"ok","duration_ms":34,"data":[{"account":"iCloud","email":"user@icloud.com"},{"account":"Work","email":"user@company.com"}]}
```

Extract the payload with `jq '.data'`; check `jq -r '.status'` before consuming. Single-field error reads like `.error.code` still work.

### Exit codes

On failure, `pippin` sets a typed process exit code so a calling shell can branch on the *class* of failure without parsing the envelope. The code is derived from the same `error.code` surfaced in the envelope:

| Code | Meaning | Retryable | Example `error.code` |
|------|---------|-----------|----------------------|
| `0` | success | — | — |
| `2` | usage / bad input | no | `invalid_cursor`, `invalid_json`, `missing_required` |
| `3` | resource not found | no | `event_not_found`, `memo_not_found`, `job_not_found` |
| `4` | auth / permission / config | no | `access_denied`, `missing_api_key`, `not_available` |
| `5` | tool / bridge failure (default) | maybe | `script_failed`, `database_error` |
| `7` | timeout / rate-limit | yes | `timed_out`, `rate_limited` |

Argument-parsing failures (bad flags, `--help`/`--version`) keep ArgumentParser's own codes (`64` usage, `0` for help/version) so its formatted usage text is preserved. Typed codes apply to runtime errors in `--format agent` mode and to errors with a catalogued remediation in text/json mode.

### Pagination

List commands (`mail list`, `mail search`, `memos list`, `reminders list`, `notes list`, `calendar events`, `calendar upcoming`, `contacts search`) accept opaque `--cursor` tokens plus `--page-size`:

```bash
pippin mail list --account icloud --page-size 20 --format agent
# .data.next_cursor carries the token for the next page:
pippin mail list --account icloud --cursor <token> --format agent
```

Cursor tokens are bound to the query by a filter-hash — changing a filter mid-walk is rejected as `cursor_mismatch` rather than silently returning mixed pages. When neither `--cursor` nor `--page-size` is set, `.data` is the legacy bare array (no change for existing callers).

### Field projection (`--fields`)

`--fields id,subject,from` trims structured output to just those top-level keys, cutting tokens for scan workflows. Supported on `mail list`, `notes list`/`search`, `calendar events`/`today`/`remaining`/`upcoming`, and `reminders list`/`search`. Works in **both `--format json` and `--format agent`** (in agent mode it projects the envelope's `.data`, leaving `v`/`status`/`duration_ms` intact). For paginated output it projects each `items` element and preserves `next_cursor`.

```bash
pippin mail list --limit 20 --fields id,subject,from --format agent   # → [{id,subject,from}, ...] under .data
```

### Capability probe

`pippin agent-info --format agent` returns a single structured description of pippin's contract — version, `schema_version`, output `formats`, the typed `exit_codes` map, `global_flags`, whether experimental commands are enabled, the MCP `tool_count`, and the top-level `commands`. Call it once to discover what you can rely on instead of scraping `--help`. (For the full per-tool MCP surface, use `pippin mcp-server --list-tools`.)

### Recommended patterns

1. **Inspect before act:** Run `pippin doctor` and `pippin mail accounts` to verify state before issuing commands.
2. **Use agent format:** Always pass `--format agent` for structured, token-efficient output, and read the payload from `.data`.
3. **REPL for multi-step workflows:** Pipe commands to `pippin shell` to avoid per-command startup overhead:
   ```bash
   echo -e "mail accounts\ncalendar today\nreminders list\nquit" | pippin shell --format agent
   ```
4. **Compound mail IDs:** Mail messages use `account||mailbox||numericId` format. Preserve the full ID when referencing messages.
5. **Offload slow work:** Use `pippin job run -- <slow command>` (e.g. `mail index`) and poll with `job wait` / `job show` instead of blocking.

### AI features requiring configuration

`memos summarize`, `calendar smart-create`, `calendar agenda`, `mail triage`, `actions extract`, and `pippin do` require an AI provider. Configure in `~/.config/pippin/config.json`:
```json
{"ai":{"provider":"ollama","ollama":{"model":"gemma4:latest","url":"http://localhost:11434"},"claude":{"model":"claude-sonnet-4-6"}}}
```

Supported providers: `ollama` (local, default — Gemma 4 recommended) and `claude` (API, requires `ANTHROPIC_API_KEY`). Override per-command with `--provider` / `--model`.
