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
Use separate branches for agent and JSON — agent gets compact output via `printAgentJSON`, JSON gets pretty-printed via `printJSON`:

```swift
if output.isAgent {
    try printAgentJSON(checks)
} else if output.isJSON {
    try printJSON(checks)
} else {
    // existing text output loop
}
```

`DiagnosticCheck` is already `Codable` — no model changes. No version bump required for this patch.

---

## Section 2: Remediation String Strategy

### Principle
Every `remediation` string falls into one of two categories:

1. **Agent-actionable** — the agent can fix it by running a command. Remediation includes a line containing `$ ` (dollar-space) followed by the runnable command.
2. **Human-required** — only a human can resolve it (TCC/permission dialogs). Remediation contains prose only, no `$ ` line.

Agents detect self-remediable failures with: `remediation?.contains("$ ") == true`.

Note: the `$ ` prefix may be preceded by whitespace in the string (e.g. `"  $ open -a Notes && sleep 2"`). Agents match using `contains("$ ")` — the space after `$` is the unambiguous sentinel, not column position.

### Concrete example: agent-actionable remediation as it appears in JSON

```json
{
  "name": "Notes automation",
  "status": "fail",
  "detail": "Notes.app is not running",
  "remediation": "→ Notes.app is not running.\n  $ open -a Notes && sleep 2"
}
```

### Concrete example: human-required remediation

```json
{
  "name": "Notes automation",
  "status": "fail",
  "detail": "permission denied",
  "remediation": "→ Open System Settings > Privacy & Security > Automation\n  Grant Terminal.app (or pippin binary) access to Notes.\n  Then run: pippin notes folders"
}
```

### Mapping: all checks in `runAllChecks()`

| Check | Change | Category | Runnable command |
|-------|--------|----------|-----------------|
| macOS version | No change | Human-required (update macOS) | *(no `$` line)* |
| Mail automation — not running | Add `$ ` line | Agent-actionable | `open -a Mail && sleep 4` |
| Mail automation — TCC denied | No change | Human-required | *(no `$` line)* |
| Mail automation — other error | No change | Human-required (cause unknown) | *(no `$` line)* |
| Voice Memos — database not found | Add `$ ` line | Agent-actionable | `open -a "Voice Memos" && sleep 3` |
| Voice Memos — unsupported schema | No change | Human-required (pippin needs update) | *(no `$` line)* |
| Voice Memos — permission denied | No change | Human-required (Full Disk Access) | *(no `$` line)* |
| Calendar access — denied | No change | Human-required | *(no `$` line)* |
| Calendar access — not determined | No change | `.skip`, no remediation | — |
| Reminders access — denied | No change | Human-required | *(no `$` line)* |
| Reminders access — not determined | No change | `.skip`, no remediation | — |
| Contacts access — denied | No change | Human-required | *(no `$` line)* |
| Contacts access — not determined | No change | `.skip`, no remediation | — |
| Notes automation — not running | Rewrite | Agent-actionable | `open -a Notes && sleep 2` |
| Notes automation — TCC denied | No change | Human-required | *(no `$` line)* |
| Python3 (new) — missing | New check | Agent-actionable | `brew install python3` |
| parakeet-mlx — not found | Add `$ ` line | Agent-actionable (`.skip`) | `pip install parakeet-mlx` |
| Speech Recognition | No change | Always `.skip`, no remediation | — |
| mlx-audio — not found | Add `$ ` line | Agent-actionable (`.skip`) | `pip install mlx-audio` |
| Node.js — not found | Add `$ ` line | Agent-actionable (`.skip`) | `brew install node` |
| Playwright — not found | Add `$ ` line | Agent-actionable (`.skip`) | `npx playwright install webkit` |
| pippin version | No change | Always `.ok`, no remediation | — |

