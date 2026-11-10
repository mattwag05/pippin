<p align="center">
  <img src="docs/AppIcon.jpg" alt="pippin" width="200" />
</p>

<h1 align="center">pippin</h1>

<p align="center">
  <strong>Your Apple apps, one CLI away.</strong><br/>
  Headless automation for Mail, Calendar, Reminders, Notes, Contacts, Voice Memos, and more, built for AI agents.
</p>

<p align="center">
  <img src="docs/demo.gif" alt="pippin answering a health check, a send preview and an error, each as a JSON envelope" width="720" />
</p>

<p align="center">
  <a href="https://github.com/mattwag05/pippin/releases/latest"><img src="https://img.shields.io/github/v/release/mattwag05/pippin?style=flat-square&color=orange" alt="Release" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/mattwag05/pippin?style=flat-square&cacheSeconds=3600" alt="License" /></a>
  <img src="https://img.shields.io/badge/platform-macOS_15%2B-blue?style=flat-square" alt="macOS 15+" />
  <img src="https://img.shields.io/badge/arch-arm64-lightgrey?style=flat-square" alt="arm64" />
</p>

---

pippin lets AI agents read and change data in Apple apps that otherwise need GUI automation. Every command returns compact JSON in a versioned envelope, from the CLI or over MCP.

```
pippin mail list --unread
pippin calendar today
pippin reminders list --limit 5
pippin notes search "meeting"
pippin memos summarize <id> --provider ollama
pippin contacts search "Alice"
pippin job run -- mail index              # detach long-running work
pippin do "what's on my calendar today?"  # let an LLM plan the tool calls
```

## Install

**Homebrew** (recommended):

```bash
brew install mattwag05/tap/pippin
```

The formula doesn't install the default transcription backend. Its caveats print the install command with the pinned version. Check the result with `pippin doctor`.

**Pre-built binary** (arm64, macOS 15+):

```bash
# Latest tagged release (replace X.Y.Z with the version from the Releases page):
curl -LO https://github.com/mattwag05/pippin/releases/download/vX.Y.Z/pippin-X.Y.Z-arm64-macos.tar.gz
tar xzf pippin-*.tar.gz && mv pippin-*-arm64-macos ~/.local/bin/pippin
```

**Build from source** (Xcode 16+ / Swift 6.0+):

```bash
git clone https://github.com/mattwag05/pippin.git && cd pippin
make install
```

## Setup

macOS asks for a separate permission for each Apple app.

```bash
pippin permissions  # grant every promptable permission in one interactive pass
pippin init         # guided setup: permissions plus dependency checks
pippin doctor       # verify everything works, including code signing
pippin status       # accounts, events, reminders and permissions
```

Run `pippin permissions` or `pippin init` from a terminal so each macOS prompt gets answered once. A prompt that appears later, while an agent runs pippin in the background, can get denied without anyone seeing it. Run it again whenever macOS resets permissions, such as after an upgrade.

| Permission | Used by | How to grant |
|---|---|---|
| Reminders | Reminders | `pippin permissions` |
| Calendars | Calendar | `pippin permissions` |
| Contacts | Contacts | `pippin permissions` |
| Automation > Mail | Mail | `pippin permissions` |
| Automation > Notes | Notes | `pippin permissions` |
| Full Disk Access | Voice Memos, Messages, and Mail's fast path (optional) | System Settings, by hand. macOS has no prompt for it |

Grants survive rebuilds and upgrades only if the binary has a stable signature. `make install` and the Homebrew formula use a **Developer ID Application** certificate when one is available, which keeps grants even through certificate renewal. An **Apple Development** certificate also works, but grants reset when it renews, about once a year. An ad-hoc build asks again after every build. The **Code signing** row in `pippin doctor` tells you which one you have. If the signing identity changes, run `pippin permissions` once more.

## Try it

These commands change nothing, and each answers with the same JSON envelope:

```bash
pippin doctor --fields name,status     # which integrations are ready
pippin mail show nope                  # an error, with a machine-readable next_step
pippin mail send --to you@example.com --subject Hello --body "Hi" --dry-run  # a preview; needs Mail access and an account
```

## Commands

### Mail

