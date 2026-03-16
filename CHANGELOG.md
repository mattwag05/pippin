# Changelog

All notable changes to pippin are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow [Semantic Versioning](https://semver.org/).

---

## [0.13.0] - 2026-03-15

### Added

- Structured agent error output: when `--format agent` is active, unhandled errors emit `{"error":{"code":"snake_case_code","message":"..."}}`  to stdout (via `AgentError` + `printAgentError()` in `AgentOutput.swift`)
- `BrowserCommandTests` — parse/validate tests for all 9 browser subcommands + `BrowserBridgeError` descriptions
- `AudioCommandTests` — parse/validate tests for all 4 audio subcommands + `AudioBridgeError` descriptions
- `ContactsCommandTests` — parse/validate tests for all 4 contacts subcommands

### Changed

- `MailBridge.swift` split into four focused files: `MailBridgeScripts.swift`, `MailBridgeHelpers.swift`, `MailBridgeRunner.swift` (core API methods remain in `MailBridge.swift`); removes `swiftlint:disable file_length`
- `MailBridgeError` moved to `MailModels.swift` (public, `Sendable`)
- `AudioBridgeError` moved from `AudioBridge.swift` to `AudioModels.swift` (public, `Sendable`)
- `BrowserBridgeError.actionFailed(String)` replaced with typed cases: `scriptFailed(String)`, `decodingFailed(String)`, `timeout` — matching Mail/Notes pattern
- `AudioCommand.Transcribe` renames `--format` to `--transcription-format` (was colliding with `OutputOptions --format`)
- 703 → 819 tests, 0 failures

---

## [0.12.0] - 2026-03-13

### Added

- `pippin doctor --format agent` — compact JSON output for AI agent consumption
- `pippin doctor` now checks Python 3 availability as a separate named check
- `pippin doctor` Notes.app pre-check via `pgrep` — faster fail when Notes is not running
- `classifyMailError()` and `classifyPython3Output()` extracted as testable public helpers
- `DoctorTests` — unit tests for mail error classification, python3 detection, and permission-denied remediation format

### Fixed

- Doctor command remediation strings unified: agent-runnable commands use `$` prefix, human-only instructions have no `$` prefix
- Notes.app timeout remediation simplified to `$ open -a Notes && sleep 2`
- Node.js remediation updated to `$ brew install node`
- Playwright remediation updated to `$ npx playwright install webkit`
- Transcription unified on `mlx-audio` (AudioBridge) — removes separate `parakeet-mlx` binary dependency
- `pippin memos transcribe` and `pippin memos export --transcribe` now read/write transcript cache (no more redundant transcription)
- `pippin doctor` no longer checks `parakeet-mlx` or Speech Recognition; `mlx-audio` check promoted from optional to required
- `MLXAudioTranscriber` replaces `ParakeetTranscriber`/`SpeechFrameworkTranscriber`/`TranscriberFactory` (dead code removed)

### Changed

- `pippin memos transcribe`, `pippin memos export`, and `pippin memos summarize` support `--jobs N` for parallel batch processing (default: 2)
- `pippin memos transcribe` gains `--force` flag to bypass transcript cache
- `pippin memos export` gains `--force-transcribe` flag to bypass transcript cache

---

## [0.11.0] - 2026-03-10

### Added

- `--format agent` output mode across all commands: compact (non-pretty-printed) JSON for AI agent consumption
- `OutputFormat.agent` case added to `OutputFormat` enum (alongside `text` and `json`)
- `OutputOptions.isAgent` computed property for command dispatch
- `printAgentJSON<T: Encodable>()` helper in `AgentOutput.swift` — uses `JSONEncoder` with no formatting options (compact by default)
- Agent mode for action results (create/edit/delete/complete/send/move/mark) — same as `json` (already compact)
- Agent mode for `notes show` uses `NoteAgentView` — excludes large HTML body, includes `plainText`, reducing token usage
- Claude Code plugin at `~/.claude/plugins/pippin/` — skill that teaches Claude to use pippin for Apple app automation

---

## [0.10.0] - 2026-03-10

### Added

- `pippin notes` subcommand: `list`, `show`, `search`, `folders`, `create`, `edit`, `delete`
- JXA (JavaScript for Automation) subprocess bridge for Notes.app automation
- Notes sorted by modification date (newest first)
- `--folder` filter for `list` and `search` subcommands
- `--append` flag on `edit` to append body content instead of replacing
- `--force` required for `delete` to prevent accidental note removal
- `--fields` JSON field filtering for `list` and `search` (JSON output only)
- `pippin doctor` now reports Notes.app automation TCC permission status

---

## [0.9.0] - 2026-03-10

### Added

- `pippin reminders` subcommand: `lists`, `list`, `show`, `create`, `edit`, `complete`, `delete`, `search`
- EventKit-based Reminders bridge using EKEventStore with `.reminder` entity type
- Priority filtering and display (high/medium/low/none mapping to EKReminder priority values 1/5/9/0)
- Due date filtering via `--due-before` and `--due-after` flags
- `pippin doctor` now reports Reminders TCC permission status

---

## [0.8.0] - 2026-03-10

### Added

- `pippin browser` subcommand: `open`, `snapshot`, `screenshot`, `click`, `fill`, `scroll`, `tabs`, `close`, `fetch`
- Playwright WebKit subprocess bridge with persistent session support
- Accessibility tree parsing with @ref IDs for AI agent interaction
- `pippin doctor` now reports Node.js and Playwright availability (optional dependencies)

---

## [0.7.0] - 2026-03-10

### Added

- `pippin calendar events --fields`: comma-separated JSON field filtering
- `pippin calendar events --range`: date shorthands (`today`, `today+N`, `week`, `month`)
- `pippin calendar events --type`: filter by calendar type (calDAV, exchange, local, etc.)
- `pippin calendar list --type`: filter calendars by type
- New subcommands: `today`, `remaining`, `upcoming` (convenience aliases)

---

## [0.6.0] - 2026-03-10

### Added

- `pippin contacts` subcommand: `list`, `search`, `show`, `groups`
- CNContactStore-based contacts access (read-only)
- `--fields` flag for token-efficient field filtering on list/search
- `pippin doctor` now reports Contacts TCC permission status

---

## [0.5.0] - 2026-03-10

### Added

- `pippin audio` subcommand: `speak`, `transcribe`, `voices`, `models`
- Python mlx-audio subprocess bridge (TTS via Kokoro, STT via Parakeet/Whisper)
- `pippin doctor` now reports mlx-audio availability (optional dependency)

---

## [0.4.0] - 2026-03-09

### Fixed

- `mail search` now scans **newest messages first** (was oldest-first, causing recent emails to be missed in large mailboxes)
- Per-mailbox scan limit raised from 50 to 200 messages
- Error messages include actionable suggestions (e.g., timeout now says "try --account or --after")
- `to:` field is now populated in `mail search` results (was always empty `[]`)

### Added

- `--after YYYY-MM-DD` — only include messages on or after this date
- `--before YYYY-MM-DD` — only include messages on or before this date
- `--to <email>` — filter search results by recipient address
- `--verbose` — print search diagnostics to stderr (accounts/mailboxes scanned, messages examined, body search status)

---

## [0.3.1] - 2026-03-09

### Added

- `pippin mail reply <id> --body "..."` — reply to a message; optional `--to` to override recipient
- `pippin mail forward <id> --to <addr>` — forward a message; optional `--body` for additional text
- `pippin mail attachments <id>` — list attachments; `--save-dir <path>` to save to disk
- `--bcc` flag on `mail send`, `mail reply`, `mail forward`
- `--to`, `--cc`, `--bcc`, `--attach` are now repeatable (accept multiple values)

### Changed

- Email address and attachment path validation extracted to shared helpers (DRY)
- Reply/forward quoting built in Swift (`buildReplyQuote`, `buildForwardPrefix`) before JXA execution
- `buildSaveAttachmentsScript` uses `resolveMailbox` helper for alias support

---

## [0.3.0] - 2026-03-06

### Added

- `pippin calendar` — new command group for Apple Calendar automation using EventKit
- `pippin calendar list` — list all calendars (NAME, TYPE, ACCOUNT, COLOR columns)
- `pippin calendar events` — list events; `--from`, `--to`, `--calendar`, `--limit 50`; defaults to today
- `pippin calendar show <id>` — full event card with attendees, recurrence, notes, URL
- `pippin calendar create --title --start` — create event; `--end` (default: +1h), `--location`, `--notes`, `--all-day`, `--url`, `--calendar`
- `pippin calendar edit <id>` — update any field on an existing event
- `pippin calendar delete <id> --force` — delete an event (requires `--force`)
- `pippin calendar smart-create "<description>"` — AI parses natural language → creates event; `--dry-run` to preview parsed JSON
- `pippin calendar agenda` — AI-generated daily/weekly briefing; `--days 1` (max 7)
- `pippin doctor` now checks Calendar TCC permission and reports ok/skip/fail
- 2 built-in AI templates: `smart-create-calendar`, `calendar-briefing`
- Event IDs use `calendarItemIdentifier` (stable UUID); prefix matching (8+ chars) supported
- All `pippin calendar` subcommands accept `--format json`

---

## [0.2.1] - 2026-03-06

### Fixed

- `mail move --to Trash` (and `Deleted`, `Junk`, `Spam`, `Sent`, `Drafts`, `Bin`) now resolves the correct provider mailbox via JXA special accessors (`acct.trash()`, `acct.junk()`, `acct.sent()`, `acct.drafts()`), fixing failures on Gmail, iCloud, and Exchange accounts where the folder name varies by provider (fixes #4)
- `mail list --mailbox <alias>` and `mail search --mailbox <alias>` use the same alias resolver, so `--mailbox Trash` works regardless of provider naming
- `mail show` now fetches plain-text content first to trigger the IMAP body download before attempting `htmlContent()`, and retries once after 500 ms if `htmlBody` is still null — fixes `htmlBody: null` on undownloaded IMAP messages (fixes #3)

---

## [0.2.0] - 2026-03-05

### Added

- `memos summarize <id>` — AI-powered summarization of voice memo transcripts; saves Markdown summary to output directory
- `memos templates` — list and manage summarization prompt templates (5 built-in + user-defined)
- `memos delete <id> --force` — permanently delete a voice memo from the Voice Memos database
- AI provider layer: Ollama (local) and Claude (Anthropic API) backends; configurable via `pippin init` or `--provider`
- Transcript cache: transcripts saved alongside audio exports, reused on subsequent summarize calls
- `--format` flag for `memos export` output (text/json, consistent with other subcommands)
- 34 new tests (228 total, 0 failures)

### Fixed

- `createdAt` timestamp now used correctly for summary filename (was using file modification date)
- `builtIn` field in template JSON now encodes as boolean (was encoding as integer)

### Changed

- Reduced duplication in `MailBridge`, `DoctorCommand`, and memos commands

---

## [0.1.0] - 2026-03-05

### Added

- `pippin completions <shell>` — generate shell completion scripts (`zsh`, `bash`, `fish`); `make completions` installs to `~/.zfunc/_pippin`
- `pippin mail mailboxes` — list all mailboxes for an account; `--account` filter
- `pippin mail list` — `--page` flag for paginated browsing, `--has-attachment` filter
- `pippin mail show` — enriched output with `htmlBody`, `headers`, and `attachments[]` (name, mimeType, size)
- `pippin memos info` — prefix ID matching (first 8 chars of UUID)
- GitHub Actions CI (`.github/workflows/ci.yaml`) — build, test, lint on GitHub push and PR
- Forgejo Actions CI enforces `swiftformat --lint` across all three source dirs

### Changed

- `pippin mail search` — timeout increased from 10 s to 30 s; fixes timeouts on large IMAP mailboxes
- All source migrated to Swift 6 strict concurrency (`swiftLanguageMode(.v6)`); all `Sendable` conformances and `nonisolated(unsafe)` patterns applied
- macOS platform minimum set to macOS 15+

### Fixed

- `pippin memos` prefix ID matching now resolves correctly against GRDB UUID column

---

## [0.1.0-beta] - 2026-03-02

Initial beta release. Single arm64 binary, human-readable text output, guided setup.

### Added

**Core**
- `pippin --version` — print version string
- `pippin doctor` — check macOS version, Mail TCC, Voice Memos DB access, parakeet-mlx, Speech Recognition; exits 1 on critical failure; `--format json` for scripting
- `pippin init` — guided first-run setup with step-by-step remediation for each failed check
- `--format text|json` on every subcommand (default: text)

**Mail**
- `pippin mail accounts` — list configured Mail accounts
- `pippin mail list` — list inbox messages (limit 20, `--unread`, `--mailbox`, `--account`)
- `pippin mail search <query>` — search by subject, sender, or body (limit 10)
- `pippin mail show <id>` — show full message; `--subject` shortcut to search-then-show
- `pippin mail mark <id> --read|--unread` — mark message read status (`--dry-run`)
- `pippin mail move <id> --to <mailbox>` — move message to another mailbox (`--dry-run`)
- `pippin mail send --to --subject --body` — send email; optional `--cc`, `--from`, `--attach`, `--dry-run`
- `pippin mail read` — hidden alias for `show` (backward compat)

**Memos**
- `pippin memos list` — list recordings as text table; `--since YYYY-MM-DD`, `--limit`
- `pippin memos info <id>` — full metadata card for a recording
- `pippin memos export <id|--all> --output <dir>` — copy audio file(s) to directory; `--transcribe` for transcript sidecar

**Infrastructure**
- GRDB.swift 7.0 dependency — read-only SQLite access to Voice Memos database (replaces Python subprocess)
- `TextFormatter` — 80-column table/card/truncate/duration/date formatting for all text output
- Apache 2.0 LICENSE
- `Makefile` with `build`, `test`, `lint`, `install`, `version`, `release`, `clean` targets
- Forgejo Actions CI (`.forgejo/workflows/ci.yaml`) — build, test, lint on every push and PR

### Changed

- `pippin mail read` renamed to `pippin mail show` (`read` kept as hidden alias)
- `pippin mail list` default limit: 50 → 20
- `pippin memos` rewritten in Swift with GRDB (was Python subprocess via `pippin-memos`)
- Default output format changed from JSON to human-readable text (`--format json` for scripting)

### Removed

- Python `pippin-memos` package (archived to `archive/pippin-memos/`)
- `pippin memos delete` — dropped from v0.1 scope (sandboxing concerns)
- Xcode project (`pippin.xcodeproj`) — SPM is the build system
- `make install-memos` and `make install-all` targets (no Python)

---

[Unreleased]: https://github.com/mattwag05/pippin/compare/v0.12.0...HEAD
[0.12.0]: https://github.com/mattwag05/pippin/compare/v0.11.0...v0.12.0
[0.13.0]: https://github.com/mattwag05/pippin/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/mattwag05/pippin/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/mattwag05/pippin/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/mattwag05/pippin/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/mattwag05/pippin/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/mattwag05/pippin/compare/v0.4.0...v0.8.0
[0.4.0]: https://github.com/mattwag05/pippin/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/mattwag05/pippin/compare/v0.2.1...v0.3.1
[0.2.1]: https://github.com/mattwag05/pippin/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/mattwag05/pippin/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/mattwag05/pippin/compare/v0.1.0-beta...v0.1.0
[0.1.0-beta]: https://github.com/mattwag05/pippin/releases/tag/v0.1.0-beta
