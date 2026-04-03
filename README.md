# pippin

macOS CLI toolkit for Apple app automation. Structured CLI access to sandboxed Apple apps — headless-safe for cron, launchd, and AI agent pipelines.

```
pippin mail list
pippin memos list
pippin calendar events
pippin notes search "meeting"
pippin contacts search "Alice"
pippin reminders list "Work"
pippin audio speak "Hello"
pippin browser open "https://example.com"
```

---

## Install

### Homebrew (recommended)

```bash
brew install mattwag05/tap/pippin
```

### Pre-built binary (arm64, macOS 15+)

Download from the [Releases](https://github.com/mattwag05/pippin/releases) page:

```bash
curl -L https://github.com/mattwag05/pippin/releases/download/v0.14.1/pippin-0.14.1-arm64-macos.tar.gz -o pippin.tar.gz
tar xzf pippin.tar.gz && mv pippin-0.14.1-arm64-macos ~/.local/bin/pippin
chmod +x ~/.local/bin/pippin
```

### Build from source

Requires Xcode 16+ / Swift 6.2+:

```bash
git clone https://github.com/mattwag05/pippin.git
cd pippin
make install
```

---

## First-run setup

pippin accesses sandboxed Apple apps — macOS requires explicit permission grants.

### 1. Run the setup guide

```bash
pippin init
```

This walks through each permission and tells you exactly what to grant.

### 2. Manual permission grants

Open **System Settings → Privacy & Security**:

| Permission | For |
|---|---|
| **Full Disk Access** → Terminal.app | Voice Memos (`pippin memos`) |
| **Automation → Mail** → Terminal.app | Mail (`pippin mail`) |
| **Automation → Mail** → pippin binary | Mail under cron/launchd |
| **Calendars** → Terminal.app / pippin | Calendar (`pippin calendar`) |
| **Reminders** → Terminal.app / pippin | Reminders (`pippin reminders`) |
| **Contacts** → Terminal.app / pippin | Contacts (`pippin contacts`) |
| **Automation → Notes** → Terminal.app | Notes (`pippin notes`) |

After granting, run each subcommand once interactively to trigger the TCC prompt.

> **Note:** Permission is per binary path. After each new build or install, re-run commands interactively before scheduling with launchd/cron.

### 3. Check permissions

```bash
pippin doctor          # Check all permissions and dependencies
pippin doctor --format json   # Machine-readable check results
```

---

## Usage

### Output formats

Every subcommand supports three output modes:

| Flag | Description |
|---|---|
| `--format text` | Human-readable text tables and cards (default) |
| `--format json` | Pretty-printed JSON for scripting |
| `--format agent` | Compact JSON for AI agent consumption (minimal whitespace) |

```bash
pippin mail list --format json | jq '.[0].subject'
pippin calendar events --format agent
```

---

### `pippin mail`

```bash
# List accounts
pippin mail accounts

# List inbox (text table, limit 20)
pippin mail list
pippin mail list --unread --limit 5
pippin mail list --mailbox Archive --account "Work"

# Search (subject, sender, body)
pippin mail search "quarterly report"
pippin mail search "invoice" --account "Work" --after 2026-01-01 --limit 20

# Show a message
pippin mail show "acct||INBOX||12345"
pippin mail show --subject "quarterly report"

# Reply / forward
pippin mail reply "acct||INBOX||12345" --body "Thanks!"
pippin mail forward "acct||INBOX||12345" --to other@example.com

# Attachments
pippin mail attachments "acct||INBOX||12345"
pippin mail attachments "acct||INBOX||12345" --save-dir ~/Downloads

# Mark read/unread
pippin mail mark "acct||INBOX||12345" --read
pippin mail mark "acct||INBOX||12345" --unread --dry-run

# Move to another mailbox
pippin mail move "acct||INBOX||12345" --to Archive
pippin mail move "acct||INBOX||12345" --to Trash --dry-run

# Send
pippin mail send --to user@example.com --subject "Hello" --body "Hi there"
pippin mail send --to user@example.com --subject "Report" --body "See attached" --attach /tmp/report.pdf --dry-run
```

---

### `pippin memos`

```bash
# List recordings
pippin memos list
pippin memos list --since 2026-01-01 --limit 10

# Show details
pippin memos info <uuid>

# Export audio file(s)
pippin memos export <uuid> --output ~/Desktop/memos
pippin memos export --all --output ~/Desktop/memos

# Transcribe (uses mlx-audio)
pippin memos transcribe <uuid> --output ~/Desktop/memos
pippin memos export <uuid> --output ~/Desktop --transcribe

# Summarize with AI (uses Ollama by default, or Claude)
pippin memos summarize <uuid> --output ~/Desktop/memos
pippin memos summarize <uuid> --provider ollama --model gemma4:latest
pippin memos summarize <uuid> --provider claude --template meeting-notes

# List prompt templates
pippin memos templates
```

---

### `pippin calendar`

```bash
# List calendars
pippin calendar list
pippin calendar list --type calDAV

# List events
pippin calendar events
pippin calendar events --from 2026-03-01 --to 2026-03-31 --calendar "Work"
pippin calendar events --range week
pippin calendar today
pippin calendar remaining
pippin calendar upcoming

# Show a specific event
pippin calendar show <id>

# Create / edit / delete
pippin calendar create --title "Team standup" --start "2026-03-20 09:00"
pippin calendar edit <id> --title "Team standup (new time)" --start "2026-03-20 10:00"
pippin calendar delete <id> --force

# Natural-language event creation
pippin calendar smart-create "Coffee with Alice next Tuesday at 2pm"
pippin calendar smart-create "Coffee with Alice next Tuesday at 2pm" --dry-run

# AI daily/weekly briefing
pippin calendar agenda
pippin calendar agenda --days 3
```

---

### `pippin reminders`

```bash
# List reminder lists
pippin reminders lists

# List reminders in a list
pippin reminders list "Work"
pippin reminders list "Work" --due-before 2026-03-20
pippin reminders list "Work" --priority high

# Show a reminder
pippin reminders show <id>

# Create / edit / complete / delete
pippin reminders create "Buy milk" --list "Personal"
pippin reminders create "Submit report" --list "Work" --due "2026-03-20" --priority high
pippin reminders edit <id> --title "Submit Q1 report" --due "2026-03-21"
pippin reminders complete <id>
pippin reminders delete <id>

# Search across all lists
pippin reminders search "report"
```

---

### `pippin notes`

```bash
# List notes
pippin notes list
pippin notes list --folder "Work"

# Show a note
pippin notes show <id>

# Search
pippin notes search "project kickoff"
pippin notes search "meeting" --folder "Work"

# List folders
pippin notes folders

# Create / edit / delete
pippin notes create "My note" --body "Note content here"
pippin notes create "My note" --body "..." --folder "Work"
pippin notes edit <id> --body "Updated content"
pippin notes edit <id> --body "Extra line" --append
pippin notes delete <id> --force
```

---

### `pippin contacts`

```bash
# List contacts
pippin contacts list
pippin contacts list --limit 50

# Search
pippin contacts search "Alice"
pippin contacts search "Alice" --fields "name,email"   # token-efficient output

# Show a contact
pippin contacts show <id>

# List contact groups
pippin contacts groups
```

---

### `pippin audio`

```bash
# Text-to-speech
pippin audio speak "Hello, world"
pippin audio speak "Hello" --voice af_bella

# Transcribe an audio file (mlx-audio)
pippin audio transcribe ~/recordings/meeting.m4a

# List available voices and models
pippin audio voices
pippin audio models
```

---

### `pippin browser`

Requires Node.js and Playwright WebKit (`npx playwright install webkit`).

```bash
# Open a URL
pippin browser open "https://example.com"

# Get accessibility snapshot (for AI agent interaction)
pippin browser snapshot

# Take a screenshot
pippin browser screenshot --output ~/Desktop/screenshot.png

# Interact with the page
pippin browser click --ref "e12"
pippin browser fill --ref "e5" --value "search query"
pippin browser scroll --direction down

# Tab management
pippin browser tabs
pippin browser close --tab 1

# Fetch page HTML (no JS rendering)
pippin browser fetch "https://example.com"
```

---

### Diagnostics

```bash
pippin doctor          # Check all permissions and dependencies
pippin doctor --format json   # Machine-readable check results
pippin init            # Guided setup with remediation steps
pippin --version       # Print version
```

---

## AI Configuration

`memos summarize` uses a local or cloud LLM to summarize voice memo transcripts. Configure the provider in `~/.config/pippin/config.json`:

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
    }
  }
}
```

| Provider | Setup | Notes |
|----------|-------|-------|
| `ollama` (default) | Install [Ollama](https://ollama.com), then `ollama pull gemma4` | Free, private, runs locally. Recommended: Gemma 4 (~22s/summary) over Qwen 3.5 (~45s) — Qwen's chain-of-thought reasoning adds latency without quality gains for summarization. |
| `claude` | Set `ANTHROPIC_API_KEY` or use Vaultwarden | Fastest (~2-3s), highest quality, requires API key and internet. |

Override per-command: `pippin memos summarize <id> --provider ollama --model qwen3.5:latest`

---

## Sample workflows

```bash
# Check everything is working
pippin doctor

