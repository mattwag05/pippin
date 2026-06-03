# CLAUDE.md — pippin

macOS CLI toolkit for Apple app automation (Mail, Voice Memos, Calendar, Reminders, Notes, Contacts, Audio, Browser). Swift 6, SPM build system, macOS 15+.

Repo: `https://github.com/mattwag05/pippin` (canonical — GitHub is source of truth since 2026-04-17)
Remote: `origin` → GitHub
Homebrew tap: `mattwag05/tap` — formula at `/opt/homebrew/Library/Taps/mattwag05/homebrew-tap/Formula/pippin.rb`

**CLAUDE.md auto-commit (pippin-only carve-out):** edits to this file (`CLAUDE.md`) are pre-authorized for autonomous commit + push. Don't ask before committing them — overrides the global "only commit when explicitly asked" rule for this single file. Keeps session learnings from stranding locally.

## Onboarding — Knowledge Graph (`graphify-out/`)

A queryable knowledge graph of the whole repo lives in [`graphify-out/`](graphify-out/) (committed map; built with [graphify](https://github.com/iruletheworld/graphify)). New here? Start with [`graphify-out/GRAPH_REPORT.md`](graphify-out/GRAPH_REPORT.md) (god nodes, community map, suggested questions), open `graphify-out/graph.html` for the interactive view, or query the graph instead of grepping:

```bash
graphify query "How does an MCP tool call reach a bridge?"   # BFS over graph.json
graphify path "McpServerCommand" "MailBridge"                # shortest path between two concepts
graphify explain "DetachBlocking"                            # plain-language node + neighbors
graphify update .                                            # refresh AST nodes after code changes (no LLM)
```

~4.8k nodes across ~320 communities; AST (free, local) for Swift + agent-extracted semantic edges for docs/rationale. `graphify update .` re-clusters from the AST and **preserves the committed community labels** in `graphify-out/.graphify_labels.json` (tracked — don't gitignore it). `/graphify` is registered for **Claude Code, Codex, OpenCode, Pi, Hermes, and OpenClaw** — on a fresh machine, run `graphify install --platform <claude|codex|opencode|pi|hermes|claw>` to wire it up, then rebuild with `/graphify .` (or `graphify update .` for code-only refreshes).

## Commands

```bash
make build          # xcrun --sdk macosx swift build -c release
make test           # xcrun --sdk macosx swift test (1,700+ tests, 0 failures expected)
make lint           # swiftformat --lint on all sources
make ci             # full CI gates natively (build + test + swiftformat + detach-lint) — fast
make ci-vm          # full CI gates in an isolated ephemeral macOS VM (Tart) — see Local CI
make install        # build + copy to ~/.local/bin/pippin + install zsh completions
make release        # build + copy release binary to .build/release-artifacts/
make tarball        # release + tar.gz artifact
make version        # print current version from Version.swift
```

**SDK selection:** `make build`/`make test` invoke `xcrun --sdk macosx` so they route through `xcode-select`. On a CLT-only macOS 26 host the CLT SDK lacks `XCTest.framework` and tests fail with "no such module XCTest" — install Xcode or `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. See pippin-ncr.

## Architecture

| Path | Purpose |
|------|---------|
| `pippin/` | `PippinLib` — all application logic (importable by tests) |
| `pippin/{Mail,Memos,Calendar,Reminders,Notes,Contacts,Messages,Audio,Browser}Bridge/` | Per-app bridges. JXA via `Scripting/ScriptRunner.swift` for Mail/Notes/Contacts; EventKit for Calendar/Reminders; GRDB for Memos/Messages |
| `pippin/MailAIBridge/` | Embeddings, semantic search, triage, prompt-injection scanner — Ollama-backed |
| `pippin/AIProvider/` | Ollama + Claude backends. `isMCPContext()` and `aiRequestTimeoutSeconds()` shorten budgets to 50s when `PIPPIN_MCP=1` |
| `pippin/Commands/` | ArgumentParser entry points. REPL (`ShellCommand`), system dashboard (`StatusCommand`), MCP server (`McpServerCommand`), plan-and-execute (`DoCommand`), background jobs (`JobCommand`), parallel dispatch (`BatchCommand`). **`audio`/`browser` are gated behind `PIPPIN_EXPERIMENTAL=1`** (hidden by default; see `Pippin.swift`) |
| `pippin/MCP/ToolRegistry.swift` | Single source of truth for the MCP tool surface — adding a tool is one entry here. Currently **44 tools**; verify with `pippin mcp-server --list-tools \| jq '.tools \| length'` (or count `name:` entries). |
| `pippin/Models/` | DTO structs for each bridge. `Codable, Sendable`. Names: `{Mail,Calendar,Reminder,Note,Contact,Messages,MailAI,Audio,Browser}Models.swift` |
| `pippin/Templates/` | Built-in summarization + smart-create + extract-actions prompt templates |
| `pippin/Formatting/AgentOutput.swift` | `printAgentJSON<T>()` + envelope v1 `{v, status, duration_ms, data\|error}` |
| `pippin/SoftTimeout.swift` | `SoftTimeout.clamp(_:)` + `defaultMs` (22000). Bridges return `Outcome<T>` `{results, timedOut}`; callers thread it through `output.emit(…, timedOut:, timedOutHint:)`. `--soft-timeout-ms` is **not** a user CLI flag; the default applies at the Swift API |
| `pippin/MailBridge/MailBridge.swift` | Cross-account timeout scaling: `listMessages`, `listActivity`, `searchMessages` auto-detect `crossAccount` from `(account == nil)` and scale ScriptRunner hard caps (single→cross: list 10→60s, list+preview 50→100s, activity 30→75s, activity+preview 70→115s, search 45→65s, search+body 75→95s). Prevents hard-timeout crashes on multi-account setups (see `TIMEOUT_ANALYSIS.md`). Under MCP (`PIPPIN_MCP=1`), all three hard caps are clamped to 55s by `MailBridge.clampHardTimeout` — below the 60s `runChild` cap — so a wedged osascript self-reaps gracefully (partial results) instead of being SIGKILLed by the MCP layer. The 22s soft cap fires first in normal operation, so the clamp only affects the pathological wedge case. |
| `pippin/DetachBlocking.swift` | **Load-bearing.** `detachBlocking { ... }` hops sync, thread-blocking work (subprocess waits, `DispatchSemaphore.wait`, `sendSynchronousRequest`) off the cooperative pool. Required at every async-command → sync-bridge boundary; failure to hop wedges `pippin mcp-server` under fanout. Full pattern in [docs/gotchas/swift.md](docs/gotchas/swift.md) |
| `pippin/BatchBudget.swift` | `BatchBudget.forCurrentContext()` — 50s wall-clock cap under MCP, unlimited in CLI. Used by `memos export/transcribe --all` for partial-results-with-warning instead of mid-batch SIGKILL |
| `pippin/SessionState.swift` | REPL session state at `~/.config/pippin/session.json` — active account, last-used IDs, command history |
| `pippin-entry/` | Thin `@main` executable target |
| `Tests/PippinTests/` | XCTest suite (1,700+ tests). Integration tests in `CLIIntegrationTests.swift` shell out to the built binary |
| `.github/workflows/` | CI (`ci.yml`), advanced CodeQL (`codeql.yml`), unicode safety scan, release |

**Reminders/Calendar flag footgun:** `reminders --list` and `calendar create --calendar` take EventKit **IDs** (from `reminders lists` / `calendar list`), not names. `reminders create`'s title is **positional**. Filter calendar events by name with `--calendar-name` (`--calendar` is an ID). `actions extract --list` and `calendar smart-create`, by contrast, *do* resolve list/calendar names.

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

### Model recommendation

Default Ollama model is **`gemma4:latest`** — fast, concise summaries. Benchmark (MacBook Air M4, 24 GB, 2026-04-03): gemma4 ~22s/238 tok vs `qwen3.5:latest` ~45s/589 tok (qwen's chain-of-thought adds latency without quality gains for structured extraction); `claude-sonnet-4-6` is fastest (~2-3s) and highest quality but needs an API key + internet. Fall back to Claude when speed or quality is critical.

### Config resolution order (AIProviderFactory.swift)

1. `--provider` / `--model` CLI flags (highest priority)
2. `~/.config/pippin/config.json` `ai.provider` / `ai.ollama.model` / `ai.claude.model`
3. Defaults: provider=`ollama`, model=provider-specific default, Ollama URL=`http://localhost:11434`

### Claude API key resolution

1. `--api-key` CLI flag
2. `ANTHROPIC_API_KEY` environment variable
3. Vaultwarden secret lookup via `get-secret "Anthropic API"`

## Gotchas (load on demand)

Hard-won patterns live in [`docs/gotchas/`](docs/gotchas/) — load the file matching the area you're touching:

| Working in… | Load |
|-------------|------|
| `*Bridge/` (Mail, Notes, Reminders, Calendar, Audio, Contacts, Browser) | [docs/gotchas/jxa.md](docs/gotchas/jxa.md) |
| `pippin/Commands/`, ArgumentParser, Swift 6 concurrency, agent JSON | [docs/gotchas/swift.md](docs/gotchas/swift.md) |
| CI failures, swiftformat/swiftlint, `swift test`, worktrees | [docs/gotchas/build.md](docs/gotchas/build.md) |
| `pippin/MCP/`, `McpServerCommand.swift` | [docs/gotchas/mcp.md](docs/gotchas/mcp.md) |

When you discover a new gotcha, append to the appropriate file.

## Releases

End-to-end procedure lives in the **release skill**: [docs/skills/release/SKILL.md](docs/skills/release/SKILL.md). After cloning, run `make link-skills` once so the skill is discoverable from `.claude/skills/`. Triggered by "release pippin", "ship vX.Y.Z", "bump pippin".

## Changelog (UPDATE WITH EVERY CHANGE)

`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/). **Every user-visible code change MUST add an entry to the `### [Unreleased]` block before (or with) its push** — do not let fixes land undocumented. This is mandatory, not optional.

- **Format:** `- [bug|feat|perf|refactor|build|ci|docs] <concise user-facing description>. Closes pippin-XXX.` (omit the `Closes` clause if there's no bd issue).
- **Subsection:** `feat` → `### Added`; `bug`/`perf` → `### Fixed`; `refactor`/`build`/`ci` → `### Changed`; `docs` → `### Documentation`.
- **Describe the user-facing effect**, not the diff (e.g. "`calendar show <prefix>` now works for recurring events", not "fixed findEventByPrefix").
- **Skip** pure housekeeping (beads status/export, gitignore tweaks, the changelog edit itself).
- The changelog is **docs-only** → exempt from the `/simplify` pre-push gate; commit it alongside the fix or immediately after.
- The release skill consumes `### [Unreleased]` to cut version notes, so keeping it current is load-bearing, not just courtesy.

## CI

**The GitHub `ci.yml` workflow is DISABLED** (`gh workflow disable ci.yml`, 2026-06-01) — we run CI locally instead of on slow GitHub-hosted `macos-15` runners. CI is now `make ci-vm` (full parity in an isolated ephemeral macOS VM) or `make ci` (fast, native). See **Local CI** below. Re-enable with `gh workflow enable ci.yml` if needed. CodeQL / unicode-scan / release workflows remain active.

- `.forgejo/workflows/` is an **active self-hosted mirror** of the CI + release gates (runner label `macos`). Keep it in parity with `.github/workflows/` when changing gates — it intentionally omits Setup-Xcode (self-hosted runner has Xcode) but MUST keep the detach-blocking lint.
- Workflow pinning, swiftformat traps, and other CI/build gotchas: [docs/gotchas/build.md](docs/gotchas/build.md).

## Local CI (Tart VM — replaces GitHub-hosted runners)

`make ci-vm` runs the `ci.yml` gates inside an ephemeral, isolated macOS VM on Apple Silicon — zero GitHub-hosted minutes, no listening self-hosted runner (so this public repo is never exposed to forked-PR code execution). Full guide: [docs/local-ci.md](docs/local-ci.md).

- **What it does:** `scripts/ci-vm.sh` clones a fresh VM from the `pippin-ci-base` image (Cirrus Labs `macos-sequoia-xcode`, ~90 GB, **shared with SwiftClaw**), rsyncs the working tree in, runs `swift build`/`swift test` + swiftformat + the detach-blocking lint, then destroys the VM.
- **One-time setup:** `brew install cirruslabs/cli/tart hudochenkov/sshpass/sshpass` then `tart clone ghcr.io/cirruslabs/macos-sequoia-xcode:latest pippin-ci-base`.
- **`make ci`** runs the same gates natively (no VM) for fast pre-push feedback.
- Gotchas (Homebrew PATH, swiftformat `--lint` paths, ssh `MaxAuthTries`) are baked into `scripts/ci-vm.sh` and documented in [docs/local-ci.md](docs/local-ci.md) / [docs/gotchas/build.md](docs/gotchas/build.md).
- **`make ci` (or `ci-vm`) is the ONLY gate before pushing** now that `ci.yml` is disabled — nothing on GitHub catches build/format/test failures anymore. Run it every push; a `redundantSelf` swiftformat violation reached `main` this session for exactly this reason.
- **`git push origin main` succeeds despite a `remote: - Changes must be made through a pull request` ruleset notice** — it's non-blocking (evaluate-mode / owner bypass); the ref still updates (look for the `oldsha..newsha  main -> main` line). Don't mistake it for a rejected push.

## CodeQL

Advanced setup via `.github/workflows/codeql.yml` — GitHub default setup is disabled. To toggle: `gh api -X PATCH repos/mattwag05/pippin/code-scanning/default-setup -f state=<configured|not-configured>`.

SPM version resolution for GRDB is the slow step (~455 s cold). Fixed by caching `~/Library/Caches/org.swift.swiftpm` keyed on `Package.resolved` in the workflow.

## Known Consumers

**Agent-mode envelope v1 (2026-04-20, breaking):**
Every `pippin <cmd> --format agent` response is wrapped in a versioned envelope. Both success and error shapes are documented in [docs/mcp-server.md § Envelope v1](docs/mcp-server.md#envelope-v1-breaking-change-2026-04-20). Summary:
- Success: `{"v":1,"status":"ok","duration_ms":N,"data":<payload>}`
- Error: `{"v":1,"status":"error","duration_ms":N,"error":{"code":"…","message":"…","remediation":{…}?}}`
- `data` carries the previous raw payload shape unchanged, so single-field extractions like `.error.code` still work; iterations like `jq 'length'` must be rewritten as `jq '.data | length'`.
- Schema version bumps on any future breaking change. Canonical constant is `AGENT_SCHEMA_VERSION` in [pippin/Formatting/AgentOutput.swift](pippin/Formatting/AgentOutput.swift).

**Morning briefing scheduled task** (`~/.claude/scheduled-tasks/morning-briefing/SKILL.md`):
Invoked from Claude Cowork via Desktop Commander MCP. Depends on:
- `pippin mail list --account <acc> --format agent` (one call per configured account)
- `pippin calendar agenda --format agent`
- `pippin reminders list --format agent`
Don't change these command shapes or agent JSON output structure without updating the task. After envelope v1, the task reads the payload from `.data` instead of the top level.

**Talia (Hermes-Agent on M5, `~/.local/bin/hermes`):**
Talia runs as Hermes-Agent on the M5 MacBook Pro since 2026-04-22 (replaced the prior OpenClaw/Talia install on the M4 Air). Pippin is registered as a stdio MCP (`pippin mcp-server`) — Talia drives the full tool registry (mail/calendar/reminders/contacts/notes/memos/messages/digest/jobs/batch) directly. `memos summarize` is the primary AI-powered feature; ensure Ollama is running on M5 before invocation. Envelope v1 applies — `--format agent` payloads live under `.data`.

**MCP clients via `pippin mcp-server`:**
Claude Code, Claude Desktop, and any other MCP-compatible client may attach to pippin over stdio and call tools like `mail_list`, `calendar_today`, `reminders_create`, `status`. The MCP server **shells out to `pippin <cmd> --format agent`** for every tool call — so any change to an agent-mode JSON shape propagates automatically (including envelope v1), but any change to a CLI flag name or a snake_case tool-level key (like `AgentError.code`) is a breaking change for MCP clients. Tool registry lives in `pippin/MCP/ToolRegistry.swift`; adding a new tool is one entry. See `docs/mcp-server.md` for the full tool list and wiring instructions.

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

### Operating principles (learned the hard way)

- **Verify "stale-open" issues against current code before implementing.** Many filed bugs were already fixed but never closed (mail_list/activity MCP timeouts, doctor latency probes, AIProvider MCP timeout, Voice Memos batch cap, Notes timedOut surfacing). Grep/read the code first and close-as-done if already implemented — don't re-build it.
- **Broad "find bugs in area X" audits now mostly surface false-positives or documented-intended behavior** — this codebase is mature. Verify EACH finding against the actual code AND the `--help`/option text before acting (e.g. `contacts edit --email` "data loss" is the documented "replaces all"). Real bugs come from direct reads of a specific mechanism + an empirical binary test, not broad sweeps.
- **Disable `export.auto` and `export.git-add` in CI/worktree setups.** The beads pre-commit hook (`prepare-commit-msg`) runs `bd` auto-export with `export.git-add=true`, which silently stages a root-level `/issues.jsonl` *in addition to* the canonical `.beads/issues.jsonl` that the hook also writes. Every commit picked up the stray root file until caught. Fix: `bd config set export.auto false` in each worktree (and main) — it's written to `.beads/config.yaml` so it ships with the repo. If you need a fresh JSONL snapshot, run `bd export -o .beads/issues.jsonl` manually.
- **`export.path` resolves relative to `.beads/`, not repo root.** Setting `export.path=.beads/issues.jsonl` actually writes to `.beads/.beads/issues.jsonl` (and silently fails when the parent dir doesn't exist). The default `issues.jsonl` is correct — leave it alone; use `export.auto=false` to gate the hook.
- **Worktrees have their own `.beads/` state.** `bd update --claim` / `bd close` run in the main repo do NOT propagate to a worktree's `.beads/issues.jsonl` until a commit or manual export. Run `bd` commands from whichever repo's history the change should land in. The worktree's bd database can diverge from main — it's not a bug, it's how bd worktrees work.
- **`bd config set` writes to `.beads/config.yaml`**, which is tracked — fixes propagate via commit to every clone and worktree.
- **`bd` runs in embedded Dolt mode here** (`.beads/embeddeddolt/`) — `bd doctor` and `bd dolt status` print "not supported in embedded mode"; use `bd list`/`bd stats` to inspect and `bd dolt push` to sync (it works).
- **`/issues.jsonl` is gitignored** as belt-and-suspenders in case the hook's `git add` is ever re-enabled; the hook's explicit `git add` bypasses gitignore, so the config fix is the real guard.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update `CHANGELOG.md`** (if user-visible code changed) - Add an entry to `### [Unreleased]` (see the **Changelog** section above). Mandatory.
4. **Update issue status** - Close finished work, update in-progress items
5. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
6. **Clean up** - Clear stashes, prune remote branches
7. **Verify** - All changes committed AND pushed
8. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->

