# CLAUDE.md — pippin

macOS CLI toolkit for Apple app automation (Mail, Voice Memos, Calendar, Reminders, Notes, Contacts, Audio, Browser). Swift 6, SPM build system, macOS 15+.

Repo: `https://forgejo.tail6e035b.ts.net/matthewwagner/pippin` (primary)
GitHub mirror: `https://github.com/mattwag05/pippin` (public — required for Homebrew formula source)
Remotes: `forgejo` (primary, CI/releases), `github` (public mirror for Homebrew)
Homebrew tap: `mattwag05/tap` — formula at `/opt/homebrew/Library/Taps/mattwag05/homebrew-tap/Formula/pippin.rb`

## Commands

```bash
make build          # swift build -c release
make test           # swift test (819 tests, 0 failures expected)
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
| `pippin/RemindersBridge/` | EventKit-based Reminders automation (.reminder entity) |
| `pippin/NotesBridge/` | JXA-based Notes automation (enum pattern, synchronous) |
| `pippin/Models/ReminderModels.swift` | ReminderList, ReminderItem (listTitle), ReminderActionResult |
| `pippin/Models/NoteModels.swift` | NoteInfo (body HTML + plainText), NoteFolder, NoteActionResult |
| `pippin/Formatting/AgentOutput.swift` | printAgentJSON<T>() — compact JSON for agent consumers |
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

**New bridge pattern (Audio/Contacts/Browser/Notes):** JXA/subprocess bridges follow MailBridge's pattern — `nonisolated(unsafe)` vars + DispatchGroup concurrent pipe drain + DispatchWorkItem SIGTERM→SIGKILL timeout. Copy `runScript` from any existing bridge. JXA bridges are `enum` with `static` methods (not class); commands are `ParsableCommand` (not Async).

**EventKit Reminders bridge:** `EKEventStore.fetchReminders(matching:)` uses a completion handler and `EKReminder` is not `Sendable` — cannot use `withCheckedThrowingContinuation` in Swift 6 strict mode. Use `DispatchSemaphore` + `nonisolated(unsafe) var` instead. See `RemindersBridge.fetchRemindersSync()`.

**JXA typed error trap:** JXA script errors always arrive as `scriptFailed(String)` — never as a typed Swift case like `noteNotFound`. Don't add typed not-found cases to JXA bridge error enums; they'll be dead code.

**Notes IDs prefix trap:** Notes IDs start with `x-coredata://` — `String(id.prefix(8))` always yields `"x-coreda"`. Use `id.components(separatedBy: "/").last` for display.

**Memos progress output in agent mode:** Progress `print()` calls guarded by `!outputOptions.isJSON` also need `&& !outputOptions.isAgent` — otherwise stdout is corrupted in agent mode.

**Agent output format:** `OutputOptions` now has `.agent` case and `isAgent` property. `printAgentJSON<T>()` uses `JSONEncoder()` with no formatting options (compact). Notes `show` in agent mode uses `NoteAgentView` (excludes HTML body field).

**Worktree cleanup order:** `git worktree remove <path>` first, then `git branch -d <branch>`. Reverse order fails — branch can't be deleted while worktree is using it.

**GRDB `SQL` type inference trap:** In files that import GRDB, `SQL` is `ExpressibleByStringInterpolation` — string interpolation inside closures near array builders causes wrong type inference. Fix: use explicit `let x: String = ...` type annotations.

**ArgumentParser async `main()` override:** Must cast before dispatching: `if var asyncCommand = command as? AsyncParsableCommand { try await asyncCommand.run() } else { try command.run() }`. Calling `try await command.run()` directly on a `ParsableCommand` existential invokes the sync `run()`, which prints help for command-groups instead of running subcommands.

**Agent error interception — `ExitCode` passthrough:** Both `CleanExit` (--help/--version) AND `ExitCode` (e.g. `throw ExitCode(1)` from `DoctorCommand`) must pass through to `Pippin.exit(withError:)`, not be treated as agent errors. Check `error is CleanExit || error is ExitCode` before the agent branch.

**`--format` collision with `OutputOptions`:** Commands using `@OptionGroup var output: OutputOptions` must NOT also declare `@Option var format` — ArgumentParser throws "Multiple arguments named --format" at parse time. Rename the command-specific option (e.g. `--transcription-format`).

**CLIIntegrationTests version assertion:** `Tests/PippinTests/CLIIntegrationTests.swift` has `result.stdout.contains("X.Y")` hardcoded — update with each version bump or the test fails. Currently `"0.13"`.

**Dual-remote push divergence:** `forgejo` and `github` can each be ahead independently. If push rejected: `git stash && git pull --rebase <remote> main && git stash pop && git push <remote> main` — repeat for each remote separately.

## Version + Release

1. Bump `pippin/Version.swift`
2. Update `CHANGELOG.md` (including comparison links at bottom — they go stale)
3. `swift test` — must pass (run `make test`)
4. `git commit -m "chore: bump to vX.Y.Z"` then `git tag vX.Y.Z`
5. `git push forgejo main --tags`
6. `git push github main --tags` (GitHub mirror must have the tag for Homebrew)
7. Update tap formula (`tag`, `revision`, `assert_match` version):
   `/opt/homebrew/Library/Taps/mattwag05/homebrew-tap/Formula/pippin.rb`
   `revision` = merge commit SHA: `git rev-parse vX.Y.Z` (not tarball SHA256 — formula uses git source)
8. `cd /opt/homebrew/Library/Taps/mattwag05/homebrew-tap && git add -A && git commit -m "pippin vX.Y.Z" && git push`
9. `brew upgrade pippin && pippin --version` to verify

## CI

- **Forgejo Actions:** `.forgejo/workflows/ci.yaml` — runs on `macbook-air` runner (`com.matthewwagner.act-runner` LaunchAgent, labels: `macos macos-15 arm64`)
- **Release workflow:** `.forgejo/workflows/release.yaml` — triggers on `v*` tag push; builds tarball, extracts changelog, creates Forgejo release with arm64 asset
- `.github/workflows/` active on GitHub — actions pinned to full commit SHAs (not `@v4` tags) for supply-chain security; update SHAs when upgrading, don't revert to tag syntax
- **act_runner + Docker:** Runner checks Docker socket at startup. If Docker is not running, act_runner exits and all CI runs cancel silently. Start Docker first, then `brew services restart act_runner`.
- **Manual release (when CI is down):** `make tarball` → check if release exists (`GET /releases/tags/vX.Y.Z`) → POST create only if missing → `POST /releases/{id}/assets` to upload tarball. The release workflow may have partially run and already created the release — always check before creating.

## Forgejo API Gotchas

- **Merge API returns HTTP 204** (empty body) on success — don't pipe to JSON parser
- **Existing PRs:** Pushing to a branch with an open PR reuses it. Update title/body via `PATCH .../pulls/{n}` instead of creating a new PR
- **Action runs API:** Use `title` field (not `name`) for workflow run descriptions
