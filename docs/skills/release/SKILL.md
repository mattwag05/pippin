---
name: pippin-release
description: Cut a new pippin release — bump version, tag, push, update Homebrew tap, verify install. Use when the user says "release vX.Y.Z", "ship pippin", "cut a release", or "bump pippin".
---

# Pippin Release

Prescriptive end-to-end release procedure. Every step matters; skipping the tap update or the dual-install verify leaves users on a stale binary.

## When to invoke

User says: "release pippin", "ship vX.Y.Z", "cut a release", "bump pippin to X.Y.Z", or anything equivalent. Confirm the target version with the user before starting if not specified.

## Preconditions

- Working tree is clean on `main` (`git status` shows nothing).
- All beads issues for the release are closed (`bd ready` shows no in-progress release work).
- `swift test` passed locally.
- You are in the main checkout, not a worktree (the Homebrew tap is at `/opt/homebrew/...`, accessible from anywhere, but releases should land on `main`).

## Steps

### 1. Bump version

Edit `pippin/Version.swift` — bump the version constant. Semantic versioning: patch for fixes, minor for new commands/features, major for breaking CLI/agent-JSON changes.

### 2. Update CHANGELOG.md

- Add a new `## [X.Y.Z] - YYYY-MM-DD` section with the changes.
- Update the `[Unreleased]` comparison link's base to the new version tag.
- Add a new comparison link entry at the bottom: `[X.Y.Z]: https://github.com/mattwag05/pippin/compare/vPREV...vX.Y.Z`.
- **Avoid duplicate version entries** in the comparison link table — these go stale silently.

### 3. Update README.md (only if needed)

If new commands or subcommands shipped, add them to the README's command table or examples.

### 4. Run tests

```bash
make test
```

Must pass with 0 failures. If anything red, stop and fix before continuing.

### 5. Commit and tag

```bash
git add pippin/Version.swift CHANGELOG.md README.md
git commit -m "chore: bump to vX.Y.Z"
git tag -a vX.Y.Z -m "vX.Y.Z"
```

The annotated tag (`-a`) is **required** — bare `git tag vX.Y.Z` fails with "no tag message" in the Homebrew tap update step.

### 6. Push commit + tag

```bash
git push origin main --tags
```

Wait for CI to go green on GitHub before continuing — release artifacts depend on the tag being live.

### 7. Update the Homebrew tap formula

Edit `/opt/homebrew/Library/Taps/mattwag05/homebrew-tap/Formula/pippin.rb`. Update three fields:
- `tag` → `vX.Y.Z`
- `revision` → output of `git rev-parse vX.Y.Z^{}` (the `^{}` dereferences the annotated tag to a commit SHA — plain `git rev-parse vX.Y.Z` returns the tag object SHA, which fails Homebrew's integrity check)
- `assert_match` version string → the new version

### 8. Commit and push the tap

```bash
cd /opt/homebrew/Library/Taps/mattwag05/homebrew-tap
git add Formula/pippin.rb
git commit -m "pippin vX.Y.Z"
git push
```

### 9. Verify the upgrade

```bash
brew upgrade pippin && pippin --version
```

Expected: prints the new version.

### 10. Resolve dual-install shadow

If this machine has both `/opt/homebrew/bin/pippin` and `~/.local/bin/pippin` (from `make install`), `~/.local/bin` sits earlier on PATH and shadows brew. `brew upgrade pippin` alone leaves `which pippin` pointing at the stale local copy.

```bash
which pippin && pippin --version
```

If `which` returns `~/.local/bin/pippin`, also run:

```bash
make install
```

The claude-plugins `pippin` plugin's `.mcp.json` uses bare `pippin`, so the shadowed version is what Claude Code actually spawns as the MCP server — both must be current.

## Failure recovery

- **CI red after push**: the tag is live but artifacts are stale. Fix forward (don't delete the tag — Homebrew users may have already pulled). Cut a patch release.
- **Tap push rejected**: someone else updated the tap. `cd /opt/homebrew/Library/Taps/mattwag05/homebrew-tap && git pull --rebase && git push`.
- **`brew upgrade` says "already up to date"**: `brew update` first, then retry.
- **`pippin --version` still shows old version**: see step 10 — almost always the dual-install shadow.

## After release

- File a beads issue if anything in this procedure was wrong/stale and update this skill.
- Don't `bd close` the release issue until step 10 is verified green.
