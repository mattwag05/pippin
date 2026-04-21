# CLAUDE.md — pippin

macOS CLI toolkit for Apple app automation (Mail, Voice Memos, Calendar, Reminders, Notes, Contacts, Audio, Browser). Swift 6, SPM build system, macOS 15+.

Repo: `https://github.com/mattwag05/pippin` (canonical — GitHub is source of truth since 2026-04-17)
Remote: `origin` → GitHub
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
| `pippin/MCP/` | MCP server runtime — `JSONValue`, `JSONRPCTypes`, `ToolRegistry`, `MCPServerRuntime` |
| `pippin/Commands/McpServerCommand.swift` | `pippin mcp-server` — stdio JSON-RPC loop (see `docs/mcp-server.md`) |
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

## CI

- `copilot-ci-fix.yml` — `workflow_run` trigger fires when CI fails on `main`, files an issue, assigns to `copilot`. Copilot opens a PR with the fix.
- `copilot-setup-steps.yml` — Xcode/SwiftFormat/deps for the Copilot coding agent.
- Workflow pinning, swiftformat traps, and other CI/build gotchas: [docs/gotchas/build.md](docs/gotchas/build.md).

## Known Consumers

**Agent-mode envelope v1 (2026-04-20, breaking):**
Every `pippin <cmd> --format agent` response is wrapped in a versioned envelope. Both success and error shapes are documented in [docs/mcp-server.md § Envelope v1](docs/mcp-server.md#envelope-v1-breaking-change-2026-04-20). Summary:
- Success: `{"v":1,"status":"ok","duration_ms":N,"data":<payload>}`
- Error: `{"v":1,"status":"error","duration_ms":N,"error":{"code":"…","message":"…","remediation":{…}?}}`
- `data` carries the previous raw payload shape unchanged, so single-field extractions like `.error.code` still work; iterations like `jq 'length'` must be rewritten as `jq '.data | length'`.
- Schema version bumps on any future breaking change. Canonical constant is `AGENT_SCHEMA_VERSION` in [pippin/Formatting/AgentOutput.swift](pippin/Formatting/AgentOutput.swift).

**Morning briefing scheduled task** (`~/.claude/scheduled-tasks/morning-briefing/SKILL.md`):
Invoked from Claude Cowork via Desktop Commander MCP. Depends on:
- `pippin mail list --account <acc> --format agent` (all 5 accounts)
- `pippin calendar agenda --format agent`
- `pippin reminders list --format agent`
Don't change these command shapes or agent JSON output structure without updating the task. After envelope v1, the task reads the payload from `.data` instead of the top level.

**Talia (OpenClaw agent on Raspberry Pi):**
Talia uses pippin indirectly via the `pippin` skill in her workspace TOOLS.md. The `memos summarize` command is the primary AI-powered feature Talia may invoke. Ensure Ollama is running on the MacBook Air before Talia attempts summarization tasks. Envelope v1 applies — Talia's `memos summarize --format agent` result now lives under `.data`.

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

- **Disable `export.auto` and `export.git-add` in CI/worktree setups.** The beads pre-commit hook (`prepare-commit-msg`) runs `bd` auto-export with `export.git-add=true`, which silently stages a root-level `/issues.jsonl` *in addition to* the canonical `.beads/issues.jsonl` that the hook also writes. Every commit picked up the stray root file until caught. Fix: `bd config set export.auto false` in each worktree (and main) — it's written to `.beads/config.yaml` so it ships with the repo. If you need a fresh JSONL snapshot, run `bd export -o .beads/issues.jsonl` manually.
- **`export.path` resolves relative to `.beads/`, not repo root.** Setting `export.path=.beads/issues.jsonl` actually writes to `.beads/.beads/issues.jsonl` (and silently fails when the parent dir doesn't exist). The default `issues.jsonl` is correct — leave it alone; use `export.auto=false` to gate the hook.
- **Worktrees have their own `.beads/` state.** `bd update --claim` / `bd close` run in the main repo do NOT propagate to a worktree's `.beads/issues.jsonl` until a commit or manual export. Run `bd` commands from whichever repo's history the change should land in. The worktree's bd database can diverge from main — it's not a bug, it's how bd worktrees work.
- **`bd config set` writes to `.beads/config.yaml`**, which is tracked — fixes propagate via commit to every clone and worktree.
- **`/issues.jsonl` is gitignored** as belt-and-suspenders in case the hook's `git add` is ever re-enabled; the hook's explicit `git add` bypasses gitignore, so the config fix is the real guard.

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

