# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project: Pippin

macOS CLI toolkit bridging Apple's sandboxed apps to automation pipelines. Single arm64 binary, headless-safe (cron/launchd/N8N compatible).

**Current status:** v0.1.3-beta — all mail and memos subcommands implemented. Python dependency eliminated; memos rewritten in Swift with GRDB.

## What This Builds

- **`pippin mail`** — Swift CLI for Apple Mail via osascript JXA (`accounts`, `mailboxes`, `list`, `search`, `show`, `send`, `move`, `mark`)
- **`pippin memos`** — Swift CLI for Voice Memos via GRDB read-only SQLite (`list`, `info`, `export`)
- **`pippin doctor`** / **`pippin init`** — Permission diagnostics and guided setup

## Build Workflow

```bash
swift build                        # Debug build
swift build -c release             # Release build
swift run pippin mail list         # Run subcommand (debug)
swift test                         # Run 216 tests

# Makefile targets
make build     # swift build -c release
make test      # swift test
make lint        # swiftformat --lint (requires brew install swiftformat)
make completions # Generate zsh completion script → ~/.zfunc/_pippin
make install     # Release build + completions + install to ~/.local/bin/pippin
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
  Version.swift             # PippinVersion.version = "0.1.3-beta"
pippin-entry/
  Pippin.swift              # @main entry point
Tests/PippinTests/          # 216 tests (models + JXAScriptBuilderTests + CLIIntegrationTests)
archive/pippin-memos/       # Archived Python implementation
docs/archive/               # Archived planning documents
```

## Architecture

### mail (Swift + JXA)
- **`MailBridge`** — all JXA calls isolated here; uses `osascript -l JavaScript` (not AppleScript)
- Uses `Process` to shell out to `osascript` (headless-safe; concurrent pipe draining prevents deadlock)
- Output schema: envelope `{id, account, mailbox, subject, from, to[], date (ISO8601), read, body?, size?, hasAttachment?}`; detail (`show`) adds `{htmlBody?, headers?, attachments?[{name, mimeType, size}]}`
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
- `swift-tools-version: 6.0` with `.swiftLanguageMode(.v6)` — strict concurrency fully enforced
- All model structs and error enums conform to `Sendable`; `VoiceMemosDB` is `final class: Sendable` (all-`let` stored properties)
- GCD pipe-draining pattern in `MailBridge.runScript()` and `ParakeetTranscriber.transcribe()` uses `nonisolated(unsafe) var` for the output `Data` buffers — safe because each var is written exactly once by one GCD block, and `group.wait()` provides a happens-before guarantee before the values are read
- `Process` is `Sendable` in Foundation; no `nonisolated(unsafe)` needed for the timeout `DispatchWorkItem` capture
- Mutable `static var` in XCTestCase requires `nonisolated(unsafe)` under Swift 6; use `#filePath` (not `#file`) for `XCTFail` file parameter

## Versioning

`pippin/Version.swift` holds the canonical version string. Update it before any release commit.

Format: `MAJOR.MINOR.PATCH[-prerelease]`

- `0.1.0-beta` → `0.1.0` when beta testing complete
- `0.1.x` → bug fixes or non-behavioral improvements (tooling, build quality); `0.2.0` → new features or breaking changes
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

### swiftformat Enforcement
CI now enforces `swiftformat --lint` on both GitHub Actions and Forgejo. Run `swiftformat pippin/ pippin-entry/ Tests/` (no `--lint`) to auto-fix before pushing. The `swiftformat` warning about missing Swift version is harmless — no `.swift-version` file is needed.

### CLI Integration Tests Require a Prior Build
`CLIIntegrationTests` calls `swift build --show-bin-path` in `class setUp()` to locate the binary. In CI the build step precedes `swift test` so this is a no-op. Locally, run `swift build` before `swift test` if you want CLI tests to run (they skip gracefully if binary is absent).

### Batch Branch Deletion on Forgejo
`git push forgejo --delete branch1 branch2 ...` aborts entirely if any one branch doesn't exist — it won't delete the rest. Remove the missing branch from the list and re-run.

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

### MailMessage Optional Fields
New optional fields on `MailMessage` require an explicit `public init(...)` with `= nil` defaults — Swift's synthesized memberwise init does NOT provide default `nil` for `Optional` properties. Use `encodeIfPresent` for new fields (omits key when nil, keeps envelope JSON compact); only `body` uses `encode` to force an explicit JSON `null`.

### JXA Mail Metadata APIs
Reliable JXA accessors for enriched output: `msg.messageSize()`, `msg.mailAttachments()` (array), `mb.unreadCount()`, `msg.htmlContent()` (null on plain-text), `msg.allHeaders()` (raw RFC 2822 string). All require try/catch — they throw on some IMAP server types.

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
- After tagging, update `revision:` in Homebrew formula with exact `git rev-parse <tag>` output — verify hash character-for-character before committing formula

## Homebrew Tap

- Tap repo: `https://github.com/mattwag05/homebrew-tap` (Formula/pippin.rb)
- Install: `brew install mattwag05/tap/pippin` (builds from source via SPM, ~30s)
- Formula uses `--disable-sandbox` — required for SPM network access during `swift build`
- Update formula `revision:` field after each new tag: `git rev-parse <tag>`
- Also update the version string in the formula's `test do` block to match.
- Tap local path: `/opt/homebrew/Library/Taps/mattwag05/homebrew-tap`
