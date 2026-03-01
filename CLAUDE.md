# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project: Pippin

macOS CLI toolkit bridging Apple's sandboxed apps to automation pipelines. Built in Xcode with Claude Code assistance.

**Current status:** All `pippin mail` subcommands implemented (PR #1–#4 merged). `pippin memos list/info/export` (PR #2) implemented. Spec: `macos-cli-automation-plan.md`.

**Xcode project:** `pippin.xcodeproj` — single target `pippin`. Entry point: `pippin/Pippin.swift` (`@main`; renamed from `main.swift` for SPM compatibility). `Package.swift` added (ArgumentParser 1.7.0).

## What This Builds

Two native CLI tools with JSON stdout output, headless-safe (cron/launchd/N8N compatible):

- **`pippin mail`** — Swift CLI subcommands for Apple Mail via osascript (`list`, `search`, `read`, `send`, `move`, `mark`)
- **`pippin memos`** — Python CLI for Voice Memos via direct SQLite read (`list`, `export`, `delete`, `info`)

## Build Workflow

```bash
swift build                        # CLI build
swift build --show-bin-path        # → .build/arm64-apple-macosx/debug/
swift run pippin mail list         # run subcommand
swift test                         # run tests
brew install swiftformat           # auto-format hook (install once)
```

> **SourceKit false positives:** Xcode's SourceKit can't see SPM dependencies (ArgumentParser, cross-file types). Ignore red squiggles in the IDE — `swift build` is the authoritative check.

## macOS Permissions Prerequisites

Before any implementation can be tested, grant these in **System Settings → Privacy & Security**:
- **Full Disk Access** → Terminal.app (Voice Memos SQLite + osascript in launchd)
- **Automation → Mail** → Terminal.app (for `swift run` / interactive testing)
- **Automation → Mail** → the built `pippin` binary (for cron/launchd — re-grant after each new build path)

Run each subcommand once interactively after granting — macOS requires a live approval prompt before launchd/cron calls work.

> **TCC note:** Permission is per binary path. `swift run` wrapper and installed binary are separate — each needs its own grant. Run `pippin mail list` once interactively (not under launchd) after building at a new path.

> **TCC note for `mail send`:** Send requires Automation → Mail **write** access. If TCC is denied, `toRecipients.push()` silently no-ops and `msg.send()` throws a cryptic JXA error rather than a clear TCC message. Run `pippin mail send --dry-run ...` once interactively after each new build path to confirm the grant is active before scheduling.

## Architecture

### mail-cli (Swift)
- **`MailBridge` module** — all JXA calls isolated here; uses `osascript -l JavaScript` (not AppleScript, not NSAppleScript)
- Uses `Process` to shell out to `osascript` (headless-safe; concurrent pipe draining prevents deadlock on large output)
- Uses Swift ArgumentParser for subcommand dispatch
- Output schema: `{id, account, mailbox, subject, from, to[], date (ISO8601), read, body?}`
- Message ID format: `account||mailbox||messageId` (compound, round-trip safe)
- `jsEscape()` escapes: `\`, `\0`, `"`, `'`, `` ` ``, `\n`, `\r`, `\u2028`, `\u2029` — in that order (backslash first, null byte second)
- `mb.messages.whose({})()` is **invalid JXA** (exits 0, error on stderr) — use `mb.messages()` for unfiltered fetch; `mb.messages.whose({readStatus: false})()` for unread-only
- `runScript()` timeout is per-operation: default 10s (list/read/accounts), 30s (search), 20s (mark), 45s (move/send) — pass `timeoutSeconds:` explicitly for new write ops
- JXA file attachment paths: use `Path(absolutePath)` in `mail.Attachment({fileName: Path(...)})` — plain string `fileName` fails to resolve POSIX paths under launchd
- `msg.send()` throws on SMTP rejection; that is sufficient for success detection — do NOT check `outgoingMessages` queue length post-send (Mail.app send-delay keeps message in queue until delay expires, causing false failures)
- Cold-launch poll: 8 attempts for read-only ops, 20 attempts (10s) for write ops
- Cleanup staged `OutgoingMessage` by object reference (`msg.delete()`), not by positional index or subject match
- `--dry-run` flag required on all write operations
- Performance target: `<3 sec` per call

### voicememos-cli (Python)
- Single-file `pippin-memos/pippin_memos.py`, installed via `pipx install pippin-memos/`; binary at `~/.local/bin/pippin-memos`
- **DB path (macOS 14+):** `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db` (`.db` extension, not `.sqlite`; NOT the `Application Support` path)
- **Table:** `ZCLOUDRECORDING` — key columns: `ZUNIQUEID` (UUID string ID), `ZCUSTOMLABELFORSORTING` (title), `ZDATE` (Core Data epoch), `ZPATH` (filename relative to Recordings dir), `ZEVICTIONDATE` (non-null = iCloud-evicted)
- **`Z_VERSION`:** 1 (macOS 26 Tahoe). Update `KNOWN_SCHEMA_VERSIONS` in `pippin_memos.py` after OS updates.
- **File formats:** `.m4a` (older recordings) and `.qta` (newer, macOS 14+) — export preserves original extension
- **Schema version guard on init** — raises `RuntimeError` if version unknown (see `voicememos-schema` skill, but note: skill assumes old path — search Group Container manually)
- **`pyproject.toml`:** use `build-backend = "setuptools.build_meta"` — `setuptools.backends.legacy:build` fails on Python 3.14
- Core Data epoch: seconds since 2001-01-01 UTC (not Unix epoch)
- Export naming: `YYYY-MM-DD_title.<ext>`
- Performance target: `<2 sec` list

### Foundation toolset (install first, per plan)
✅ **Installed.** `icalpal`, `reminders-cli`, `contacts-cli`, `imsg`, `imessage-exporter`, `macnotesapp`, `tag`, `osxmetadata`, `trash`, `duti`, `blueutil`, `mas`, `terminal-notifier` — all require Full Disk Access + relevant permissions granted to Terminal.

Gotchas: `macnotesapp` brew tap is dead — use `pipx install macnotesapp` (command is `notes`). `icalPal` gem binary at `~/.gem/ruby/2.6.0/bin/icalPal` (not on default PATH).

## Automations Configured

### MCP Servers
- **context7** (global) — live Swift ArgumentParser + Python sqlite3 docs. Use via `use context7` in prompts.

### Skills (invoke with `/skill-name`)
- **`/mail-bridge-scaffold`** — scaffolds a new MailBridge method + ArgumentParser subcommand + JSON output struct for a new `pippin mail` subcommand
- **`/voicememos-schema`** — inspects the live Voice Memos SQLite schema and maps columns to the `VoiceMemosDB` output types; run when starting memos development or after an OS update
- **`/pippin-output-validator`** — builds the binary and validates a subcommand's JSON output matches its documented schema; run after implementation changes

### Hooks (active — `.claude/settings.json` configured)
- **PreToolUse** (`Bash|Edit|Write`): blocks any operation targeting `com.apple.voicememos` path — Voice Memos DB is read-only
- **PostToolUse** (`Edit|Write`): runs `swiftformat` on `.swift` files (no-ops if not installed; `brew install swiftformat`)
- **PostToolUse** (`Edit|Write`): runs `swift build` after any `.swift` edit — reports failures inline

### Agents
- **`applescript-security-reviewer`** — reviews `MailBridge` methods for injection, privilege creep, error leakage, and headless safety; invoke after adding/modifying any MailBridge method
- **`headless-compatibility-checker`** — checks osascript calls for launchd/cron failure modes (TCC assumptions, blocking ops, missing timeouts); invoke after any new MailBridge method

## Implementation Order (per spec)

1. ✅ **Foundation toolset** — installed
2. ✅ **`pippin mail`** — all subcommands implemented: `list`, `read` (PR #1), `accounts`, `search` (PR #3), `mark`, `move`, `send` (PR #4) on Forgejo
3. ✅ **`pippin memos`** — `list`, `info`, `export` implemented (PR #2 on Forgejo)

## Non-Goals (per spec)
- No TUI or interactive UI
- No HTML email composition
- No Voice Memos recording or iCloud sync management
- No real-time watch mode (post-MVP)
- No iOS/cross-platform support
