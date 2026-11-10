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

pippin gives an AI agent your Mail, Calendar, Reminders, Contacts, Notes, Messages and Voice Memos on macOS, from one local binary, over MCP or the command line. It is built for the agent, not a person at a keyboard: every call answers with one JSON envelope, every error says what to do next, and every write goes through a safety gate that can preview, ask for confirmation, rate-limit, log and undo. Nothing leaves your Mac unless you point an AI feature at a remote provider ([SECURITY.md](SECURITY.md#data-handling)).

## Quickstart for agents (60 seconds)

```bash
brew install mattwag05/tap/pippin
pippin permissions                      # answer the macOS prompts once, in a terminal
claude mcp add pippin -- pippin mcp-server --apps calendar,reminders
```

Any MCP client works; the JSON form is in [docs/agent-integration.md](docs/agent-integration.md#60-second-setup). `--apps` exposes only the tool groups you name, which keeps the tool list small: scoped to one app it costs 1.4k to 6.1k tokens per turn instead of 22.6k for all 79 tools ([measured](docs/competitive/results.md#agent-ergonomics)). Then ask your agent "what's on my calendar tomorrow?".

## How it compares

A head-to-head against the most-used open-source Apple automation tools and MCP servers, run in a disposable VM against a seeded fixture, with the method committed before any result ([results](docs/competitive/results.md), [method](docs/competitive/methodology.md)):

- **Coverage:** 7 apps scored (Reminders, Calendar, Contacts, Notes, Messages, Mail, Voice Memos), every probed operation answered. The next widest tool covers 4.
- **Correctness and reliability:** 54 of 54 correctness checks and 65 of 65 reliability checks passed.
- **Speed:** with Mail and Voice Memos measured, fastest on 15 of 19 read operations warm and tied on the other 4, and fastest or tied on all 19 cold. Mail list and search take 2.4 and 1.6 ms against 8.5 and 7.7 ms for apple-pim. Every scored axis is 4 in one run of `bench/competitive/run.sh` from a clean checkout ([run](bench/competitive/results/2026-11-10-final/summary.md), [results](docs/competitive/results.md#speed)).
- **Agent tasks:** with `--apps`, the fewest model tokens on all three tasks (11k to 21k). With all tools exposed it is the most expensive (84k to 88k) ([agent tasks](docs/competitive/results.md#agent-tasks), [run](bench/competitive/results/2026-11-10-tasks)).
- **Safety:** the only measured tool with confirm tokens, rate limits, an action log, undo and untrusted-content marking together ([guardrail matrix](docs/competitive/results.md#safety-and-guardrails)).

Where pippin trails is listed first on the [results page](docs/competitive/results.md#where-pippin-trails). Mail and Voice Memos writes, and iMCP, were not run.

## Safety model

Writes made over MCP pass through one gate ([docs/safety-model.md](docs/safety-model.md), with the test behind each line):

- **Policy.** `~/.config/pippin/policy.json` sets each tool to `allow`, `deny` or `confirm`. With no file, sends and deletes need confirmation and other writes are allowed. `pippin policy show` prints the active policy.
- **Confirm tokens.** A confirmed tool's first call does nothing but return a preview and a single-use token bound to the exact arguments; the second call with the token acts. `messages_send` can only draft.
- **Dry run everywhere.** Every mutating tool takes `dryRun: true`.
- **Rate limits.** 10 per hour per send tool and 30 per hour per delete tool by default, surviving restarts.
- **Action log and undo.** Every write is logged before it runs (`pippin log`). Edits record their inverse, and `pippin undo <id>` reverts them. Sends, deletes and creates cannot be undone.
- **Untrusted content.** Results that carry other people's text (mail, messages, notes, events) are marked `content_trust: "untrusted"`.

The gate covers MCP only. An agent with a shell can run the CLI directly, which keeps its own `--confirm` and `--force` flags but has no policy, tokens or rate limits. The full threat model, including what pippin does not defend against, is in [SECURITY.md](SECURITY.md#threat-model).

## What each app supports

| App | Read | Write | Over MCP |
| --- | --- | --- | --- |
| Mail | accounts, mailboxes, list, search, show, verify, attachments, activity, triage, sanitize, extract | send, reply, forward (confirm), mark, move, apply rules | 17 tools |
| Calendar | calendars, events, today, remaining, upcoming, search, show, conflicts, agenda | create, smart create, edit, delete (confirm) | 13 tools |
| Reminders | lists, list, show, search | create, smart create, edit, complete, delete (confirm) | 9 tools |
| Contacts | list, search, show, groups | create, edit, delete (confirm) | 7 tools |
| Notes | folders, list, search, show | create, edit, delete (confirm, recoverable for 30 days) | 7 tools |
| Messages | list, search, show | draft only over MCP; exclude list | 7 tools |
| Voice Memos | list, info, export, transcribe, summarize | delete (confirm), capture to reminders | 7 tools (group `memos`) |

Plus `digest`, `status`, `doctor`, `actions_extract`, `batch`, `job_*`, and the safety tools `policy_show`, `action_log` and `undo`. Tool counts are from `pippin mcp-server --apps <app> --list-tools`. The full list is in [docs/mcp-server.md](docs/mcp-server.md).

## Command line

The same commands run from a shell, with the same JSON:

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

Examples by app follow. Every command, with its help text, is in [docs/cli-reference.md](docs/cli-reference.md), generated from the command definitions.

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

The 79 tools cover mail, calendar, reminders, contacts, notes, voice memos, Messages, `actions_extract`, `status`, `doctor`, `digest`, `batch` for parallel calls, `job_*` for background work, and the safety tools `policy_show`, `action_log` and `undo`. `--apps calendar,reminders` lists only the groups you name. Sends and deletes return a preview and a confirm token on the first call ([safety model](docs/safety-model.md)). `messages_send` can only draft. Calendar, Reminders, Contacts, Messages and Notes reads run inside the server, and everything else runs in a child process. See [`docs/mcp-server.md`](docs/mcp-server.md) for wiring and the full tool list, and [`docs/agent-integration.md`](docs/agent-integration.md) for how an agent should read the results.

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
| `pippin/MCP/` | MCP server: tool registry, dispatcher, in-process tools, `--apps` filter |
| `pippin/Safety/` | Policy, confirm tokens, rate limits, action log, undo, untrusted-content marking |

The whole codebase builds under Swift 6 strict concurrency. JXA bridges run `osascript`, and EventKit bridges use the framework directly. The full design is in [docs/architecture.md](docs/architecture.md).

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

See [CONTRIBUTING.md](CONTRIBUTING.md) for the test suites and conventions, and [docs/performance.md](docs/performance.md) for benchmarks.

## License

Apache 2.0. See [LICENSE](LICENSE).
