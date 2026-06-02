# Build / CI / Worktree Gotchas

Load when CI is failing, `swiftformat` is misbehaving, `swift test` won't resolve, or you're juggling worktrees.

## SwiftFormat

**`swiftformat --lint` needs project root.** Run as:

```bash
cd /Users/matthewwagner/Projects/pippin && /opt/homebrew/bin/swiftformat --lint pippin/ Tests/
```

Running from a worktree or with absolute paths skips the `.swiftformat` config and reports "0 eligible files".

**Common CI failures:** trailing spaces in multiline string literals, `&&` vs `,` in conditions, modifier ordering (`public nonisolated(unsafe) static` not `public static nonisolated(unsafe)`).

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

- The `.beads/` dir in a linked worktree is empty (synced export, not the live DB). Run all `bd` commands from the main repo: `cd /Users/matthewwagner/Projects/pippin && bd ...`.
- **Root `issues.jsonl` is gated, not regenerated:** `.beads/config.yaml` sets `export.auto: false` and `export.path: "issues.jsonl"` (which resolves *inside* `.beads/`, so the canonical export is `.beads/issues.jsonl`). The stray repo-root `issues.jsonl` was an accidental early commit; it's gitignored (`/issues.jsonl`) and `git rm --cached issues.jsonl` now sticks (the hook no longer restages it).

## CI workflow pinning

- GitHub Actions in `.github/workflows/` are pinned to full commit SHAs (not `@v4` tags) for supply-chain security. Update SHAs when upgrading — don't revert to tag syntax.
- `.forgejo/workflows/` is an active self-hosted mirror of the CI/release gates (last normalized 2026-06-01). It deliberately omits the Setup-Xcode step (the self-hosted `macos` runner already has Xcode selected). Keep it in parity with `.github/workflows/` when changing gates.

## Local CI in a macOS VM (`make ci-vm`)

GitHub `ci.yml` is disabled; CI runs locally via `make ci-vm` (Tart VM) or `make ci` (native). Full guide: [../local-ci.md](../local-ci.md). Three gotchas, all already handled in `scripts/ci-vm.sh`:

1. **Homebrew missing in the VM.** Non-interactive ssh skips `~/.zprofile` → minimal `PATH` without `/opt/homebrew/bin`, so `brew`/`swiftformat` aren't found. The script `export`s the Homebrew path in the remote command.
2. **SwiftFormat `--lint` path parsing.** `swiftformat --lint pippin` (no trailing slash) errors `--lint argument does not expect a value` on SwiftFormat 0.61. Use trailing slashes: `pippin/ pippin-entry/ Tests/`.
3. **ssh `MaxAuthTries`.** sshpass offers agent keys first and trips the VM sshd ("Too many authentication failures"). Force password-only auth: `-o PreferredAuthentications=password -o PubkeyAuthentication=no -o IdentitiesOnly=yes`.

**SourceKit "no member" diagnostics go stale:** right after you add a new symbol (a helper, a static func), SourceKit may report `Type 'X' has no member 'Y'` while `swift build`/`swift test` compile and pass fine. Trust the build, not the in-editor diagnostic — it catches up after a reindex.
