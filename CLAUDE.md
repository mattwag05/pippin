# CLAUDE.md — pippin

macOS CLI toolkit for Apple app automation (Mail, Voice Memos, Calendar, Reminders, Notes, Contacts, Audio, Browser). Swift 6, SPM build system, macOS 15+.

Repo: `https://forgejo.tail6e035b.ts.net/matthewwagner/pippin` (primary)
GitHub mirror: `https://github.com/mattwag05/pippin` (public — required for Homebrew formula source)
Remotes: `forgejo` (primary, CI/releases), `github` (public mirror for Homebrew)
Homebrew tap: `mattwag05/tap` — formula at `/opt/homebrew/Library/Taps/mattwag05/homebrew-tap/Formula/pippin.rb`

## Commands

```bash
make build          # swift build -c release
make test           # swift test (~1049 tests, 0 failures expected)
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
| `pippin/Commands/ShellCommand.swift` | Interactive REPL — `pippin shell` or bare `pippin` |
| `pippin/Commands/StatusCommand.swift` | System dashboard — `pippin status` |
| `pippin/SessionState.swift` | Session state persistence for REPL (`~/.config/pippin/session.json`) |
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
| `.github/copilot-setup-steps.yml` | Copilot agent environment (Xcode, SwiftFormat, deps) |
| `.github/workflows/copilot-ci-fix.yml` | Auto-creates Copilot issue on CI failure |

## AI Provider Configuration

Config file: `~/.config/pippin/config.json`

```json
{
  "ai": {
    "provider": "ollama",
    "ollama": {
      "model": "gemma4:latest",
      "url": "http://localhost:11434"
    },
    "claude": {
      "model": "claude-sonnet-4-6"
    }
  }
}
```

**Supported providers:** `ollama` (default), `claude`

The `provider` field selects the active backend. Both providers can be configured simultaneously — the inactive one is ignored until `provider` is switched or `--provider` overrides it per-command.

**Per-command override:** `pippin memos summarize <id> --provider ollama --model qwen3.5:latest`

### Model comparison (tested 2026-04-03 on MacBook Air M4, 24 GB)

| Model | Size | Response time | Tokens | Notes |
|-------|------|--------------|--------|-------|
| `gemma4:latest` (Q4_K_M, 8B) | 9.6 GB | ~22s | 238 | Fast, concise responses. Recommended default for pippin's summarization tasks. |
| `qwen3.5:latest` (Q4_K_M, 9.7B) | 6.6 GB | ~45s | 589 | Heavy chain-of-thought reasoning overhead — generates extensive internal deliberation even for simple prompts. Better suited for complex analytical tasks, not structured summarization. |
| `claude-sonnet-4-6` (API) | — | ~2-3s | varies | Fastest option but requires API key and internet. Best quality. |

**Recommendation:** Use **Gemma 4** as the default Ollama model for pippin. It's ~2x faster than Qwen 3.5 for equivalent output quality on summarization tasks. Qwen 3.5's thinking mode adds latency without proportional quality gains for structured extraction work. Fall back to Claude when speed or quality is critical.

### Config resolution order (AIProviderFactory.swift)

1. `--provider` / `--model` CLI flags (highest priority)
2. `~/.config/pippin/config.json` `ai.provider` / `ai.ollama.model` / `ai.claude.model`
3. Defaults: provider=`ollama`, model=provider-specific default, Ollama URL=`http://localhost:11434`

### Claude API key resolution

1. `--api-key` CLI flag
2. `ANTHROPIC_API_KEY` environment variable
3. Vaultwarden secret lookup via `get-secret "Anthropic API"`

## Key Patterns

**REPL shell architecture (`ShellCommand.swift`):**
- `ShellCommand` is `AsyncParsableCommand` in PippinLib; bare `pippin` defaults to REPL in `Pippin.main()`
- Parser injection: `ShellCommand.parser` is a `nonisolated(unsafe)` static var set by `Pippin.main()` to `Pippin.parseAsRoot(_:)` — avoids circular dependency between PippinLib and executable target
- `--format` session flag: when set, injected into every command's args before parsing
- Non-interactive (pipe) mode: detected via `isatty(fileno(stdin))`; no prompt, no banner
- `ExitCode` errors are caught silently (like `CleanExit`) — commands that exit non-zero don't kill the REPL
- `shellSplit(_:)` handles single/double quote parsing for command lines
- Session state: `SessionManager` persists active account, last-used IDs, and command history to `~/.config/pippin/session.json`. REPL auto-injects `--account` from session context for mail commands. Built-in commands: `use <account>`, `context`, `history`

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

**Worktree blocks checkout:** If `git checkout <branch>` fails "already used by worktree at ...", run `git worktree remove --force .claude/worktrees/<name>` first.

**SwiftLint in worktrees:** `.swiftlint.yml` only exists in the main worktree. In a linked worktree, run `swiftlint lint --config /Users/matthewwagner/Projects/pippin/.swiftlint.yml ...` (absolute path required).

**GRDB `SQL` type inference trap:** In files that import GRDB, `SQL` is `ExpressibleByStringInterpolation` — string interpolation inside closures near array builders causes wrong type inference. Fix: use explicit `let x: String = ...` type annotations.

**ArgumentParser async `main()` override:** Must cast before dispatching: `if var asyncCommand = command as? AsyncParsableCommand { try await asyncCommand.run() } else { try command.run() }`. Calling `try await command.run()` directly on a `ParsableCommand` existential invokes the sync `run()`, which prints help for command-groups instead of running subcommands.

