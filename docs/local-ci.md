# Local CI — running the macOS CI gates off GitHub-hosted runners

The GitHub-hosted `macos-15` runners are slow and queue-bound. As of 2026-06-01
pippin's GitHub `ci.yml` workflow is **deleted** (disabled 2026-06, removed 2026-07) and CI
runs locally on Apple Silicon instead. Two tiers:

| Command | Where | Speed | Use |
|---------|-------|-------|-----|
| `make ci` | natively on the host | ~20 s | fast pre-push feedback |
| `make ci-vm` | isolated ephemeral macOS VM (Tart) | minutes (cold) | full parity with the old `ci.yml` |

Both run the same gates: `swift build -c release`, `swift test`, `swiftformat
--lint`, and the detach-blocking lint (`scripts/lint-detach-blocking.py`).

## Why a VM (not a self-hosted runner)

pippin is a **public** repo. A listening self-hosted GitHub Actions runner on a
public repo lets a forked PR run arbitrary code on your hardware — GitHub warns
against it. `make ci-vm` sidesteps that entirely: it is **on-demand** (you run
it before pushing), runs in an **isolated ephemeral VM** (destroyed after each
run), and exposes **no listening runner**. It also burns zero GitHub-hosted
minutes.

`act` (the Linux-container equivalent) can't help here — it only runs Linux
runners, and pippin's CI is macOS/Xcode. `act` is used for the Linux-CI repos
(e.g. DeepTutor); see the global `act-local-ci-apple-silicon` memory.

## One-time setup

```bash
brew install cirruslabs/cli/tart hudochenkov/sshpass/sshpass
# Pull the base macOS+Xcode VM image (~90 GB, shared with SwiftClaw):
tart clone ghcr.io/cirruslabs/macos-sequoia-xcode:latest pippin-ci-base
```

Requirements: Apple Silicon (Tart uses Apple's Virtualization.framework),
macOS 13+, ~90 GB free for the image. Apple's EULA caps a host at **2 macOS VMs**
at once. Pin the image to an exact Xcode tag (e.g. `:16`) for reproducibility —
`:latest` drifts.

## How `scripts/ci-vm.sh` works

1. `tart clone pippin-ci-base pippin-ci-run` — fast copy-on-write clone.
2. `tart run --no-graphics` — boot headless; wait for IP + sshd.
3. `rsync` the working tree into the VM (excludes `.build`/`.git`/`.beads`).
4. Run the CI gates over ssh inside the VM.
5. A trap destroys the ephemeral VM on exit (pass or fail).

## Gotchas (already handled in the script)

1. **Homebrew not on the VM's PATH.** Non-interactive ssh skips `~/.zprofile`, so
   `PATH=/usr/bin:/bin:/usr/sbin:/sbin` — `brew`/`swiftformat` are missing. The
   script does `export PATH="/opt/homebrew/bin:$PATH"` in the remote command.
2. **SwiftFormat `--lint` path parsing.** SwiftFormat 0.61 mis-parses bare paths
   after `--lint` (`error: --lint argument does not expect a value`). Use trailing
   slashes: `swiftformat --lint pippin/ pippin-entry/ Tests/`.
3. **ssh `MaxAuthTries`.** sshpass + ssh offers every agent/identity key before
   the password and trips the VM sshd's limit ("Too many authentication
   failures"). The script forces password-only auth:
   `-o PreferredAuthentications=password -o PubkeyAuthentication=no -o IdentitiesOnly=yes`.

## SwiftClaw

SwiftClaw (the other Swift/macOS repo) has the same setup, sharing the
`pippin-ci-base` image; its `ci-vm` runs `swift build` + `swift test --parallel`
(no lint steps in its `ci.yml`). Note SwiftClaw is an **archived** GitHub repo —
to push changes, unarchive (`gh api -X PATCH repos/mattwag05/SwiftClaw -F
archived=false`), push, then re-archive.
