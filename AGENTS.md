# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd onboard` to get started.

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work atomically
bd close <id>         # Complete work
bd dolt push          # Push beads data to remote
```

## GitHub Copilot Coding Agent

This repo has a Copilot coding agent configured for automatic CI troubleshooting.

### How it works

1. CI fails on `main` → `.github/workflows/copilot-ci-fix.yml` triggers
2. Workflow extracts failed job logs and creates an issue (labels: `ci-fix`, `copilot`)
3. Copilot agent picks up the issue, reads the logs, and opens a fix PR
4. Human reviews and merges

### Environment setup

`.github/copilot-setup-steps.yml` defines the agent's build environment:
- Xcode (latest stable)
- SwiftFormat (`brew install swiftformat`)
- Swift package resolution (`swift package resolve`)
- Build verification (`swift build`)

### Common CI failure patterns for agents

| Symptom | Root cause | Fix |
|---------|-----------|-----|
| `swiftformat --lint` errors | Code not formatted | Run `swiftformat pippin/ pippin-entry/ Tests/` |
| Modifier order errors | Wrong keyword order | `public nonisolated(unsafe) static`, not `public static nonisolated(unsafe)` |
| `&&` vs `,` in conditions | SwiftFormat `andOperator` rule | Use `,` instead of `&&` in `if`/`guard`/`while` |
| Trailing space in multiline strings | Blank lines in `"""` blocks | Remove trailing whitespace from blank lines in discussion strings |
| Build failure | Missing import or type error | Check `swift build` output for the exact file and line |
| Test failure | Assertion mismatch | Run `swift test --filter <TestName>` to isolate |

### Quality gates (must pass before PR)

```bash
swift build                                    # Debug build
swift test                                     # All tests
swift build -c release                         # Release build
swiftformat --lint pippin/ pippin-entry/ Tests/ # Lint
```

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** with file operations to avoid hanging on confirmation prompts.

Shell commands like `cp`, `mv`, and `rm` may be aliased to include `-i` (interactive) mode on some systems, causing the agent to hang indefinitely waiting for y/n input.

**Use these forms instead:**
```bash
# Force overwrite without prompting
cp -f source dest           # NOT: cp source dest
mv -f source dest           # NOT: mv source dest
rm -f file                  # NOT: rm file

# For recursive operations
rm -rf directory            # NOT: rm -r directory
cp -rf source dest          # NOT: cp -r source dest
```

**Other commands that may prompt:**
- `scp` - use `-o BatchMode=yes` for non-interactive
- `ssh` - use `-o BatchMode=yes` to fail instead of prompting
- `apt-get` - use `-y` flag
- `brew` - use `HOMEBREW_NO_AUTO_UPDATE=1` env var

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