```bash
pippin mail list --unread --limit 5
pippin mail list --unread --after 2026-06-01 --before 2026-07-01
pippin mail search "quarterly report" --after 2026-01-01
pippin mail search "invoice" --from billing@vendor.com    # sender filter, no body scan
pippin mail search "invoice" --preview 200                # add a body snippet to each hit
pippin mail show "acct||INBOX||12345"
pippin mail show "acct||INBOX||12345" "acct||INBOX||12346"   # 2+ ids, one batched fetch
pippin mail show "acct||INBOX||12345" --no-cache          # force a live fetch
pippin mail verify "acct||INBOX||12345"                   # compare against the sender's history
pippin mail attachments "acct||INBOX||12345" --save-dir ~/Downloads
pippin mail mark "acct||INBOX||12345" --read
pippin mail move "acct||INBOX||12345" --to Archive
pippin mail list --fields id,subject,from                 # only these JSON keys
pippin mail cache warm --limit 50                         # pre-fetch bodies so later reads are faster
```

**Sending.** `send`, `reply` and `forward` only preview unless you pass `--confirm`.

```bash
pippin mail send --to user@example.com --subject "Hello" --body "Hi there" --confirm
pippin mail reply "acct||INBOX||12345" --body "Thanks!" --confirm
pippin mail forward "acct||INBOX||12345" --to other@example.com --confirm
```

**Speed without Full Disk Access.** With Full Disk Access, list, search and activity read Mail's on-disk index in milliseconds, and `pippin doctor` shows whether that's available. Without it, pippin can build its own metadata index. Read state still comes from Mail on every call.

```bash
pippin job run -- mail cache fill
```

A mailbox the index hasn't finished falls back to reading Mail directly. Those direct scans can hit a time limit on large multi-account mailboxes, so add `--account` or a date range. A scan that times out with matches returns them with `partial: true`. One that times out with no matches returns `search_incomplete`, so an unfinished search never looks like an empty result.

**Body search.** `--body` adds message bodies to the match and is slower. Hits it finds in the body include a `bodyPreview`. Use `--from` on its own for sender searches.

**Phishing checks.** `mail show` reports structural warning signs in `headerAnomalies`, such as a Reply-To on a different domain, hidden recipients, SPF, DKIM or DMARC failures, and changes from the sender's own history. A passing auth check never suppresses a warning, because a compromised account signs its phishing with valid DKIM. List, search and activity show the same warnings only for messages whose headers are already cached, so a row with no warning hasn't necessarily been checked.

`mail verify` also parses the raw message into `authChain`, with every Received hop, Authentication-Results instance, ARC set and DKIM signature. Failures in older instances and a broken ARC chain (`cv=fail`) count toward the verdict.

**Rule-driven archiving.** `~/.config/pippin/triage-rules.json` drives the first pass of `mail triage`. A rule can also set `moveTo` and `markRead`, which `mail apply-rules` carries out. `mail triage` ignores both fields and stays read-only.

```bash
pippin mail apply-rules                          # prints the plan and changes nothing
pippin mail apply-rules --live                   # moves and marks
pippin mail apply-rules --account Work --min-age-days 30 --max-actions 50
```

```json
[
  { "id": "delta", "name": "Delta receipts", "enabled": true, "conditionOperator": "and",
    "conditions": [{ "field": "sender", "operator": "contains", "value": "@t.delta.com" }],
    "action": { "moveTo": "Archive", "markRead": true } }
]
```

Nothing changes without `--live`. `--min-age-days` (default 14) protects newer mail, and a message with an unreadable date stays put. `--max-actions` (default 200) caps each run and works oldest first, so repeated runs clear the backlog. The plan groups messages by sender, which is how you spot a rule that reaches too far, such as a domain rule that also catches two real people. `--skip-unread` spares unread mail, and a rule with `skip: true` never acts. If one message can't be reached, pippin records the failure and continues.

`date` is the sent time the sender declared, and a row may also include `receivedAt`. Date filters, newest-first ordering and the `apply-rules` age check use `receivedAt` when it exists, so a wrong sender date can't change the order or get around the age check.

