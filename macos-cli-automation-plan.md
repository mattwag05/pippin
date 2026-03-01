# macOS CLI Automation: Install Plan + MVP PRDs

---

## Part 1: Tools to Install

Install everything below in one pass. This covers Calendar, Reminders, Contacts, Messages, Notes, Finder/metadata, and general macOS scripting utilities — leaving Mail and Voice Memos for the custom CLIs described in Parts 2 and 3.

### Core Apple App CLIs

```bash
# Calendar (read-only, JSON/CSV/YAML/XML/Markdown output, reads Calendar.app SQLite directly)
gem install icalpal

# Reminders (full CRUD, JSON output, battle-tested)
brew install keith/formulae/reminders-cli

# Contacts (query by name, returns name/email pairs — simple but reliable)
brew install keith/formulae/contacts-cli

# Messages — live watch + send + history with JSON output
brew install steipete/tap/imsg

# Messages — bulk export/archival to HTML/TXT (separate use case from imsg)
brew install imessage-exporter

# Notes — full CRUD, JSON output, folder management
brew tap RhetTbull/macnotesapp && brew install macnotesapp

# Finder tags — add/remove/search tags on files
brew install tag
```

### File & System Utilities

```bash
# Broad macOS file metadata (Finder comments, where-from URLs, MDItem attributes, JSON output)
pipx install osxmetadata

# Move to Trash safely (preserves "Put Back" — use instead of rm for user files)
brew install trash

# Set default apps for file types/URL schemes (useful for scripted system config)
brew install duti

# Bluetooth power + device management with --format json
brew install blueutil

# Mac App Store CLI — install, update, search apps
brew install mas
```

### Notification & Scripting

```bash
# Send macOS notifications from scripts with custom titles, sounds, and actions
brew install terminal-notifier

# Swift scripting with inline dependencies (for building custom tools, see Parts 2–3)
brew install mxcl/made/swift-sh
```

### Post-Install: Grant Permissions

After installing, run each tool once interactively so macOS prompts you for the right permissions. The critical ones are:

- **Full Disk Access** → Terminal.app (required for imsg, imessage-exporter, icalPal)
- **Contacts** → Terminal.app (contacts-cli)
- **Reminders** → Terminal.app (reminders-cli)
- **Calendar** → Terminal.app (icalPal, if using EventKit path)

Grant these in **System Settings → Privacy & Security**, not just at the prompt, so they persist for cron/launchd jobs.

---

## Part 2: MVP PRD — `mail-cli`

### Summary

A native macOS command-line tool for reading and sending Apple Mail messages with structured JSON output, enabling Mail.app to participate in N8N workflows, shell pipelines, and homelab automation — filling the gap left by the absence of any existing brew-installable Mail CLI.

### Problem

Apple Mail has no CLI interface. The only current bridge is `osascript` with AppleScript, which is verbose, produces unstructured text output, and has a history of breaking silently across macOS updates. This makes Mail.app effectively invisible to scripted workflows even though it's the primary email client.

### Goals

- Read messages (list, search, get body/metadata) from any mailbox or account
- Send messages with subject, body, To/CC/BCC, and optional file attachments
- Mark messages as read/unread and move them between mailboxes
- Output all read operations as structured JSON consumable by `jq` and N8N
- Work reliably headlessly (cron, launchd, N8N Execute Command node)

### Non-Goals

- No UI, no TUI, no interactive mode
- No calendar/contacts integration (separate tools handle those)
- No HTML email composition (plain text and file attachments only at MVP)
- No email rule management or plugin system
- No support for non-Apple-Mail email clients

### Implementation Approach

Build in **Swift** using `osascript` as the underlying bridge but wrapped in a structured, testable Swift CLI layer. The Swift layer handles argument parsing, output formatting, error handling, and retry logic. Raw `osascript` calls are confined to a single `MailBridge` module, making them easy to replace if Apple improves its API surface.

Use **ArgumentParser** (Swift package) for subcommands. All read commands emit JSON to stdout; errors go to stderr with an exit code. A `--dry-run` flag on write operations prints what would happen without executing.

