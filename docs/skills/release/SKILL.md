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

**Before tagging**, run `make ci` (or `make ci-vm`) locally and confirm green — the GitHub `ci.yml` build/test workflow is **disabled**, so nothing on push catches build/test failures.

The GitHub **`release.yml` workflow is also disabled** (pippin-6qi — its `macos-15` runner kept cancelling). The tag push fires the self-hosted **`.forgejo/workflows/release.yaml`** (publishes to the tailnet Forgejo), but the **GitHub release is published locally** — do it now:

```bash
make tarball   # → .build/release-artifacts/pippin-X.Y.Z-arm64-macos.tar.gz
awk "/^## \[X.Y.Z\]/{f=1;next} f&&/^## \[/{exit} f{print}" CHANGELOG.md > /tmp/notes.md
gh release create vX.Y.Z --title "vX.Y.Z — pippin" --notes-file /tmp/notes.md --verify-tag \
  .build/release-artifacts/pippin-X.Y.Z-arm64-macos.tar.gz
```

This reproduces exactly what the old `release.yml` produced (title, changelog body, arm64 asset, not a pre-release). Verify with `gh release view vX.Y.Z`.

### 7. Update the Homebrew tap formula

The formula installs the **pre-signed release tarball** (not a from-source build) so brew binaries carry a stable Developer ID signature. **Step 6 must have run first** — the asset has to exist on the GitHub release before the formula points at it. Edit `/opt/homebrew/Library/Taps/mattwag05/homebrew-tap/Formula/pippin.rb` and update:

> **Note (pippin-6sf, corrects pippin-jt9):** the signature gives a stable code identity, but **brew TCC grants do NOT persist across upgrades** — macOS keys a bare-CLI grant on the binary's resolved path, and brew's path is the versioned `Cellar/<ver>/bin/pippin`, so each upgrade re-prompts. The durable, TCC-granted home is `~/.local/bin/pippin` (stable copied path via `make install` — step 10). Agents/scheduled tasks point there, not at brew.
- `url` → `https://github.com/mattwag05/pippin/releases/download/vX.Y.Z/pippin-X.Y.Z-arm64-macos.tar.gz`
- `version` → `X.Y.Z`
- `sha256` → `shasum -a 256 .build/release-artifacts/pippin-X.Y.Z-arm64-macos.tar.gz` (must match the uploaded asset)
- `assert_match` version string → the new version

Then lint: `brew style mattwag05/tap/pippin` (must be clean). The `test do` block asserts both the version and a `Developer ID Application` signature — if the asset is ad-hoc, the formula test fails by design.

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
# Restart both [agent] services so their children pick up the new inode:
launchctl kickstart -k gui/$(id -u)/ai.agent-runtime.gateway
launchctl kickstart -k gui/$(id -u)/ai.agent-runtime.webui
# Trust-but-verify: every live MCP child should be on the new binary's inode.
for p in $(pgrep -f "pippin mcp-server"); do lsof -p "$p" | awk '/txt.*pippin/{print $(NF-1)}'; done | sort -u
stat -f %i ~/.local/bin/pippin   # each inode above should equal this
```

The claude-plugins `pippin` plugin's `.mcp.json` uses bare `pippin`, so the shadowed version is what Claude Code actually spawns as the MCP server — both must be current. `ai.agent-runtime.webui` is a **second** launchd-managed service that also spawns `pippin mcp-server` children; both services must be restarted or the webui's children stay on the stale binary inode.

## Failure recovery

- **GitHub release missing after a tag push**: the GitHub `release.yml` is **disabled** (pippin-6qi — `macos-15` runner kept cancelling), so a tag push never auto-creates the GitHub release. This is expected — publishing it locally is **step 6**, not a recovery action. If you skipped it, run the `make tarball` + `gh release create` recipe in step 6.
- **Tap push rejected**: someone else updated the tap. `cd /opt/homebrew/Library/Taps/mattwag05/homebrew-tap && git pull --rebase && git push`.
- **`brew upgrade` says "already up to date"**: `brew update` first, then retry.
- **`brew upgrade`/`reinstall` fails `build.rb ... exited with 1` (Homebrew 6.0.x tap-trust)**: Homebrew 6.0 added a global tap-trust gate whose in-sandbox check fails the build (with no log) when *any* tap is untrusted — and on 6.0.1 it **still fails even after `brew trust`ing every tap** (verified 2026-06-12: trusting cleared the *warning* but not the build error). Do **NOT** waste time on `brew trust mattwag05/tap/pippin` — pippin's tap is already trusted; that's never the culprit. The reliable workaround is the env-var bypass: `HOMEBREW_NO_REQUIRE_TAP_TRUST=1 brew upgrade pippin` (or set it in your shell rc until Homebrew fixes the gate). The release artifacts are unaffected — the checksum verifies and the binary installs fine under the bypass. Since agents/[agent] run `~/.local/bin/pippin` (step 10's `make install`), a brew-path hiccup doesn't block the release.
- **`pippin --version` still shows old version**: see step 10 — almost always the dual-install shadow.

## After release

- File a beads issue if anything in this procedure was wrong/stale and update this skill.
- Don't `bd close` the release issue until step 10 is verified green.
