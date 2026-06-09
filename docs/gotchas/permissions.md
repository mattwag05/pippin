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
"first use" happens from a **background LaunchAgent** (e.g. [agent-runtime]/[agent]), there
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

- **Guarded**: `sign.sh` resolves the first "Developer ID Application" identity
  (override with `PIPPIN_SIGN_IDENTITY`). If none is present it warns and exits
  0, leaving the ad-hoc signature — so CI / the ci-vm / other machines still
  build. The formula also `File.exist?`-guards the call for tags predating the
  script.
- **Notarization is NOT needed for TCC.** It's a Gatekeeper/quarantine concern
  (binaries *downloaded* to other Macs). Set `PIPPIN_SIGN_HARDENED=1` to add
  `--options runtime --timestamp` only when you'll notarize for distribution.
- `pippin doctor` reports a **Code signing** row: `ok` for a stable identity,
  `skip` (with remediation) when ad-hoc/unsigned. Verify directly with
  `codesign -dvv "$(command -v pippin)"`.
- After (re)signing with a *new* identity the DR changes once → one re-grant via
  `pippin permissions`, then it persists.
- **Homebrew caveat (pippin-jt9):** `brew install/upgrade` builds in a sandbox
  with no access to the login keychain, so `sign.sh` finds no identity and falls
  back to ad-hoc — brew-built binaries are NOT Developer ID signed and their
  grants won't persist. In practice `~/.local/bin/pippin` (from `make install`,
  signed) shadows the brew copy on PATH, so the active/MCP binary is the signed
  one. If you rely on the brew copy directly, re-sign it:
  `bash scripts/sign.sh "$(brew --prefix)/bin/pippin"`.

### Apple Events responsible-process caveat

EventKit/Contacts/Full Disk Access key on pippin's own identity, so signing fixes
their persistence. **Apple Events** (Mail/Notes/Messages automation) key on the
*responsible process* — when the [agent-runtime] LaunchAgent spawns pippin, TCC may
attribute the grant to `agent-runtime`, not pippin. Signing pippin doesn't change the
agent's Automation identity; that's a property of the launching process.
