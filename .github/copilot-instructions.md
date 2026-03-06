# Copilot Instructions for Pippin

## Project Overview

Pippin is a macOS CLI toolkit (single `arm64` binary) that bridges Apple's sandboxed apps to automation pipelines. It is headless-safe and compatible with cron/launchd/N8N.

**Language/Runtime:** Swift 6.0, macOS 15+, SPM (Swift Package Manager)  
**Key dependencies:** `swift-argument-parser` ≥ 1.5.0, `GRDB.swift` ≥ 7.0.0

### Subcommands

- `pippin mail` — Apple Mail via `osascript` JXA (`accounts`, `mailboxes`, `list`, `search`, `show`, `send`, `move`, `mark`)
- `pippin memos` — Voice Memos via read-only GRDB/SQLite (`list`, `info`, `export`)
- `pippin completions <shell>` — generate zsh/bash/fish completion scripts
- `pippin doctor` / `pippin init` — permission diagnostics and guided setup

---

## Repository Layout

```
Package.swift               # SPM manifest (swift-tools-version: 6.0)
Makefile                    # build/test/lint/install helpers
pippin/                     # PippinLib target — all application logic
  Commands/                 # ArgumentParser subcommand structs
    MailCommand.swift
    MemosCommand.swift
    DoctorCommand.swift
    InitCommand.swift
    OutputOptions.swift     # shared --format text|json
  Formatting/
    TextFormatter.swift
    JSONOutput.swift
  MailBridge/
    MailBridge.swift        # osascript JXA runner + all script builders
  MemosBridge/
    VoiceMemosDB.swift      # GRDB read-only DatabaseQueue
    Transcriber.swift
  Models/
    MailModels.swift        # MailMessage, MailAccount, MailActionResult
    MemosModels.swift       # VoiceMemo, ExportResult
  Version.swift             # PippinVersion.version = "0.1.0"
pippin-entry/
  Pippin.swift              # @main entry point
Tests/PippinTests/          # ~228 tests
.github/
  workflows/ci.yml          # CI: build → test → release build → swiftformat lint
```

---

## Build, Test, and Lint

> These commands are validated for macOS with Xcode/Swift toolchain installed.

```bash
# Debug build
swift build

# Release build
swift build -c release

# Run tests (run `swift build` first so CLIIntegrationTests can locate the binary)
swift build && swift test

# Lint (requires: brew install swiftformat)
swiftformat --lint pippin/ pippin-entry/ Tests/

# Auto-fix formatting issues (run before pushing)
swiftformat pippin/ pippin-entry/ Tests/

# Makefile shortcuts
make build        # swift build -c release
make test         # swift test
make lint         # swiftformat --lint on all three dirs
make install      # release build + completions + install to ~/.local/bin/pippin
make clean        # clean build artifacts
```

**Always lint all three directories together:** `pippin/ pippin-entry/ Tests/`  
Linting only one dir can miss cross-dir issues and won't match CI.

---

## CI Pipeline (`.github/workflows/ci.yml`)

Runs on every push/PR to `main` on `macos-15`:

1. `swift build` (debug)
2. `swift test`
3. `swift build -c release`
4. `brew install swiftformat && swiftformat --lint pippin/ pippin-entry/ Tests/`

**A PR will fail CI if:**
- The code does not compile (debug or release)
- Any test fails
- `swiftformat --lint` reports formatting issues — always run `swiftformat pippin/ pippin-entry/ Tests/` (no `--lint`) to auto-fix before pushing

---

## Architecture Notes

### Swift Concurrency (Swift 6 strict mode)
- `.swiftLanguageMode(.v6)` is enforced across all targets — strict concurrency is on
- All model structs and error enums must conform to `Sendable`
- `VoiceMemosDB` is `final class: Sendable` (all-`let` stored properties)
- Mutable GCD output buffers in `MailBridge` and `Transcriber` use `nonisolated(unsafe) var` — safe because each is written once before `group.wait()`
- Mutable `static var` in `XCTestCase` requires `nonisolated(unsafe)` under Swift 6

### mail (JXA via osascript)
- All JXA calls are in `MailBridge.swift`; uses `osascript -l JavaScript` (not AppleScript)
- Message ID: `account||mailbox||messageId` (compound, round-trip safe)
- `jsEscape()` escapes in order: `\`, `\0`, `"`, `'`, `` ` ``, `\n`, `\r`, `\u2028`, `\u2029`
- Use `mb.messages()` for unfiltered fetch — `mb.messages.whose({})()` is **invalid JXA**
- Timeouts: 10s (list/show/accounts), 30s (search), 20s (mark), 45s (move/send)
- All write operations require `--dry-run` flag

### memos (GRDB/SQLite)
- `VoiceMemosDB` opens a read-only `DatabaseQueue` (`configuration.readonly = true`)
- DB path: `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db`
- Table: `ZCLOUDRECORDING`; key columns: `ZUNIQUEID`, `ZCUSTOMLABELFORSORTING`, `ZDURATION`, `ZDATE`, `ZPATH`, `ZEVICTIONDATE`
- Core Data epoch offset is handled by `Date(timeIntervalSinceReferenceDate:)` automatically
- Export filename format: `YYYY-MM-DD_sanitized-title.<ext>` with collision suffix (-2, -3…)

### New Optional Fields on MailMessage
Always add an explicit `public init(...)` with `= nil` defaults — Swift's synthesized memberwise init does NOT provide default `nil` for `Optional` properties. Use `encodeIfPresent` for new optional fields; only `body` uses `encode` (forces explicit `null` in JSON).

### GRDB Nullable Columns
Use `COUNT(*) WHERE col IS NOT NULL` instead of `fetchOne` on a nullable column to avoid `Optional<Optional<T>>` ambiguity.

---

## Test Notes

- `CLIIntegrationTests` calls `swift build --show-bin-path` in `class setUp()` to find the binary — always run `swift build` before `swift test`
- Use `#filePath` (not `#file`) for `XCTFail` file parameter under Swift 6
- Assert on `lastPathComponent` when checking export paths — UUID-based temp dir names can contain `-2`

---

## SourceKit / IDE

SourceKit can't resolve SPM dependencies or cross-file types — ignore red squiggles. Run `swift build` to verify correctness.
