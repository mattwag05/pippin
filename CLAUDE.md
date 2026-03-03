# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project: Pippin

macOS CLI toolkit bridging Apple's sandboxed apps to automation pipelines. Single arm64 binary, headless-safe (cron/launchd/N8N compatible).

**Current status:** v0.1.0-beta — all mail and memos subcommands implemented. Python dependency eliminated; memos rewritten in Swift with GRDB.

## What This Builds

- **`pippin mail`** — Swift CLI for Apple Mail via osascript JXA (`list`, `search`, `show`, `send`, `move`, `mark`, `accounts`)
- **`pippin memos`** — Swift CLI for Voice Memos via GRDB read-only SQLite (`list`, `info`, `export`)
- **`pippin doctor`** / **`pippin init`** — Permission diagnostics and guided setup

## Build Workflow

```bash
swift build                        # Debug build
swift build -c release             # Release build
swift run pippin mail list         # Run subcommand (debug)
swift test                         # Run 126 tests

# Makefile targets
make build     # swift build -c release
make test      # swift test
make lint      # swiftformat --lint (requires brew install swiftformat)
make install   # Release build + install to ~/.local/bin/pippin
make release   # Release binary → .build/release-artifacts/
make version   # Print version from Version.swift
make clean     # Clean build artifacts
```

> **SourceKit false positives:** Xcode's SourceKit can't see SPM dependencies (GRDB, ArgumentParser, cross-file types). Ignore red squiggles in the IDE — `swift build` is authoritative.

## macOS Permissions Prerequisites

Before any implementation can be tested, grant these in **System Settings → Privacy & Security**:
- **Full Disk Access** → Terminal.app (Voice Memos SQLite + osascript in launchd)
- **Automation → Mail** → Terminal.app (for `swift run` / interactive testing)
- **Automation → Mail** → the built `pippin` binary (for cron/launchd — re-grant after each new build path)

Run each subcommand once interactively after granting — macOS requires a live approval prompt before launchd/cron calls work.

> **TCC note:** Permission is per binary path. `swift run` wrapper and installed binary are separate — each needs its own grant.

## Package Structure

```
pippin/                     # PippinLib target (all application logic)
  Commands/                 # ArgumentParser subcommand structs
    MailCommand.swift       # mail subcommands
    MemosCommand.swift      # memos subcommands
    DoctorCommand.swift     # doctor + shared runAllChecks()
    InitCommand.swift       # init (guided setup)
    OutputOptions.swift     # shared --format text|json
  Formatting/
    TextFormatter.swift     # table/card/truncate/duration/compactDate
    JSONOutput.swift        # shared printJSON<T>()
  MailBridge/
    MailBridge.swift        # JXA process runner, all script builders
  MemosBridge/
    VoiceMemosDB.swift      # GRDB read-only DB access
    Transcriber.swift       # parakeet-mlx + SFSpeechRecognizer strategy
  Models/
    MailModels.swift        # MailMessage, MailAccount, MailActionResult
    MemosModels.swift       # VoiceMemo, ExportResult (GRDB FetchableRecord)
  Version.swift             # PippinVersion.version = "0.1.0-beta"
pippin-entry/
  Pippin.swift              # @main entry point
Tests/PippinTests/          # 126 tests
archive/pippin-memos/       # Archived Python implementation
docs/archive/               # Archived planning documents
```

## Architecture

### mail (Swift + JXA)
- **`MailBridge`** — all JXA calls isolated here; uses `osascript -l JavaScript` (not AppleScript)
- Uses `Process` to shell out to `osascript` (headless-safe; concurrent pipe draining prevents deadlock)
- Output schema: `{id, account, mailbox, subject, from, to[], date (ISO8601), read, body?}`
- Message ID format: `account||mailbox||messageId` (compound, round-trip safe)
- `jsEscape()` escapes in order: `\`, `\0`, `"`, `'`, `` ` ``, `\n`, `\r`, `\u2028`, `\u2029`
- `mb.messages.whose({})()` is **invalid JXA** — use `mb.messages()` for unfiltered fetch
- Timeouts: 10s (list/show/accounts), 30s (search), 20s (mark), 45s (move/send)
- `--dry-run` flag required on all write operations
- Performance target: `<3 sec` per call