**Previews from Mail's index (opt-in).** With Full Disk Access, `mail list --preview` and `mail activity` can use Mail's own `summaries` table instead of fetching bodies. Turn it on with `"mail": { "previewFromIndex": true }` in `~/.config/pippin/config.json`. It's off by default because Mail's summary isn't the first N characters of the body, and these previews skip the body cache, so a later `mail show` fetches from scratch.

### Voice Memos

```bash
pippin memos list --since 2026-01-01
pippin memos export <uuid> --output ~/Desktop/memos --transcribe
pippin memos summarize <uuid> --template meeting-notes
pippin memos summarize <uuid> --provider ollama --model gemma4:latest
pippin memos capture --to-reminders                 # most recent memo to Reminders
pippin memos capture --to-reminders --list Work --dry-run
pippin memos templates list                          # also `pippin templates list`
```

### Calendar

```bash
pippin calendar today
pippin calendar events --from 2026-04-01 --to 2026-04-30 --calendar-name "Work"
pippin calendar agenda --days 3
pippin calendar smart-create "Coffee with Alice next Tuesday at 2pm" --dry-run
pippin calendar create --title "Team standup" --start "2026-04-07 09:00"
```

### Reminders

```bash
pippin reminders lists                                          # get list IDs
pippin reminders list --list <list-id> --due-before 2026-04-15 --priority high
pippin reminders create "Submit report" --list <list-id> --due "2026-04-10" --priority high
pippin reminders complete <id>
pippin reminders search "report"
```

### Notes

```bash
pippin notes list --folder "Work"
pippin notes search "project kickoff"
pippin notes create "My note" --body "Content here" --folder "Work"
pippin notes create "Notes" --body $'## Heading\n\nPara one.\nLine two.'  # newlines/paragraphs preserved
pippin notes edit <id> --body "Extra line" --append
pippin notes create "Raw" --body "<div>already <b>HTML</b></div>" --html  # pass HTML through unconverted
```

### Contacts

```bash
pippin contacts search "Alice" --fields fullName,emails
pippin contacts show <id>
pippin contacts groups
```

### Messages

Reads `~/Library/Messages/chat.db`, and can send only behind explicit gates. Your terminal needs Full Disk Access (System Settings > Privacy & Security > Full Disk Access).

```bash
pippin messages list --since-hours 48
pippin messages search "lunch"
pippin messages show "iMessage;-;+15551234567"
pippin messages exclude add "iMessage;-;groupA"   # hide thread from every read
pippin messages exclude list

# Send defaults to --draft, which logs it and delivers nothing
pippin messages send --to "+15551234567" --body "Running 10 min late" --draft

# A real send requires all three:
#   1. PIPPIN_AUTONOMOUS_MESSAGES=1 env var
#   2. Recipient in config.messages.autonomousAllowlist
#   3. Explicit --autonomous flag
PIPPIN_AUTONOMOUS_MESSAGES=1 pippin messages send --to "+15551234567" --body "On my way" --autonomous
```

Each read and send attempt is added to `~/.local/share/pippin/messages-audit.jsonl` with the operation, its parameters and a SHA-256 of the body. Message bodies are never stored.

### Audio (experimental)

Requires `PIPPIN_EXPERIMENTAL=1`. Hidden by default.

```bash
PIPPIN_EXPERIMENTAL=1 pippin audio speak "Hello, world" --voice af_bella
PIPPIN_EXPERIMENTAL=1 pippin audio transcribe ~/recordings/meeting.m4a
PIPPIN_EXPERIMENTAL=1 pippin audio voices
```

### Browser (experimental)

Requires Node.js, Playwright WebKit (`npx playwright install webkit`), and
`PIPPIN_EXPERIMENTAL=1`. Hidden by default.

```bash
PIPPIN_EXPERIMENTAL=1 pippin browser open "https://example.com"
PIPPIN_EXPERIMENTAL=1 pippin browser snapshot
PIPPIN_EXPERIMENTAL=1 pippin browser fetch "https://example.com"
```


### Background Jobs

`pippin job` runs slow work (`mail index`, `mail cache fill`, `memos summarize`, `actions extract`) in the background so the caller doesn't wait. Each job keeps `status.json`, `stdout.log` and `stderr.log` in `~/.cache/pippin/jobs/<id>/`. IDs are 16 hex characters, and any unambiguous prefix works.

