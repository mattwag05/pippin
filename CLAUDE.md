# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project: Pippin

macOS CLI toolkit bridging Apple's sandboxed apps to automation pipelines. Built in Xcode with Claude Code assistance.

**Current status:** Design phase — skeleton Xcode project created, implementation not started. Spec: `macos-cli-automation-plan.md`.

**Xcode project:** `pippin.xcodeproj` — single target `pippin` (command-line tool, macOS). Entry point: `pippin/main.swift`. No `Package.swift` yet — build via Xcode GUI (Cmd+B) or `xcodebuild`.

## What This Builds

Two native CLI tools with JSON stdout output, headless-safe (cron/launchd/N8N compatible):

- **`pippin mail`** — Swift CLI subcommands for Apple Mail via osascript (`list`, `search`, `read`, `send`, `move`, `mark`)
- **`pippin memos`** — Python CLI for Voice Memos via direct SQLite read (`list`, `export`, `delete`, `info`)

## Build Workflow

**Current (Xcode project, no SPM):**
```bash
open pippin.xcodeproj              # open in Xcode
# Cmd+B to build, Cmd+R to run
xcodebuild -scheme pippin build    # headless build
# Find and smoke-test the binary:
$(xcodebuild -scheme pippin -showBuildSettings 2>/dev/null | awk '/BUILT_PRODUCTS_DIR/{print $3}')/pippin --help
```

**Once Package.swift is added (future):**
```bash
swift build                        # CLI build
swift run pippin mail list         # run subcommand
swift test                         # run tests
brew install swiftformat           # auto-format hook (install once)
```

## macOS Permissions Prerequisites

Before any implementation can be tested, grant these in **System Settings → Privacy & Security**:
- **Full Disk Access** → Terminal.app (Voice Memos SQLite + osascript in launchd)
- **Automation → Mail** → Terminal.app (required for any `pippin mail` osascript calls)

Run each subcommand once interactively after granting — macOS requires a live approval prompt before launchd/cron calls work.

## Architecture

### mail-cli (Swift)
- **`MailBridge` module** — all osascript calls isolated here; zero AppleScript outside this module
- Uses `Process` to shell out to `osascript` (not `NSAppleScript` — headless-safe)
- Uses Swift ArgumentParser for subcommand dispatch
- Output schema: `{id, account, mailbox, subject, from, to[], date (ISO8601), read, body?}`
- `--dry-run` flag required on all write operations
- Performance target: `<3 sec` per call

### voicememos-cli (Python)
- Single-file script, installed via `pipx`
- `VoiceMemosDB` class reads `~/Library/Application Support/com.apple.voicememos/*.sqlite` directly
- **Schema version guard on init** — raises `RuntimeError` if schema version is unknown (see `voicememos-schema` skill)
- Core Data epoch: seconds since 2001-01-01 UTC (not Unix epoch)
- Optional transcription: `whisper` → `SFSpeechRecognizer` fallback
- Export naming: `YYYY-MM-DD_title.m4a`
- Performance target: `<2 sec` list

### Foundation toolset (install first, per plan)
`icalpal`, `reminders-cli`, `contacts-cli`, `imsg`, `imessage-exporter`, `macnotesapp`, `tag`, `osxmetadata`, `trash`, `duti`, `blueutil`, `mas`, `terminal-notifier` — all require Full Disk Access + relevant permissions granted to Terminal.

Install commands: **`macos-cli-automation-plan.md` → Part 1** (all brew/gem/pipx one-liners in order).

## Automations Configured

### MCP Servers
- **context7** (global) — live Swift ArgumentParser + Python sqlite3 docs. Use via `use context7` in prompts.

### Skills (invoke with `/skill-name`)
- **`/mail-bridge-scaffold`** — scaffolds a new MailBridge method + ArgumentParser subcommand + JSON output struct for a new `pippin mail` subcommand
- **`/voicememos-schema`** — inspects the live Voice Memos SQLite schema and maps columns to the `VoiceMemosDB` output types; run when starting memos development or after an OS update

### Hooks (planned — `.claude/settings.json` not yet created)
- **PreToolUse**: Will block any `Bash`/`Write` targeting `com.apple.voicememos` path — Voice Memos DB is read-only
- **PostToolUse**: Will run `swiftformat` on `.swift` files after edit/write (no-ops if not installed; `brew install swiftformat`)

### Subagent
- **`applescript-security-reviewer`** — reviews `MailBridge` methods for injection, privilege creep, error leakage, and headless safety; invoke after adding/modifying any MailBridge method

## Implementation Order (per spec)

1. **Foundation toolset** — install all brew/gem/pipx tools from `macos-cli-automation-plan.md` Part 1
2. **`pippin mail`** — Swift CLI; start with `MailBridge` scaffold, then ArgumentParser subcommands
3. **`pippin memos`** — Python single-file script; start with `VoiceMemosDB` class + schema guard

## Non-Goals (per spec)
- No TUI or interactive UI
- No HTML email composition
- No Voice Memos recording or iCloud sync management
- No real-time watch mode (post-MVP)
- No iOS/cross-platform support
