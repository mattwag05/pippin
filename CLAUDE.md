# CLAUDE.md — pippin

macOS CLI toolkit for Apple app automation (Mail, Voice Memos, Calendar). Swift 6, SPM build system, macOS 15+.

Repo: `https://forgejo.tail6e035b.ts.net/matthewwagner/pippin` (primary)
GitHub mirror: `https://github.com/mattwag05/pippin` (public — required for Homebrew formula source)
Remotes: `forgejo` (primary, CI/releases), `github` (public mirror for Homebrew)
Homebrew tap: `mattwag05/tap` — formula at `/opt/homebrew/Library/Taps/mattwag05/homebrew-tap/Formula/pippin.rb`

## Commands

```bash
make build          # swift build -c release
make test           # swift test (421 tests, 0 failures expected)
make lint           # swiftformat --lint on all sources
make install        # build + copy to ~/.local/bin/pippin + install zsh completions
make release        # build + copy release binary to .build/release-artifacts/
make tarball        # release + tar.gz artifact
make version        # print current version from Version.swift
```

## Architecture

| Path | Purpose |
|------|---------|
| `pippin/` | `PippinLib` — all application logic (importable by tests) |
| `pippin/MailBridge/` | JXA script builders for Mail.app automation |
| `pippin/MemosBridge/` | GRDB-based Voice Memos DB access |
| `pippin/CalendarBridge/` | EventKit-based Calendar automation |
| `pippin/AIProvider/` | Ollama + Claude backends for `memos summarize` |
| `pippin/Commands/` | ArgumentParser command implementations |
| `pippin/Commands/TemplatesCommand.swift` | `memos templates` subcommand |
| `pippin/Commands/SummarizeCommand.swift` | `memos summarize` subcommand |
| `pippin/Templates/` | Built-in summarization prompt templates |
| `pippin/Models/CalendarModels.swift` | CalendarInfo, CalendarEvent, Attendee, CalendarActionResult |
| `pippin/Models/MailModels.swift` | MailMessage, Attachment (savedPath), MailActionResult, Mailbox, MailAccount |
| `pippin-entry/` | Thin `@main` executable target |
| `Tests/PippinTests/` | Unit tests |

## Key Patterns

**Compound message ID:** `account||mailbox||numericId`
- Parsed in `MailBridge` and `CompoundId` helpers
- `mailbox` reflects the *resolved* mailbox name (e.g. `[Gmail]/Trash`), not the user-supplied alias

**JXA script builders (`MailBridge.swift`):**
- Scripts are built as Swift string templates and run via `osascript`
- Shared helpers: `jsFindMailboxByName()`, `jsResolveMailbox()`, `jsMailReadyPoll()`
- `jsResolveMailbox()` resolves user aliases (`Trash`, `Junk`, `Sent`, `Drafts`) to the provider-correct mailbox via JXA special accessors (`acct.trash()`, etc.) — required because folder names vary by provider (Gmail, iCloud, Exchange)
- Tests assert on generated script *strings* — no osascript execution needed

**IMAP body fetch:**
- Always call `msg.content()` before `msg.htmlContent()` — `content()` triggers the IMAP body download
- Retry `htmlContent()` once after `delay(0.5)` if still null

**ArgumentParser `ValidationError` from `run()`:** Shows full usage-help footer — use a custom `LocalizedError` struct for runtime errors instead.

**`TextFormatter.actionResult` dict overload:** Use `TextFormatter.actionResult(success:action:details:[String:String])` — never hand-roll `.map { "\($0.key)=\($0.value)" }.sorted().joined()` inline.

**Shared mail validation helpers (MailCommand.swift):** `validateEmailAddresses(_:field:)` and `validateAttachmentPaths(_:)` are file-private free functions used by Send/Reply/Forward — add new outgoing commands there, not inline.

**Reply/Forward quoting:** Happens in Swift (`buildReplyQuote`, `buildForwardPrefix`) before the JXA send script runs — not inside osascript. Subject de-duplication (`Re:`/`Fwd:`) also in Swift via `buildReplySubject`/`buildForwardSubject`.

## Version + Release

1. Bump `pippin/Version.swift`
2. Update `CHANGELOG.md` (including comparison links at bottom — they go stale)
3. `swift test` — must pass (run `make test`)
4. `git commit -m "chore: bump to vX.Y.Z"` then `git tag vX.Y.Z`
5. `git push forgejo main --tags`
6. `git push github main --tags` (GitHub mirror must have the tag for Homebrew)
7. Update tap formula (`tag`, `revision`, `assert_match` version):
   `/opt/homebrew/Library/Taps/mattwag05/homebrew-tap/Formula/pippin.rb`
8. `cd /opt/homebrew/Library/Taps/mattwag05/homebrew-tap && git add -A && git commit -m "pippin vX.Y.Z" && git push`
9. `brew upgrade pippin && pippin --version` to verify

## CI

- **Forgejo Actions:** `.forgejo/workflows/ci.yaml` — runs on `macbook-air` runner (`com.matthewwagner.act-runner` LaunchAgent, labels: `macos macos-15 arm64`)
- **Release workflow:** `.forgejo/workflows/release.yaml` — triggers on `v*` tag push; builds tarball, extracts changelog, creates Forgejo release with arm64 asset
- `.github/workflows/` kept in place but not used on GitHub

## Forgejo API Gotchas

- **Merge API returns HTTP 204** (empty body) on success — don't pipe to JSON parser
- **Existing PRs:** Pushing to a branch with an open PR reuses it. Update title/body via `PATCH .../pulls/{n}` instead of creating a new PR
- **Action runs API:** Use `title` field (not `name`) for workflow run descriptions