```bash
pippin job run -- mail index                     # returns the job id and pid
pippin job show <id>                             # status and the end of each log
pippin job list                                  # recent jobs (--status running|done|error|killed)
pippin job wait <id> --timeout 600               # wait until it finishes
pippin job logs <id> --stream                    # follow stdout (or --stderr)
pippin job gc --older-than 7d                    # delete finished jobs
```

Terminal statuses: `done` (exit 0), `error` (non-zero exit), `killed` (signal).

MCP exposes the same commands as `job_run`, `job_show`, `job_list` and `job_wait`, so an agent can start a slow index build and check on it later.

### Plan-and-Execute (`pippin do`)

Give an LLM a request in plain language. It plans a short list of tool calls from the MCP registry, pippin checks each step against the tool's schema, and child `pippin` processes run them.

```bash
pippin do "what's on my calendar today and any overdue reminders?"
pippin do "list my icloud inbox" --dry-run        # plan only
pippin do "summarize yesterday's voice memos" --provider claude --max-steps 3
```

`--dry-run` returns the plan (`{steps: [{tool, args}...], final_answer}`)
without executing. Planning requests use temperature `0`. The complete plan is
validated before execution for step count, known tools, argument schemas, and
empty-plan semantics. Invalid JSON or an invalid plan gets one repair attempt
that retains the original intent. An unsupported request is valid only as zero
steps plus a nonblank explanation.

Both dry-run and real output include `dry_run` and `executed`. Dry runs always
report `{"dry_run":true,"executed":false}`. Real runs report `executed:true`
only after at least one tool ran. `final_answer` is a planning note, not evidence
that any action occurred. OpenAI-compatible blank, reasoning-only, truncated,
or filtered responses fail as the non-retryable `incomplete_completion` error;
reasoning content is never returned or logged by pippin.

Before planning, a short model call reads which personal data the intent forbids
("don't touch my email"). Pass `--exclude-data mail,notes` to state exclusions
directly; both sources are merged and reported as `excluded_data`. Every tool
that accesses an excluded kind is removed from the planner's tool list and from
the executor's allowlist, so a plan naming one fails validation. Cross-cutting
tools count as accessing every app they open: `status` and `doctor` open Mail,
Notes, Calendar, and the rest, and the `job_*` and `batch` tools count as
accessing everything. Reading exclusions from the intent is best effort, while
`--exclude-data` is enforced.

### Action Extraction

Finds commitments you made in recent Sent mail and recently modified Notes, and offers them as draft reminders.

```bash
pippin actions extract                          # list what it found, change nothing
pippin actions extract --days 14                # last 2 weeks
pippin actions extract --create --list "Work"   # write them to Reminders
pippin actions extract --no-notes               # mail only
pippin actions extract --provider claude        # use Claude instead of Ollama
```

### Interactive Shell (REPL)

```bash
pippin shell                           # start a session
pippin                                 # bare pippin does the same
echo "calendar agenda" | pippin shell  # pipe commands in
```

Inside the REPL, type commands without the `pippin` prefix:

```
pippin> mail accounts
pippin> mail list --account Work --unread
pippin> calendar agenda
pippin> quit
```

### Output

Every command and every error writes one compact JSON envelope: `{v, status, duration_ms, partial?, warnings?, next_cursor?, data}`, or `error` in place of `data`. `--format agent` is accepted and changes nothing. `--format text` and `--format json` are usage errors. For a human look, pipe through `jq '.data'`.

List and search rows default to essential fields to save tokens. `--fields id,subject` picks keys, and `--fields all` returns whole rows. A field no row has produces a warning.

### Agent discovery & exit codes

```bash
pippin agent-info     # version, exit codes, tool count and commands
```

Exit codes let a shell branch without parsing JSON: `2` usage, `3` not found, `4` auth, permission or config, `5` tool or bridge failure, `7` timeout, rate limit or other transient failure. Every error envelope also has `error.next_step`, which says whether to retry and when, what to call next, or what a person has to do.

### Pagination

`mail list`, `mail search`, `memos list`, `reminders list`, `notes list`, `calendar events`, `calendar upcoming` and `contacts search` take `--cursor` tokens, so an agent can walk a long result without fetching earlier pages again.