### memos (Swift + GRDB)
- **`VoiceMemosDB`** — read-only `DatabaseQueue` (`configuration.readonly = true`)
- **DB path (macOS 14+):** `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db`
- **Table:** `ZCLOUDRECORDING` — key columns: `ZUNIQUEID`, `ZCUSTOMLABELFORSORTING`, `ZDURATION`, `ZDATE`, `ZPATH`, `ZEVICTIONDATE`
- **`Z_VERSION`:** 1 (macOS 26 Tahoe). Update `knownSchemaVersions` in `VoiceMemosDB.swift` after OS updates.
- **File formats:** `.m4a` (older) and `.qta` (newer, macOS 14+)
- Core Data epoch: `Date(timeIntervalSinceReferenceDate:)` handles 2001-01-01 offset automatically
- Export naming: `YYYY-MM-DD_sanitized-title.<ext>` with collision suffix (-2, -3…)
- Performance target: `<2 sec` list

### Concurrency
- `swift-tools-version: 6.0` with `.swiftLanguageMode(.v5)` — strict concurrency not enforced yet
- Existing GCD patterns in `MailBridge.runScript()` work under Swift 5 language mode
- Migration path: adopt `@concurrent` and `withCheckedContinuation` in a future PR when ready for Swift 6 strict concurrency

## Versioning

`pippin/Version.swift` holds the canonical version string. Update it before any release commit.

Format: `MAJOR.MINOR.PATCH[-prerelease]`

- `0.1.0-beta` → `0.1.0` when beta testing complete
- `0.1.x` → bug fixes; `0.2.0` → new features or breaking changes
- `1.0.0` → CLI interface frozen, output schemas stable

## Non-Goals (per spec)
- No TUI or interactive UI
- No HTML email composition
- No Voice Memos recording or iCloud sync management
- No real-time watch mode (post-MVP)
- No iOS/cross-platform support
- `memos delete` — deferred to v0.2 (sandboxing concerns)

> **Note:** Project-level `.claude/` skills, hooks, and agents were removed in PR #6. No local hooks are active — `swiftformat` and `swift build` must be run manually.

## Workflow Gotchas

### Creating PRs on Forgejo
`gh pr create` fails with `HTTP 405` (Forgejo doesn't support GitHub's GraphQL API). Use curl + Forgejo REST API with Basic auth:
```bash
curl -s -X POST "https://forgejo.tail6e035b.ts.net/api/v1/repos/matthewwagner/pippin/pulls" \
  -H "Content-Type: application/json" \
  -H "Authorization: Basic $(echo -n 'matthewwagner:<token>' | base64)" \
  -d '{"title":"...","head":"branch","base":"main","body":"..."}'
```
Token: Vaultwarden "Forgejo Admin Credentials" (password field). Bearer token auth ("token <tok>") fails with "user does not exist" — Basic auth only.

### Test Assertions on Temp Paths
`result.contains("-2")` on export paths will fail intermittently — UUID-based tmpDir names can contain "-2" (e.g. `F6-2789`). Always assert on `lastPathComponent`:
```swift
XCTAssertEqual((result as NSString).lastPathComponent, "expected.m4a")
```

### GRDB Nullable Columns
`fetchOne` on a nullable column returns `Optional<Optional<T>>` — ambiguous for null vs missing row. Use `COUNT(*) WHERE col IS NOT NULL` instead:
```swift
// See VoiceMemosDB.isEvicted() for the pattern
let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ... WHERE ZEVICTIONDATE IS NOT NULL AND ZUNIQUEID = ?", arguments: [id])!
return count > 0
```

## Git Remotes

- `origin` → `https://github.com/mattwag05/pippin.git` (public, default push)
- `forgejo` → `https://forgejo.tail6e035b.ts.net/matthewwagner/pippin.git` (private mirror)
- Push to both after releases: `git push origin main && git push forgejo main`

### Releasing

- `make release` → `.build/release-artifacts/pippin-VERSION-arm64-macos`
- `gh release create` requires **absolute paths** for artifact upload (relative paths fail — zsh cwd reset)
- Tag format: `v0.1.0-beta` (with `v` prefix)

## Homebrew Tap

- Tap repo: `https://github.com/mattwag05/homebrew-tap` (Formula/pippin.rb)
- Install: `brew install mattwag05/tap/pippin` (builds from source via SPM, ~30s)
- Formula uses `--disable-sandbox` — required for SPM network access during `swift build`
- Update formula `revision:` field after each new tag: `git rev-parse <tag>`