**Note on `.skip` with `$ ` lines:** Optional dependencies (`parakeet-mlx`, `mlx-audio`, `Node.js`, `Playwright`) remain `.skip` — they are not required for pippin to function. An agent treating `.skip` as "not blocking but agent can install" is correct. The `$ ` convention applies to any check where the agent can take action, regardless of `.ok`/`.fail`/`.skip` status.

---

## Section 3: New and Improved Checks

### 3a: Python3 Check (new)

**Location:** New `checkPython3()` internal function in `DoctorCommand.swift`, inserted between `checkNotesAccess()` and `checkParakeetMLX()` in `runAllChecks()`.

**Implementation:** Run `python3 --version` via `Process` with a 5-second timeout. Capture combined stdout+stderr (python3 writes version to stderr on some versions).

- Success (exit 0): `.ok`, detail = version string parsed from output (e.g. `"3.14.3"`)
- Missing or timeout (non-zero or no output): `.fail`, detail = `"not found"`, remediation includes `$ brew install python3`

**Testable seam:** Extract a required `internal func classifyPython3Output(exitCode: Int32, output: String) -> DiagnosticCheck` helper (parallel to `classifyMailError`). `checkPython3()` passes the process exit code and combined stdout+stderr output to it. This makes both the `.ok` and `.fail` branches testable with synthetic inputs without running a real subprocess.

**Rationale:** Both `mlx-audio` and `parakeet-mlx` are Python packages. Without Python3, both are impossible to install — doctor currently reports them as `.skip` without explaining the root cause.

### 3b: Notes.app Pre-check (improved)

**Location:** `checkNotesAccess()` in `DoctorCommand.swift`.

**Current problem:** Calls `NotesBridge.listFolders()` unconditionally. When Notes.app is not running, this hits the 30-second JXA timeout, hanging `pippin doctor` for 30s.

**Fix:** Run `pgrep -x Notes` first (fast subprocess, <100ms). Evaluation:

- `pgrep` exits non-zero → Notes not running → immediately return `.fail`:
  ```
  → Notes.app is not running.
    $ open -a Notes && sleep 2
  ```
- `pgrep` binary itself fails to execute → fall through to bridge call (treat as "status unknown")
- `pgrep` exits 0 → Notes is running → proceed with existing `listFolders()` call

**Known edge case (acceptable):** `pgrep -x Notes` returns 0 during a slow Notes.app launch. The subsequent `listFolders()` may still time out. If it does, the existing timeout error bubbles up as a generic failure. This is acceptable — it only occurs in the few-second window after `open -a Notes`, which is an unusual state for doctor to run in.

**Implementation note:** The existing `.timeout` catch arm in `checkNotesAccess()` should be retained as a fallback (covers the pgrep-passes-but-bridge-times-out race). Its remediation string must be updated to include the `$ open -a Notes && sleep 2` line so it is consistent with the agent-actionable convention.

**Result:** Worst-case `pippin doctor` runtime drops from 30s to <1s when Notes is closed.

### 3c: MailBridge Empty-Output Diagnosis (improved)

**Location:** `checkMailAutomation()` in `DoctorCommand.swift`.

**Current problem:** Empty osascript output is always attributed to TCC denial. When Mail.app isn't running, the error message misleads the agent.

**Success path (unchanged):** Successful `MailBridge.listAccounts()` → `.ok`, `detail = "granted"`.

**Failure path — branch priority order (TCC first, then running check):**

1. **TCC/permission branch (highest priority):** `detail.contains("not authorized") || detail.contains("AppleEvent") || detail.contains("1002") || detail.contains("TCC")` → permission denied. Human-required, no `$ ` line. If a string matches both this branch and the next, this branch wins.

2. **Not running branch:** `detail.isEmpty` → Mail.app likely not running. Agent-actionable:
   ```
   → Mail.app may not be running.
     $ open -a Mail && sleep 4
   ```

3. **Other/unknown branch (lowest priority):** All other errors → pass raw `error.localizedDescription` as `detail`, no `$ ` line, remediation: `"→ Ensure Mail.app is installed and has at least one account configured.\n  Then run: pippin mail list"`.

