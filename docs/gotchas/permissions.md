# Gotchas — macOS permissions (TCC)

Hard-won notes on how pippin obtains and keeps macOS privacy permissions. Load
when touching `pippin/Permissions/`, the `init`/`permissions`/`doctor` commands,
or any bridge's `ensureAccess()`.

## The mechanisms differ per integration

| Integration | Mechanism | System Settings pane | Promptable by pippin? |
|-------------|-----------|----------------------|-----------------------|
| Reminders | EventKit `.reminder` | Reminders | Yes — `requestFullAccessToReminders()` |
| Calendar | EventKit `.event` | Calendars | Yes — `requestFullAccessToEvents()` |
| Contacts | Contacts framework | Contacts | Yes — `CNContactStore.requestAccess` |
| Mail | Apple Events (Automation) | Automation | Yes — fires on first script run |
| Notes | Apple Events (Automation) | Automation | Yes — fires on first script run |
| Voice Memos | Full Disk Access | Full Disk Access | **No** — no request API |
| Messages | Full Disk Access | Full Disk Access | **No** — no request API |

`PermissionMechanism.isPromptable` encodes this. Full Disk Access has **no
prompt** — `pippin permissions` cannot grant it; the user must toggle it
manually and relaunch the launching app.

## The "first use" trap (why priming exists)

A `.notDetermined` EventKit/Contacts permission only prompts on first access. If
"first use" happens from a **background LaunchAgent** (e.g. an agent gateway), there
is no GUI session to present the dialog, so the request silently returns denied —
the bug behind pippin-ci2/pippin-k8g. Fix: resolve every prompt once,
interactively, via `pippin permissions` (or `pippin init`). `PermissionPriming.
shouldPrime` gates this to interactive TTY / not-MCP / not-structured-output —
**never** trigger a prompt nothing can answer.

## Embedded Info.plist is load-bearing

`requestFullAccess*` requires usage-description strings
(`NSRemindersFullAccessUsageDescription`, etc.). A bare SPM executable has none,
so the request is unreliable (or crashes) outside an interactive terminal. We
embed `pippin-entry/Info.plist` into the binary's `__TEXT,__info_plist` section
via linker `-sectcreate` flags in `Package.swift` (`.unsafeFlags` — fine because
pippin is never a versioned library dependency). Verify after a build:

```bash
otool -s __TEXT __info_plist "$(swift build -c release --show-bin-path)/pippin"
```

## Persistence: stable code signing (pippin-xzu)

SwiftPM **ad-hoc / linker-signs** by default (`flags=…(adhoc,linker-signed)`),
so the code identity macOS TCC keys grants on IS the CDHash — a content hash
that changes on every build. TCC then treats each build as a new app and orphans
the prior grant (every `make install` / `brew upgrade` re-prompts), and the two
install paths (`~/.local/bin/pippin`, `/opt/homebrew/bin/pippin`) get separate
grants because their hashes differ.

Fix: sign with a **stable identity** (a Developer ID Application cert) and a
fixed `--identifier com.mattwag05.pippin`. That gives a content-independent
Designated Requirement, so a grant given once survives rebuilds and is shared
across both install paths. `scripts/sign.sh` does this; `make install` /
`make release` and the Homebrew formula call it.

- **Guarded**: `sign.sh` resolves the first "Developer ID Application" identity,
  falling back to the first "Apple Development" identity (override either with
  `PIPPIN_SIGN_IDENTITY`). If none is present it warns and exits 0, leaving the
  ad-hoc signature — so CI / the ci-vm / other machines still build. The formula
  also `File.exist?`-guards the call for tags predating the script.
- **Apple Development is a usable fallback for LOCAL TCC persistence** (pippin-ink):
  on a machine with only the everyday Xcode "Apple Development" cert (no paid
  Developer ID), `make install` still yields a content-independent DR
  (`identifier "com.mattwag05.pippin" and … certificate leaf[subject.CN] =
  "Apple Development: …"`), so grants survive rebuilds. Caveat vs Developer ID:
  the DR pins to the **leaf cert**, so grants reset when that cert is renewed/
  expires (~1yr); Developer ID's DR is team-based and survives renewal. Apple
  Development also can't be notarized for distribution — local dev loop only.
