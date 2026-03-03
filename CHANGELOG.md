# Changelog

All notable changes to pippin are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

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

[Unreleased]: https://github.com/mattwag05/pippin/compare/v0.1.0-beta...HEAD
[0.1.0-beta]: https://github.com/mattwag05/pippin/releases/tag/v0.1.0-beta