# Find unread emails from a specific sender
pippin mail list --unread --format json | jq '.[] | select(.from | contains("boss@company.com"))'

# Export and transcribe today's voice memos
pippin memos list --since $(date +%Y-%m-%d) --format json \
  | jq -r '.[].id' \
  | xargs -I{} pippin memos export {} --output ~/memos --transcribe

# Get today's calendar + active reminders for a morning briefing
pippin calendar today --format agent
pippin reminders list "Work" --format agent

# Search notes and contacts together
pippin notes search "Alice" --format json
pippin contacts search "Alice" --format json
```

---

## Requirements

- **macOS 15+ (Sequoia)** or later (tested on macOS 26 Tahoe)
- **Swift 6.2+** — source builds only; pre-built binaries are arm64
- **Node.js + Playwright** — required for `pippin browser` only
- **mlx-audio** — required for `pippin audio` and `pippin memos transcribe`

---

## Development

```bash
swift build          # Debug build
swift test           # Run tests
make build           # Release build
make test            # Run tests (914 tests, 0 failures)
make lint            # swiftformat lint
make install         # Build release + install to ~/.local/bin/pippin
make release         # Build release binary in .build/release-artifacts/
make version         # Print current version
```

---

## Architecture

| Component | Description |
|---|---|
| `pippin-entry/` | `@main` entry point — thin executable target |
| `pippin/Commands/` | ArgumentParser subcommand structs |
| `pippin/MailBridge/` | JXA script builder and runner for Mail.app |
| `pippin/MemosBridge/` | GRDB read-only SQLite access to Voice Memos database |
| `pippin/CalendarBridge/` | EventKit wrapper for Calendar CRUD |
| `pippin/RemindersBridge/` | EventKit wrapper for Reminders CRUD |
| `pippin/NotesBridge/` | JXA subprocess bridge for Notes.app |
| `pippin/ContactsBridge/` | CNContactStore wrapper (read-only) |
| `pippin/AudioBridge/` | mlx-audio Python subprocess (TTS/STT) |
| `pippin/BrowserBridge/` | Playwright WebKit Node.js subprocess with persistent session |
| `pippin/AIProvider/` | Ollama + Claude backends for summarization |
| `pippin/Formatting/` | Text table/card formatters, JSON output, agent compact output |
| `pippin/Models/` | Shared data models (Codable + Sendable) |
| `Tests/PippinTests/` | Unit tests |

Key patterns:
- **Mail message IDs** use a compound format: `account||mailbox||numericId`
- **Agent output** (`--format agent`) uses compact JSON via `printAgentJSON<T>()` — no whitespace, minimal tokens
- **JXA bridges** (Mail, Notes) shell out to `osascript -l JavaScript` with per-operation timeouts
- **EventKit bridges** (Calendar, Reminders) use EventKit directly via `EKEventStore`
- **Swift 6 strict concurrency** — fully enforced across the entire codebase

---

## License

Apache 2.0 — see [LICENSE](LICENSE).