- **Notarization is NOT needed for TCC.** It's a Gatekeeper/quarantine concern
  (binaries *downloaded* to other Macs). Set `PIPPIN_SIGN_HARDENED=1` to add
  `--options runtime --timestamp` only when you'll notarize for distribution.
- `pippin doctor` reports a **Code signing** row: `ok` for a stable identity,
  `skip` (with remediation) when ad-hoc/unsigned. Verify directly with
  `codesign -dvv "$(command -v pippin)"`.
- After (re)signing with a *new* identity the DR changes once → one re-grant via
  `pippin permissions`, then it persists.
- **Homebrew (pippin-jt9):** `brew install/upgrade` builds in a sandbox with no
  login-keychain access, so it *cannot* Developer-ID-sign a from-source build.
  Resolved by having the formula install the **pre-signed release tarball** (the
  `make tarball` asset, signed on a real machine at release time) for tagged
  versions — so `brew install pippin` lands a Developer-ID-signed binary with
  persistent grants. Only `brew install --HEAD` builds from source and is
  ad-hoc. **Release implication:** the asset must be built+signed+uploaded to the
  GitHub release *before* the formula is pointed at it (url + sha256). See the
  release skill.

### The responsible-process caveat applies to EventKit/Contacts too (pippin-0vr)

**TCC associates consent with the *responsible (launching) process*, not pippin's
own binary** — for EventKit (Reminders/Calendar), Contacts, Full Disk Access, AND
Apple Events. So a grant approved while pippin runs under **Terminal** does **not**
transfer to pippin spawned by a **background agent / MCP gateway** (e.g. an agent gateway
whose responsible process is its own LaunchAgent) — that's a different
launcher, so the call is denied. Observed 2026-06-08: `pippin permissions --status`
on the Developer-ID-signed binary reports Reminders `not_determined` from a
non-Terminal launcher while Terminal has a working grant.

What signing *does* buy: a stable code identity so TCC doesn't re-prompt when the
binary's hash changes on rebuild/upgrade **under the same launcher** (and so the
two install paths share a grant). It does **not** make one launcher's grant apply
to another. (Earlier wording here claimed EventKit keys on pippin's own identity —
that was wrong; pippin's user-facing remediation, which says the grant attaches to
the launching app, is the accurate description.)

**Resolution (pippin-0vr): pippin disclaims responsibility for itself.** As of
v0.31.0 pippin re-execs itself at startup with
`responsibility_spawnattrs_setdisclaim` (a private SPI resolved via `dlsym`;
`CDisclaimSpawn` C target + `DisclaimRespawn` + the `becomeOwnResponsibleProcess()`
call in `@main`). The re-exec'd process is its own responsible process, so TCC keys
consent on pippin's own code identity (`com.mattwag05.pippin`) regardless of
launcher. **Grant pippin once and it works under Terminal, Codex, an agent
gateway, launchd — everywhere.** Notes:

- One disclaim per process tree: the child sets `PIPPIN_DISCLAIMED=1`, so the MCP
  server's per-tool-call children inherit pippin's responsibility (no per-call
  re-exec). Opt out with `PIPPIN_NO_DISCLAIM=1`.
- The re-exec inherits argv/stdio/environ and forwards termination signals, so it
  is transparent to terminals and the MCP JSON-RPC pipe. ~one extra process
  startup per *direct* CLI invocation (not per MCP tool call).
- **One-time migration cost:** because consent now attaches to pippin's identity
  (not the launcher's), every permission must be re-granted once after upgrading —
  run `pippin permissions` from a terminal and approve. Until then, EventKit
  commands fail fast (see below) and Mail/Notes **Automation** calls block to their
  soft-timeout when un-granted in a non-interactive context (pippin-qjf tracks a
  fast-fail for that; interactive Terminal use self-heals because the automation
  prompt appears on first call).
- Bridges only block on `requestFullAccess*` when a user can answer the dialog
  (`PermissionPriming.canRequestAccess()` = interactive TTY && not MCP); otherwise
  they throw `accessDenied` immediately instead of hanging on an un-showable prompt
  — now the common path, since a disclaimed pippin sees its own `.notDetermined`
  status under background launchers.
