# Copilot Instructions for Pippin

## Project Overview

Pippin is a macOS CLI toolkit (single `arm64` binary) that bridges Apple's sandboxed apps to automation pipelines. It is headless-safe and compatible with cron/launchd/MCP clients.

**Language/Runtime:** Swift 6.0, macOS 15+, SPM (Swift Package Manager)
**Key dependencies:** `swift-argument-parser` 1.7.0, `GRDB.swift` 7.10.0 (see `Package.resolved` for exact pins)

> `CLAUDE.md` (repo root) and `README.md` are the authoritative, continuously-maintained references for the command surface and architecture. This file is a Copilot-specific summary — when in doubt, defer to those.

### Subcommands (top-level)

`mail`, `memos`, `calendar`, `contacts`, `reminders`, `notes`, `messages`, `actions`, `digest`, `doctor`, `status`, `init`, `completions`, `shell`, `mcp-server`, `batch`, `job`, `do`. `audio` and `browser` are **experimental** and only registered when `PIPPIN_EXPERIMENTAL=1` is set. The MCP tool surface (`pippin mcp-server`) is generated from `pippin/MCP/ToolRegistry.swift` — currently 44 tools.

---

## Repository Layout

```
Package.swift               # SPM manifest (swift-tools-version: 6.0)
Makefile                    # build/test/lint/ci/install helpers
pippin/                     # PippinLib target — all application logic
  Commands/                 # ArgumentParser subcommand structs (one file per command group)
  Formatting/               # AgentOutput (envelope v1), JSONOutput, TextFormatter, BridgeOutcome, Remediation
  MailBridge/               # osascript JXA runner + script builders (+ cross-account timeout scaling)
  MailAIBridge/             # embeddings, semantic search, triage, prompt-injection scanner (Ollama-backed)
  MemosBridge/              # GRDB read-only access to Voice Memos + transcription
  CalendarBridge/ RemindersBridge/   # EventKit wrappers
  NotesBridge/ ContactsBridge/       # JXA / CNContactStore wrappers
  MessagesBridge/           # GRDB read of chat.db + gated send + audit log
  BrowserBridge/ AudioBridge/        # experimental (PIPPIN_EXPERIMENTAL=1)
  AIProvider/               # Ollama + Claude backends
  Planner/                  # LLM plan-and-execute over the MCP tool registry (`pippin do`)
  Jobs/                     # filesystem-backed background-job registry (`pippin job`)
  Pagination/               # opaque-cursor tokens + filter-hash guards for list commands
  MCP/                      # ToolRegistry (tool surface), MCPServerRuntime, JSON-RPC types
  Models/                   # Codable, Sendable DTO structs per bridge
  Templates/                # built-in summarization / smart-create / extract-actions prompts
  DetachBlocking.swift      # load-bearing: hops sync blocking work off the cooperative pool
  SoftTimeout.swift  BatchBudget.swift  SessionState.swift
  Version.swift             # PippinVersion.version (e.g. "0.24.0")
pippin-entry/
  Pippin.swift              # @main entry point + subcommand registration
Tests/PippinTests/          # XCTest suite (1,700+ tests)
.github/workflows/          # ci.yml (DISABLED), codeql.yml, release.yml, unicode-scan.yml
```

---

## Build, Test, and Lint

> Validated for macOS with the Xcode/Swift toolchain installed. `make build`/`make test` route through `xcrun --sdk macosx`; on a CommandLineTools-only host, `swift test` fails with `no such module XCTest` — install Xcode or set `DEVELOPER_DIR`.

```bash
make build        # swift build -c release
make test         # swift test (1,700+ tests, 0 failures expected)
make lint         # swiftformat --lint on pippin/ pippin-entry/ Tests/
make ci           # full local gate: build + test + swiftformat + detach-blocking lint
make ci-vm        # same gates in an isolated ephemeral macOS VM (Tart)
make install      # release build + completions + install to ~/.local/bin/pippin
```