**Testable seam:** Extract an `internal func classifyMailError(_ detail: String) -> DiagnosticCheck` helper containing the three branches. The function returns a full `DiagnosticCheck` with `name` hardcoded to `"Mail automation"` internally — it is scoped to this one check. `checkMailAutomation()` calls it with the error's `localizedDescription` (or `""` on empty output). Tests call it directly with synthetic strings.

---

## Section 4: Testing

### Internal testable helpers

To enable testing without live system calls, extract these `internal` (not `private`) helpers:

- `classifyMailError(_ detail: String) -> DiagnosticCheck` — the three-branch logic from Section 3c. Returns a full `DiagnosticCheck` with `name` hardcoded to `"Mail automation"`.
- `classifyPython3Output(exitCode: Int32, output: String) -> DiagnosticCheck` — maps process result to a `DiagnosticCheck`. Returns a full `DiagnosticCheck` with `name` hardcoded to `"Python3"`. Enables testing both `.ok` and `.fail` branches with synthetic inputs.

### DoctorTests.swift (new file)

1. **`--format agent` emits compact JSON** — `CLIIntegrationTests`: `pippin doctor --format agent` stdout is valid JSON, parses as `[[String: Any]]`, and each element contains keys `"name"`, `"status"`, `"detail"` (and optionally `"remediation"`).

2. **Permission-denial remediations have no `$ ` line** — For `Calendar`, `Reminders`, `Contacts`: when `authorizationStatus` returns `.denied`, the returned `DiagnosticCheck.remediation` does not contain `"$ "`. These call the private check functions directly via `@testable import` (they read live TCC state; if granted, the check returns `.ok` and the assertion is skipped with `guard`).

3. **`classifyPython3Output` branch isolation** — Call the helper directly with synthetic inputs:
   - `classifyPython3Output(exitCode: 0, output: "Python 3.14.3")` → `status == .ok`, `detail` starts with `"3."` or contains `"3.14"`
   - `classifyPython3Output(exitCode: 1, output: "")` → `status == .fail`, `remediation?.contains("$ brew install python3") == true`
   - `checkPython3()` live call on CI (Python3 present): assert `status == .ok`

4. **`classifyMailError` branch isolation:**
   - `classifyMailError("not authorized to send Apple events")` → `remediation` does not contain `"$ "`
   - `classifyMailError("")` → `remediation?.contains("$ open -a Mail") == true`
   - `classifyMailError("some unrecognized error")` → `remediation` does not contain `"$ "`, `detail` contains the raw string

5. **`$`-prefix presence on agent-actionable `.skip` remediations** — For `checkParakeetMLX()`, `checkMLXAudio()`, `checkNodeJS()`, `checkPlaywright()`: when the check returns `.skip` with a remediation, assert `remediation?.contains("$ ") == true`.

6. **Notes pgrep pre-check timing** — Call `checkNotesAccess()` in a context where Notes.app is not running. Assert completion within 2 seconds (vs. the 30s timeout). Annotate as a live-state test that only runs when Notes.app is confirmed not running; if Notes is running, skip.

### `CLIIntegrationTests.swift`
Add smoke test: `pippin doctor --format agent` exits with code 0 or 1 (both valid — some checks may fail), stdout is non-empty valid JSON array. No version bump for this patch — `"0.11"` assertion unchanged.

---

## Files Changed

| File | Change |
|------|--------|
| `pippin/Commands/DoctorCommand.swift` | Wire `isAgent` (separate branch from `isJSON`), rewrite remediation strings per table, add `checkPython3()`, improve `checkNotesAccess()` (pgrep pre-check), improve `checkMailAutomation()` (branch priority), extract `classifyMailError()` as `internal` |
| `Tests/PippinTests/DoctorTests.swift` | New test file covering items 2–6 above |
| `Tests/PippinTests/CLIIntegrationTests.swift` | Add `--format agent` JSON smoke test |
