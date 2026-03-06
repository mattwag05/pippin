# pippin

macOS CLI toolkit for Apple app automation. Structured CLI access to sandboxed Apple apps — headless-safe for cron, launchd, and N8N pipelines.

```
pippin mail list
pippin memos list
```

---

## Install

### Homebrew (recommended)

```bash
brew install mattwag05/tap/pippin
```

### Pre-built binary (arm64, macOS 15+)

Download from the [Releases](https://github.com/mattwag05/pippin/releases) page:

```bash
curl -L https://github.com/mattwag05/pippin/releases/download/v0.2.0/pippin-0.2.0-arm64-macos.tar.gz -o pippin.tar.gz
tar xzf pippin.tar.gz && mv pippin-0.2.0-arm64-macos ~/.local/bin/pippin
chmod +x ~/.local/bin/pippin
```

### Build from source

Requires Xcode 16+ / Swift 6.2+:

```bash
git clone https://github.com/mattwag05/pippin.git
cd pippin
make install
```

---

## First-run setup

pippin accesses sandboxed Apple apps — macOS requires explicit permission grants.

### 1. Run the setup guide

```bash
pippin init
```

This walks through each permission and tells you exactly what to grant.

### 2. Manual permission grants

Open **System Settings → Privacy & Security**:

| Permission | For |
|---|---|
| **Full Disk Access** → Terminal.app | Voice Memos (`pippin memos`) |
| **Automation → Mail** → Terminal.app | Mail (`pippin mail`) |
| **Automation → Mail** → pippin binary | Mail under cron/launchd |

After granting, run each subcommand once interactively to trigger the TCC prompt:

```bash
pippin mail list
pippin memos list
```

> **Note:** Permission is per binary path. After each new build or install, re-run the above commands interactively before scheduling with launchd/cron.

### 3. Optional: transcription

For `pippin memos export --transcribe`:

```bash
pip install parakeet-mlx   # or: use built-in Speech Recognition (slower)
```

---

## Usage

### `pippin mail`

```bash
# List accounts
pippin mail accounts

# List inbox (text table, limit 20)
pippin mail list
pippin mail list --unread --limit 5
pippin mail list --mailbox Archive --account "Work"

# Search (subject, sender, body)
pippin mail search "quarterly report"
pippin mail search "invoice" --account "Work" --limit 20

# Show a message
pippin mail show "acct||INBOX||12345"
pippin mail show --subject "quarterly report"

# Mark read/unread
pippin mail mark "acct||INBOX||12345" --read
pippin mail mark "acct||INBOX||12345" --unread --dry-run

# Move to another mailbox
pippin mail move "acct||INBOX||12345" --to Archive
pippin mail move "acct||INBOX||12345" --to Archive --dry-run

# Send
pippin mail send --to user@example.com --subject "Hello" --body "Hi there"
pippin mail send --to user@example.com --subject "Report" --body "See attached" --attach /tmp/report.pdf --dry-run
```

### `pippin memos`

```bash
# List recordings
pippin memos list
pippin memos list --since 2026-01-01 --limit 10

# Show details for a recording
pippin memos info <uuid>

# Export audio file(s)
pippin memos export <uuid> --output ~/Desktop/memos
pippin memos export --all --output ~/Desktop/memos
pippin memos export <uuid> --output ~/Desktop --transcribe
```

### Output formats

Every subcommand supports `--format text` (default) and `--format json`:

```bash
pippin mail list --format json | jq '.[0].subject'
pippin memos list --format json
```

JSON output is stable and suitable for scripting.

### Diagnostics

```bash
pippin doctor          # Check all permissions and dependencies
pippin doctor --format json   # Machine-readable check results
pippin init            # Guided setup with remediation steps
pippin --version       # Print version
```

---

## Sample workflow

```bash
# Check everything is working
pippin doctor

# Find unread emails from a specific sender
pippin mail list --unread --format json | jq '.[] | select(.from | contains("boss@company.com"))'

# Export and transcribe today's voice memos
pippin memos list --since $(date +%Y-%m-%d) --format json \
  | jq -r '.[].id' \
  | xargs -I{} pippin memos export {} --output ~/memos --transcribe
```

---

## Requirements

- **macOS 15+ (Sequoia)** or later (tested on macOS 26 Tahoe)
- **Swift 6.2+** — source builds only; pre-built binaries are arm64

---

## Development

```bash
swift build          # Debug build
swift test           # Run tests
make build           # Release build
make test            # Run tests
make lint            # swiftformat lint
make install         # Build release + install to ~/.local/bin/pippin
make release         # Build release binary in .build/release-artifacts/
```

---

## Architecture

**`pippin mail`** — Swift CLI using ArgumentParser. All Mail interaction goes through `MailBridge`, which shells out to `osascript -l JavaScript` (JXA). Headless-safe with per-operation timeouts.

**`pippin memos`** — Swift CLI using GRDB.swift for read-only SQLite access to the Voice Memos database. No Python required.

Key files:
- `pippin/Commands/` — ArgumentParser subcommand structs
- `pippin/MailBridge/MailBridge.swift` — JXA script runner
- `pippin/MemosBridge/VoiceMemosDB.swift` — GRDB database reader
- `pippin/MemosBridge/Transcriber.swift` — transcription strategy (parakeet-mlx / SFSpeechRecognizer)
- `pippin/Formatting/` — text table/card formatters and JSON output
- `pippin-entry/Pippin.swift` — `@main` entry point

---

## License

Apache 2.0 — see [LICENSE](LICENSE).