**Always lint all three directories together** (`pippin/ pippin-entry/ Tests/`) — linting one dir can miss cross-dir issues and won't match the gate. Auto-fix with `swiftformat pippin/ pippin-entry/ Tests/` (no `--lint`) before pushing.

---

## CI

The GitHub `ci.yml` build/test workflow is **disabled** — CI runs **locally** via `make ci` (fast, native) or `make ci-vm` (full parity in a Tart VM). There is no push-time GitHub gate for build/test/format anymore, so `make ci` is mandatory before every push. The detach-blocking lint (`python3 scripts/lint-detach-blocking.py`) is part of `make ci` and a real gate — don't skip it.

`codeql.yml`, `unicode-scan.yml`, and `release.yml` remain active on GitHub.

---

## Architecture Notes

### Swift Concurrency (Swift 6 strict mode)
- `.swiftLanguageMode(.v6)` is enforced across all targets — strict concurrency is on.
- All model structs and error enums must conform to `Sendable`.
- **`detachBlocking { ... }` is load-bearing:** any sync, thread-blocking work (subprocess waits, `DispatchSemaphore.wait`, `sendSynchronousRequest`) called from an async command MUST be hopped off the cooperative pool via `detachBlocking`, or `pippin mcp-server` wedges under fanout. `scripts/lint-detach-blocking.py` enforces this.
- Mutable GCD output buffers use `nonisolated(unsafe) var` — safe because each is written once before `group.wait()`. Mutable `static var` in `XCTestCase` requires `nonisolated(unsafe)` under Swift 6.

### mail (JXA via osascript)
- All JXA calls go through `pippin/Scripting/ScriptRunner.swift`; uses `osascript -l JavaScript` (not AppleScript).
- Message ID: `account||mailbox||messageId` (compound, round-trip safe).
- `jsEscape()` escapes in order: `\`, `\0`, `"`, `'`, `` ` ``, `\n`, `\r`, `U+2028`, `U+2029`.
- Use `mb.messages()` for unfiltered fetch — `mb.messages.whose({})()` is **invalid JXA**.
- **Timeouts are not fixed constants.** Single-account caps scale up for cross-account scans, and under MCP (`PIPPIN_MCP=1`) all caps are clamped to 55s by `MailBridge.clampHardTimeout`. The 22s soft cap (`SoftTimeout.defaultMs`) fires first in normal operation. See `TIMEOUT_ANALYSIS.md` and `pippin/MailBridge/MailBridge.swift` for the current numbers.

### Agent output (envelope v1)
- `--format agent` wraps every response in `{"v":1,"status":"ok","duration_ms":N,"data":<payload>}` (or `{...,"status":"error","error":{"code","message","remediation"?}}`). Canonical version constant: `AGENT_SCHEMA_VERSION` in `pippin/Formatting/AgentOutput.swift`. Changing a snake_case key or a CLI flag name is a breaking change for MCP clients.

### memos (GRDB/SQLite)
- `VoiceMemosDB` opens a read-only `DatabaseQueue` (`configuration.readonly = true`).
- Core Data epoch offset is handled via `Date(timeIntervalSinceReferenceDate:)`.
- Use `COUNT(*) WHERE col IS NOT NULL` instead of `fetchOne` on a nullable column to avoid `Optional<Optional<T>>` ambiguity.

### New optional fields on models
Always add an explicit `public init(...)` with `= nil` defaults — Swift's synthesized memberwise init does NOT default `Optional` properties to `nil`. Use `encodeIfPresent` for new optional fields.

---

## Test Notes

- `CLIIntegrationTests` resolves the built binary in `setUp()` — run `make build` (or `swift build`) before `swift test`.
- Use `#filePath` (not `#file`) for the `XCTFail` file parameter under Swift 6.
- Assert on `lastPathComponent` when checking export paths — UUID-based temp dir names can contain `-2`.

## SourceKit / IDE

SourceKit can't always resolve SPM dependencies or cross-file types — ignore red squiggles and run `make build` to verify correctness.