### CLI Interface

```
mail-cli accounts                          # list configured Mail accounts
mail-cli list [--account x] [--mailbox x] [--unread] [--limit 20]
mail-cli search <query> [--account x] [--limit 10]
mail-cli read <message-id>                 # full message with headers + body
mail-cli send --to x --subject x --body x [--cc x] [--attach path]
mail-cli move <message-id> --to <mailbox>
mail-cli mark <message-id> --read / --unread
```

### Output Schema (list/search/read)

```json
{
  "id": "string",
  "account": "string",
  "mailbox": "string",
  "subject": "string",
  "from": "string",
  "to": ["string"],
  "date": "ISO8601",
  "read": true,
  "body": "string"   // only in `read` subcommand
}
```

### Success Criteria

- `mail-cli list --unread --limit 10` returns valid JSON in under 3 seconds
- `mail-cli send` successfully delivers a message from a cron job context
- No crashes on malformed messages or empty mailboxes
- Works on macOS 14+ with Full Disk Access granted to terminal

---

## Part 3: MVP PRD — `voicememos-cli`

### Summary

A macOS command-line tool for listing, exporting, and optionally transcribing Voice Memos by reading the app's internal SQLite database and media file store — enabling Voice Memos to be used as a quick capture mechanism that feeds into automation pipelines.

### Problem

Voice Memos has no API and no AppleScript dictionary. Recordings accumulate with auto-generated names and no structured access, making them invisible to any workflow tooling. The primary pain point is the inability to export recordings with meaningful filenames or trigger post-capture automation (e.g., transcription, archival to a notes system).

### Goals

- List all Voice Memos with metadata (title, duration, creation date, file path) as JSON
- Export individual or all recordings to a specified directory with human-readable filenames
- Delete recordings by ID
- Optionally trigger transcription via macOS built-in speech recognition or a local Whisper model on export
- Output structured JSON for all read operations

### Non-Goals

- No recording capability (use the Voice Memos app for capture)
- No iCloud sync management
- No real-time watch/trigger mode at MVP (post-MVP consideration)
- No audio editing or format conversion beyond what macOS provides natively
- No support for iOS Voice Memos backups (macOS library only at MVP)

### Implementation Approach

Build in **Python** (not Swift) because the core data access is SQLite queries against `~/Library/Application Support/com.apple.voicememos/Recordings/` and the database schema, not a framework API. Python's `sqlite3` stdlib handles this cleanly, and `subprocess` can call `whisper` or macOS `SpeechRecognition` for the optional transcription path.

Package as a single-file script with `argparse` and a `pipx install` workflow for clean isolation. The SQLite schema is internal and undocumented, so isolate all schema assumptions in a `VoiceMemosDB` class with a version check against the known macOS 14/15 schema — this is the most likely breakage point across OS updates and should fail loudly with a clear error message rather than silently returning wrong data.

### CLI Interface

```
voicememos list [--format json] [--since YYYY-MM-DD]
voicememos export <id|--all> --output <dir> [--transcribe]
voicememos delete <id>
voicememos info <id>         # full metadata including file path
```

### Output Schema (list)

```json
{
  "id": "string",
  "title": "string",
  "duration_seconds": 142,
  "created_at": "ISO8601",
  "file_path": "string",
  "transcription": "string | null"
}
```

### Transcription Strategy

At export time, if `--transcribe` is passed, the tool checks for a local `whisper` binary (`brew install openai-whisper`) and uses it if available. If not present, it falls back to macOS built-in `SFSpeechRecognizer` via a small Swift helper shim. Transcription results are written as `.txt` sidecar files alongside exported audio and optionally included in JSON output.

### Success Criteria

- `voicememos list --format json` returns valid JSON for all recordings in under 2 seconds
- `voicememos export --all --output ~/exports` exports all recordings with `YYYY-MM-DD_title.m4a` naming
- Graceful, descriptive error on schema version mismatch (macOS update scenario)
- Works without any special permissions beyond Full Disk Access for terminal
