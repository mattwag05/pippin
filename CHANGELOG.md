# Changelog

All notable changes to pippin are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow [Semantic Versioning](https://semver.org/).

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

[Unreleased]: https://github.com/mattwag05/pippin/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/mattwag05/pippin/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/mattwag05/pippin/compare/v0.1.0-beta...v0.1.0
[0.1.0-beta]: https://github.com/mattwag05/pippin/releases/tag/v0.1.0-beta
