# AX Improvements Design
**Date:** 2026-03-12
**Project:** pippin CLI
**Status:** Approved

## Overview

Pippin is an AI-agent-first CLI. This spec covers a targeted AX (Agent Experience) pass on the `doctor` command and the `MailBridge` empty-output diagnosis. The goal: an agent calling `pippin doctor --format agent` gets compact JSON it can parse, and every actionable failure includes a `$ command` the agent can execute without human intervention. Permission-denial failures are clearly distinguished — no shell command is promised when the agent can't fix it unilaterally.

---

## Section 1: Doctor `--format agent` Wiring

### Problem
`DoctorCommand.run()` only checks `output.isJSON`. `--format agent` falls through to text output, making it unusable for agent consumers.

### Fix
Treat `isAgent` identically to `isJSON` in the doctor output branch:

```swift
if output.isJSON || output.isAgent {
    try printJSON(checks)
}
```

`DiagnosticCheck` is already `Codable` — no model changes. Agents using `--format agent` get the same `[DiagnosticCheck]` JSON array as `--format json`.

---

## Section 2: Remediation String Strategy

### Principle
Every `remediation` string falls into one of two categories:

1. **Agent-actionable** — the agent can fix it by running a command. Remediation includes a line starting with `$ ` containing the runnable command.
2. **Human-required** — only a human can resolve it (TCC/permission dialogs). Remediation contains prose only, no `$ ` line.

Agents use this convention as a signal: `remediation?.contains("$ ")` → can self-remediate; no `$ ` line → must surface to human.

### Format
```
→ <human-readable description>
  $ <runnable shell command>
```

### Mapping by check

| Check | Category | Runnable command |
|-------|----------|-----------------|
| Notes not running | Agent-actionable | `open -a Notes && sleep 2` |
| Mail not running | Agent-actionable | `open -a Mail && sleep 4` |
| Python3 missing | Agent-actionable | `brew install python3` |
| parakeet-mlx missing | Agent-actionable | `pip install parakeet-mlx` |
| mlx-audio missing | Agent-actionable | `pip install mlx-audio` |
| Calendar permission denied | Human-required | *(prose only)* |
| Reminders permission denied | Human-required | *(prose only)* |
| Contacts permission denied | Human-required | *(prose only)* |
| Mail TCC denied | Human-required | *(prose only)* |
| Notes TCC denied | Human-required | *(prose only)* |

---

## Section 3: New and Improved Checks

### 3a: Python3 Check (new)

**Location:** New `checkPython3()` private function in `DoctorCommand.swift`, inserted before `checkMLXAudio()` and `checkParakeetMLX()` in `runAllChecks()`.

**Implementation:** Run `python3 --version` via `Process`. Capture stdout/stderr with a 5-second timeout.

- Success: `.ok`, detail = version string (e.g. `"3.14.3"`)
- Missing: `.fail`, detail = `"not found"`, remediation includes `$ brew install python3`

**Rationale:** Both `mlx-audio` and `parakeet-mlx` are Python packages. Without Python3, both are impossible to install. Currently doctor reports them as `skip` silently even when Python3 is the root cause.

### 3b: Notes.app Pre-check (improved)

**Location:** `checkNotesAccess()` in `DoctorCommand.swift`.

**Current problem:** Calls `NotesBridge.listFolders()` unconditionally. When Notes.app is not running, this hits the 30-second JXA timeout, making `pippin doctor` hang for 30s.

**Fix:** Run `pgrep -x Notes` first (fast subprocess, <100ms). If exit code is non-zero (Notes not running), immediately return `.fail` without calling the bridge:

```
→ Notes.app is not running.
  $ open -a Notes && sleep 2
```

If Notes is running, proceed with the existing `listFolders()` call.

**Result:** Worst-case `pippin doctor` runtime drops from 30s to <1s when Notes is closed.

### 3c: MailBridge Empty-Output Diagnosis (improved)

**Location:** `checkMailAutomation()` in `DoctorCommand.swift`.

**Current problem:** Empty osascript output is attributed to TCC denial regardless of cause. When Mail.app isn't running, the error message is misleading.

**Fix:** Distinguish cases using the error detail string:

- Error detail contains `"not authorized"` / `"AppleEvent"` / `"1002"` / `"TCC"` → TCC denial (human-required, no `$ ` line)
- Error detail is empty or contains `"not running"` / no Mail-specific signal → Mail.app likely not running, remediation includes `$ open -a Mail && sleep 4`
- Other errors → generic "check Mail.app is installed and configured" (no `$ ` line, cause unknown)

---

## Section 4: Testing

### DoctorTests.swift (new file)

New test class covering:

1. **`--format agent` emits JSON** — `CLIIntegrationTests`: `pippin doctor --format agent` output is valid JSON and parses as an array with `name`/`status`/`detail` keys.

2. **Permission-denial checks have no `$` line** — For `Calendar`, `Reminders`, `Contacts`: when status is `.fail` due to denial, `remediation` does not contain `"$ "`.

3. **Python3 check returns non-nil description** — `checkPython3()` result has a non-empty `detail` string and `status` is either `.ok` or `.fail`.

4. **`$`-prefix on agent-actionable remediations** — For checks where the agent can act (Notes not running, Mail not running, Python3 missing), assert `remediation?.contains("$ ") == true`.

5. **MailBridge diagnosis strings** — `checkMailAutomation()` when given a TCC-error detail: remediation does not contain `"$ "`. When given empty/unknown detail: remediation contains `"$ open -a Mail"`.

### Existing tests unaffected
No changes to `DiagnosticCheck` model — existing JSON serialization tests continue to pass. `NotesBridgeError` and `MailBridgeError` model tests unaffected.

---

## Files Changed

| File | Change |
|------|--------|
| `pippin/Commands/DoctorCommand.swift` | Wire `isAgent`, rewrite all remediation strings, add `checkPython3()`, improve `checkNotesAccess()` and `checkMailAutomation()` |
| `Tests/PippinTests/DoctorTests.swift` | New test file |
| `Tests/PippinTests/CLIIntegrationTests.swift` | Add `pippin doctor --format agent` JSON smoke test |