**Agent error interception — `ExitCode` passthrough:** Both `CleanExit` (--help/--version) AND `ExitCode` (e.g. `throw ExitCode(1)` from `DoctorCommand`) must pass through to `Pippin.exit(withError:)`, not be treated as agent errors. Check `error is CleanExit || error is ExitCode` before the agent branch.

**`--format` collision with `OutputOptions`:** Commands using `@OptionGroup var output: OutputOptions` must NOT also declare `@Option var format` — ArgumentParser throws "Multiple arguments named --format" at parse time. Rename the command-specific option (e.g. `--transcription-format`).

**CLIIntegrationTests version assertion:** `Tests/PippinTests/CLIIntegrationTests.swift` uses `PippinVersion.version` dynamically — no manual update needed on version bumps.

**Dual-remote push divergence:** `origin` (Forgejo) and `github` can each be ahead independently. If push rejected: `git stash && git pull --rebase <remote> main && git stash pop && git push <remote> main` — repeat for each remote separately. Note: Forgejo remote is named `origin` in this repo, not `forgejo`.

## Version + Release

1. Bump `pippin/Version.swift`
2. Update `CHANGELOG.md` (including comparison links at bottom — they go stale)
   - Update `[Unreleased]` base to the new version tag
   - Avoid duplicate version entries in the comparison link table
3. Update `README.md` if any new commands or subcommands were added
4. `swift test` — must pass (run `make test`)
4. `git commit -m "chore: bump to vX.Y.Z"` then `git tag -a vX.Y.Z -m "vX.Y.Z"` (annotated tag required — bare `git tag` fails with "no tag message")
5. `git push origin main --tags`
6. `git push github main --tags` (GitHub mirror must have the tag for Homebrew)
7. Update tap formula (`tag`, `revision`, `assert_match` version):
   `/opt/homebrew/Library/Taps/mattwag05/homebrew-tap/Formula/pippin.rb`
   `revision` = commit SHA — use `git rev-parse vX.Y.Z^{}` (dereference annotated tag to commit; plain `git rev-parse vX.Y.Z` returns the tag object SHA, which will fail Homebrew's integrity check)
8. `cd /opt/homebrew/Library/Taps/mattwag05/homebrew-tap && git add -A && git commit -m "pippin vX.Y.Z" && git push`
9. `brew upgrade pippin && pippin --version` to verify

## CI

- **Forgejo Actions:** `.forgejo/workflows/ci.yaml` — runs on `macbook-air` runner (`com.matthewwagner.act-runner` LaunchAgent, labels: `macos macos-15 arm64`)
- **Release workflow:** `.forgejo/workflows/release.yaml` — triggers on `v*` tag push; builds tarball, extracts changelog, creates Forgejo release with arm64 asset
- `.github/workflows/` active on GitHub — actions pinned to full commit SHAs (not `@v4` tags) for supply-chain security; update SHAs when upgrading, don't revert to tag syntax
- **Copilot CI-fix workflow:** `.github/workflows/copilot-ci-fix.yml` — `workflow_run` trigger fires when CI fails on `main`. Extracts failed job logs via GitHub API, creates an issue with error details and fix instructions, assigns to `copilot`. The Copilot coding agent picks up the issue and opens a PR with the fix. Labels: `ci-fix`, `copilot`.
- **Copilot environment:** `.github/copilot-setup-steps.yml` — defines Xcode, SwiftFormat, and dependency setup for the Copilot coding agent. Updated when CI toolchain changes.
- **act_runner + Docker:** Runner checks Docker socket at startup. If Docker is not running, act_runner exits and all CI runs cancel silently. Start Docker first, then `brew services restart act_runner`.
- **Manual release (when CI is down):** `make tarball` → check if release exists (`GET /releases/tags/vX.Y.Z`) → POST create only if missing → `POST /releases/{id}/assets` to upload tarball. The release workflow may have partially run and already created the release — always check before creating.
- **SwiftFormat lint in CI:** Runs `swiftformat --lint pippin/ pippin-entry/ Tests/`. Always run `swiftformat` locally before pushing to avoid lint failures. Common issues: trailing spaces in multiline string literals, `&&` vs `,` in conditions, modifier ordering (`public nonisolated(unsafe) static` not `public static nonisolated(unsafe)`).

## Known Consumers

**Morning briefing scheduled task** (`~/.claude/scheduled-tasks/morning-briefing/SKILL.md`):
Invoked from Claude Cowork via Desktop Commander MCP. Depends on:
- `pippin mail list --account <acc> --format agent` (all 5 accounts)
- `pippin calendar agenda --format agent`
- `pippin reminders list --format agent`
Don't change these command shapes or agent JSON output structure without updating the task.

**Talia (OpenClaw agent on Pironman):**
Talia uses pippin indirectly via the `pippin` skill in her workspace TOOLS.md. The `memos summarize` command is the primary AI-powered feature Talia may invoke. Ensure Ollama is running on the MacBook Air before Talia attempts summarization tasks.

## Issue Tracking

Uses `bd` (beads) — Claude owns this autonomously. See `~/.claude/CLAUDE.md` § Issue Tracking for commands.
Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists.

## Forgejo API Gotchas

- **Merge API returns HTTP 204** (empty body) on success — don't pipe to JSON parser
- **Existing PRs:** Pushing to a branch with an open PR reuses it. Update title/body via `PATCH .../pulls/{n}` instead of creating a new PR
- **Action runs API:** Use `title` field (not `name`) for workflow run descriptions


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
