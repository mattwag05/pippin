# Pippin Review & Ship

/autonomous-execution

## Mission

Review changes in this repository, fix any issues, then push and open a PR on GitHub. You have full authority to modify code to make it shippable.

## Phase 1 — Inventory

1. `git status` and `git diff` (or `git diff --staged` if changes are staged) to see every change
2. `git log --oneline -10` to understand recent commit history
3. Read `CHANGELOG.md` to understand what changes claim to do
4. Flag any mismatch between the diff and the changelog
5. Run `make version` to confirm the current version

## Phase 2 — Review & Fix

Work through each changed file. For anything that fails the bar below, fix it yourself before proceeding.

### Correctness
- Logic matches the changelog description, no regressions
- Bridge patterns followed: `enum` + `static` methods, `nonisolated(unsafe)` + DispatchGroup (intentional for Swift 6)
- Async commands hop sync blocking work via `detachBlocking { ... }` — see `pippin/DetachBlocking.swift` and any `process.waitUntilExit` / `DispatchSemaphore.wait` / `sendSynchronousRequest` callsite
- Agent output uses the three-way pattern: `isJSON -> printJSON`, `isAgent -> printAgentJSON`, else text — wrapped in envelope v1 (`{v, status, duration_ms, data|error}`)
- Progress output guarded by `!outputOptions.isStructured`
- Compound IDs use the `account||mailbox||numericId` format correctly
- Mail/Notes bridges threading `softTimeoutMs` and surfacing `outcome.timedOut` to callers

### Security
- No hardcoded secrets or debug output in production paths
- JXA scripts properly escape user input
- No new attack surface

### Code Quality
- No dead code, debug artifacts, or bare `catch {}`
- Naming consistent with codebase conventions
- Shared helpers reused (validation, formatting)
- No typed error cases added for JXA failures (they arrive as `scriptFailed`)

### Tests
- New functionality has corresponding tests in `Tests/PippinTests/`
- `CLIIntegrationTests.swift` version assertion matches if version was bumped

### Changelog Accuracy
- Every meaningful diff has a matching CHANGELOG entry
- Format follows Keep a Changelog (`### Added`, `### Changed`, `### Fixed`, `### Removed`)
- Add missing entries yourself if needed

### Automated Checks
Run all three and fix failures caused by the changes:
```bash
make lint    # swiftformat check
make test    # all tests must pass (current baseline: ~1648)
make build   # release build must succeed
```

If a failure is demonstrably pre-existing and unrelated, document it in the PR body but do not block on it.

## Phase 3 — Commit & Push

Once changes are clean:

1. Stage and commit with a descriptive, scoped message:
   ```bash
   git add <specific files>
   git commit -m "$(cat <<'EOF'
   <type>: <description>

   Co-Authored-By: Claude Code <noreply@anthropic.com>
   EOF
   )"
   ```

2. Create a feature branch if on main:
   ```bash
   git checkout -b <descriptive-branch-name>
   ```

3. Push to GitHub:
   ```bash
   git push -u origin <branch-name>
   ```

## Phase 4 — Open PR on GitHub

```bash
gh pr create --title "<short summary, under 70 chars>" --body "$(cat <<'EOF'
## Summary
<2-3 sentences from changelog>

## Changes
<changelog entries as bullets, grouped by category>

## Validation
- Lint: <pass/fail> | Tests: <count> passed | Build: <pass/fail>

## Notes
<any pre-existing failures, reviewer amendments, observations>

---
Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Confirm the PR URL from the `gh` output.

## Phase 5 — Post-Merge

After the PR is merged:

```bash
git checkout main
git pull --rebase origin main
# If this was a tagged release:
git push --tags origin
```

## Phase 6 — Report

Output a terminal summary:
- PR URL (or direct push confirmation)
- Issues found and fixed during review (count and type)
- `make test` / `make lint` / `make build` final status
- Any pre-existing failures noted

## Constraints
- Never push directly to `main` on shared branches unless the changes are trivial (typo, formatting only) and no PR workflow is warranted
- Do NOT modify `Package.resolved` unless a dependency update is part of the changes
- If you discover a security vulnerability you cannot safely fix, halt and escalate to the user
- Do NOT delete the feature branch from GitHub until the PR is merged