```bash
pippin mail list --account icloud --page-size 20
# the top-level next_cursor holds the token for the next page, and data stays an array
pippin mail list --account icloud --cursor <token>
# or jump to a numbered page
pippin mail list --account icloud --page 2 --page-size 20
```

A token is tied to its query, so changing a filter between calls returns `cursor_mismatch` instead of mixing pages. If you pass both `--cursor` and `--page`, the cursor wins. `next_cursor` is omitted on the last page.

### MCP Server Mode

Run pippin as a [Model Context Protocol](https://modelcontextprotocol.io) server so Claude Code, Claude Desktop, Cursor or another MCP client can call it directly:

```bash
pippin mcp-server                    # JSON-RPC over stdin and stdout
pippin mcp-server --list-tools       # print the registered tools as JSON
```

The 79 tools cover mail, calendar, reminders, contacts, notes, voice memos, Messages, `actions_extract`, `status`, `doctor`, `digest`, `batch` for parallel calls, and `job_*` for background work. Outbound mail only previews and deletes fail unless the call passes `confirm: true`. `messages_send` can only draft. Quick Calendar, Reminders and Contacts reads run inside the server, and everything else runs in a child process. See [`docs/mcp-server.md`](docs/mcp-server.md) for wiring and the full tool list.

## AI Configuration

`memos summarize`, `calendar smart-create`, `mail triage`, `mail extract`, `actions extract` and `do` use an LLM. pippin works with Ollama locally, Claude, and any OpenAI-compatible Chat Completions endpoint, such as OpenAI, OpenRouter, vLLM, LM Studio or llama.cpp server.

```json
{
  "ai": {
    "provider": "ollama",
    "ollama": {
      "model": "gemma4:latest",
      "url": "http://localhost:11434"
    },
    "claude": {
      "model": "claude-sonnet-4-6"
    },
    "openai": {
      "baseURL": "https://api.openai.com/v1",
      "model": "gpt-4o-mini"
    }
  }
}
```

Save to `~/.config/pippin/config.json`, or override per-command:

```bash
pippin memos summarize <id> --provider ollama --model qwen3.5:latest
pippin memos summarize <id> --provider claude
```

| Provider | Setup | Speed |
|----------|-------|-------|
| `ollama` (default) | [Install Ollama](https://ollama.com), then `ollama pull gemma4` | ~22s/summary (Gemma 4) |
| `claude` | Set `ANTHROPIC_API_KEY` env var | ~2-3s/summary |
| `openai` | Set `ai.openai.baseURL` (+ `apiKey` / `$OPENAI_API_KEY` if the endpoint authenticates) | endpoint-dependent |

`apiKey` is optional for local endpoints that don't authenticate.

### Embeddings and transcription backends

Semantic mail search and memo transcription have their own backends, chosen independently of `ai.provider`:

```json
{
  "ai": {
    "embeddings":    { "provider": "openai", "model": "text-embedding-3-small" },
    "transcription": { "provider": "apple", "locale": "en-US" }
  }
}
```

| Setting | Providers | Default |
|---------|-----------|---------|
| `ai.embeddings` (`mail index`, `mail search --semantic`) | `ollama`, `openai` (any `/v1/embeddings` endpoint; `model` required) | `ollama` with `nomic-embed-text` |
| `ai.transcription` (`memos transcribe`, `export --transcribe`, `summarize`, `capture`) | `mlx-audio`, `apple` (on-device SpeechAnalyzer, macOS 26+), `openai` (any `/v1/audio/transcriptions` endpoint) | `mlx-audio` |

For `openai`, an omitted `baseURL` or `apiKey` falls back to the `ai.openai` values. `mail index` and `mail search` also accept `--provider`, `--model` (`--embedding-model` on search), and `--ollama-url`.

Vectors from different embedding models cannot be compared. The index records which model embedded each message, so run `pippin mail index` again after switching backends. Semantic search ranks only messages indexed with the active model and reports an error when there are none.

`pippin doctor` has an AI provider, Embeddings, and Transcription check. Each names the configured backend and says whether it is reachable. Set `PIPPIN_CONFIG` to read a different config file.

The planner sends temperature `0` so plans stay deterministic, and other callers use each provider's default. OpenAI-compatible responses must have assistant text and a completed finish reason. Anything else returns `incomplete_completion`, and pippin never exposes hidden reasoning fields.

For summaries, use Gemma 4 over Qwen 3.5. Qwen's reasoning roughly doubled the time without better structured output.

## Contact Name Resolution

`mail list`, `search`, `activity` and `show`, and `messages list`, `search` and `show`, turn each phone number or email into its Apple Contacts name. The index lives in `~/.config/pippin/contact-index.db` and rebuilds only when your contacts change. If Contacts isn't authorized, names just stay unresolved and the command still works.

To turn it off everywhere instead of passing `--no-contacts` each time:

```json
{
  "resolveContacts": false
}
```

A per-command `--no-contacts` or `--contacts` wins over the config key, and resolution is on by default.

Phone numbers match on digits, first the full string and then the last 10 digits, so `+1 555 123 4567` and `555-123-4567` resolve to the same person. Two numbers that differ only by country code collide. The first contact enumerated keeps the match, and nothing marks it as a near match, so a name on a foreign number could belong to a domestic contact. Use `--no-contacts` when you need the raw handle.

## Sample Workflows

```bash
# Morning briefing in one process
echo -e "calendar today\nreminders list\nmail list --unread --limit 10" | pippin shell

# Or as separate commands
pippin calendar today
pippin reminders list
pippin mail list --unread --limit 10

# Export and transcribe today's voice memos
pippin memos list --since $(date +%Y-%m-%d) \
  | jq -r '.data[].id' \
  | xargs -I{} pippin memos export {} --output ~/memos --transcribe

# Find unread emails from a specific sender
pippin mail list --unread \
  | jq '.data[] | select(.from | contains("boss@company.com"))'
```

## Architecture

| Component | Description |
|---|---|
| `pippin/MailBridge/` | JXA script builder for Mail.app |
| `pippin/MemosBridge/` | GRDB SQLite access to Voice Memos |
| `pippin/CalendarBridge/` | EventKit wrapper for Calendar |
| `pippin/RemindersBridge/` | EventKit wrapper for Reminders |
| `pippin/NotesBridge/` | JXA subprocess bridge for Notes.app |
| `pippin/ContactsBridge/` | CNContactStore wrapper (read + write) |
| `pippin/MessagesBridge/` | GRDB SQLite access to Apple Messages (read + gated send) |
| `pippin/AIProvider/` | Ollama, Claude, and OpenAI-compatible backends; per-feature embedding and transcription factories |
| `pippin/Jobs/` | Filesystem-backed registry for detached `pippin job` subprocesses |
| `pippin/Planner/` | LLM-driven plan-and-execute over the MCP tool registry (`pippin do`) |
| `pippin/Pagination/` | Opaque-cursor tokens + filter-hash guards for list commands |
| `pippin/Commands/AgentCommand.swift` | `AgentResult`, the value every command returns to the CLI and to in-process MCP tools |
| `pippin/Commands/ShellCommand.swift` | Interactive REPL |
| `pippin/Formatting/` | Agent envelope, field projection, error next steps and exit codes |

The whole codebase builds under Swift 6 strict concurrency. JXA bridges run `osascript`, and EventKit bridges use the framework directly.

## Requirements

- **macOS 15 (Sequoia) or later**, on arm64 for pre-built binaries
- **Swift 6.0 or later** for source builds
- **mlx-audio** for the default memo transcription backend. You don't need it when `ai.transcription.provider` is `apple` or `openai`. The experimental `audio` command also uses it
- **Ollama** for the default AI and embeddings backend. Claude and OpenAI-compatible endpoints work without it

`audio` (speech through mlx-audio) and `browser` (Playwright WebKit) are hidden unless you set `PIPPIN_EXPERIMENTAL=1`. They'll be removed in the next major release unless someone files an issue asking to keep them. See `CHANGELOG.md`.

## Development

```bash
make build      # release build
make test       # run the tests
make lint       # swiftformat lint
make ci         # build, tests, swiftformat and the repo lint scripts
make install    # build and install to ~/.local/bin
```

## License

Apache 2.0. See [LICENSE](LICENSE).
