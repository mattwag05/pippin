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
"first use" happens from a **background LaunchAgent** (e.g. Hermes/Talia), there
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

## Durability caveat: re-grant after upgrades

The binary is **unsigned** (no Developer ID). macOS TCC can reset a grant when
the binary content changes, so after `make install` / a Homebrew upgrade the user
may need to re-grant. This is why `pippin permissions` exists as a standalone,
re-runnable command — re-granting is one interactive command, not a re-onboard.
A stable code-signing identity would make grants survive rebuilds; we
deliberately did not take that on (no signing setup required).
