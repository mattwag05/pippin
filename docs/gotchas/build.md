# Build / CI / Worktree Gotchas

Load when CI is failing, `swiftformat`/`swiftlint` is misbehaving, `swift test` won't resolve, or you're juggling worktrees.

## SwiftFormat

**`swiftformat --lint` needs project root.** Run as:

```bash
cd /Users/matthewwagner/Desktop/Projects/pippin && /opt/homebrew/bin/swiftformat --lint pippin/ Tests/
```

Running from a worktree or with absolute paths skips the `.swiftformat` config and reports "0 eligible files".

**Common CI failures:** trailing spaces in multiline string literals, `&&` vs `,` in conditions, modifier ordering (`public nonisolated(unsafe) static` not `public static nonisolated(unsafe)`).

## SwiftLint in worktrees

`.swiftlint.yml` only exists in the main worktree. In a linked worktree, run:

```bash
swiftlint lint --config /Users/matthewwagner/Projects/pippin/.swiftlint.yml ...
```

(absolute path required).

## `swift test` / XCTest module missing

If `xcode-select -p` points at `/Library/Developer/CommandLineTools`, `swift test` fails with `no such module 'XCTest'`. Fix:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test
# OR (persistent):
sudo xcode-select -s /Applications/Xcode.app
```

`make test` and `make lint` inherit the same defect.

## Git worktree lifecycle

- **Cleanup order:** `git worktree remove <path>` first, then `git branch -d <branch>`. Reverse order fails — branch can't be deleted while worktree is using it.
- **Worktree blocks checkout:** If `git checkout <branch>` fails "already used by worktree at ...", run `git worktree remove --force .claude/worktrees/<name>` first.

## Beads in worktrees

- The `.beads/` dir in a linked worktree is empty (synced export, not the live DB). Run all `bd` commands from the main repo: `cd /Users/matthewwagner/Desktop/Projects/pippin && bd ...`.
- **Beads pre-commit hook re-exports root `issues.jsonl`:** `.beads/hooks/pre-commit` runs `bd hooks run pre-commit` which restages the stray root-level `issues.jsonl` on every commit. `git rm issues.jsonl` is silently reverted. Treat it as cosmetic churn; don't fight it.

## CI workflow pinning

- GitHub Actions in `.github/workflows/` are pinned to full commit SHAs (not `@v4` tags) for supply-chain security. Update SHAs when upgrading — don't revert to tag syntax.
- Legacy `.forgejo/workflows/` retained on disk but the Forgejo instance was retired 2026-04-17. Safe to delete when convenient.
