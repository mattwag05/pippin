# Mail Command Timeout Analysis & Fix Plan

## Test Date: 2026-05-19

## System: 5 Mail accounts (iCloud, Google, Gmail×2, Exchange, Yahoo), hundreds to thousands of messages per account

---

## 1. Pre-Fix Failure Summary (ARCHIVED)

### Hard Timeouts — FIXED

| Command | Original Cap | Post-Fix | Result |
|---------|-------------|-----------|--------|
| `pippin mail list` (no `--account`) | 10s → 60s | 60s | **PASS** (partial results) |
| `pippin mail search X --body --limit 5` | 30s → 95s | 95s | **PASS** (partial results) |
| `pippin mail activity` (no `--account`) | 50s → 75s | 115s | **PASS** (partial results) |

All previously-hard-crashing commands now return partial results gracefully via the JXA soft timeout (22s) and return before the ScriptRunner hard cap.

### Soft Timeouts (partial results — working as designed)

| Command | Soft Timeout | System |
|---------|-------------|--------|
| `list` (no preview) | 22s | Returns partial results |
| `list` (with --preview) | 22s | Returns partial results |
| `search` (no --body) | 22s | Returns partial results |
| `search` (with --body) | 22s | Returns partial results (95s hard cap now gives 73s headroom) |
| `activity` (no --preview) | 22s | Returns partial results |
| `activity` (with --preview) | 22s | Returns partial results |

## 2. Root Causes

### Cause 1: `listMessages` hard cap too short (10s)

**Original code (MailBridge.swift):**
```swift
let timeout = (preview ?? 0) > 0 ? 50 : 10
```

10s is fine for a single account with modest INBOX, but **cross-account** (no `--account` flag) means iterating 5 accounts, each with 1000-2700 messages, before even reaching the soft cap.

**Fix:** Made the hard cap scale based on whether it's cross-account.

### Cause 2: `searchMessages` hard cap too short (30s) when `--body`

**Original code:**
```swift
let json = try runScript(script, timeoutSeconds: 30)
```

30s is too tight when:
- No `--mailbox` filter → iterates ALL mailboxes per account (Google alone has 21)
- `--body` is true → forces `msg.content()` per matched message (IMAP body fetch)
- Soft timeout (22s) fires, but 8s for JSON.stringify on partial results is tight

**Fix:** Increased to 95s for cross-account --body, 65s for cross-account no --body.

### Cause 3: `listActivity` hard cap (50s) may be exceeded by MCP runChild cap (60s)

**Original code:**
```swift
let timeout = (preview ?? 0) > 0 ? 50 : 30
```

50s leaves only 10s margin before the 60s MCP runChild cap. When 5 accounts × multiple mailboxes are scanned (500 messages per mailbox), 50s is insufficient.

**Fix:** Increased to 75s for cross-account (115s with preview).

### Cause 4: No distinction between cross-account and single-account operations

All MailBridge methods shared a single `timeoutSeconds` value, but cross-account scans are ~5× slower.

**Fix:** Added `crossAccount` detection (auto-computed from `account == nil`) to scale timeouts appropriately.

## 3. Changes Made

### File: `pippin/MailBridge/MailBridge.swift`

#### `listMessages` — 3 changes
1. Added `crossAccount: Bool` computed from `(account == nil)`
2. Single-account stays 10s; cross-account bumped to 60s
3. With preview: single 50s, cross 100s

#### `listActivity` — 2 changes
1. Added `crossAccount: Bool` computed from `(account == nil)`
2. Single-account: 30s (unchanged); cross-account: 75s
3. With preview: single 50s (unchanged), cross 115s

#### `searchMessages` — 1 change
1. Added `crossAccount: Bool` computed from `(account == nil) && (mailbox == nil)`
2. Base: cross 50s, single 30s
3. With --body: cross 95s (50+45), single 45s (30+15)

## 4. Testing

- **Unit tests:** All 271 tests pass (no changes needed — script generation is agnostic to runtime)
- **Integration:** All 3 previously-failing commands now return partial results gracefully
- **Targeted commands** (with `--account`): Unchanged, still fast (<3s)

## 5. Remaining Considerations

1. **Search --body across all accounts** returns partial results at 22s but needs ~2min+ for full scan. Users should use `--account` or `--mailbox` for complete results.
2. **Activity without `--account`** has 115s timeout (with preview) which is generous but still may not cover all messages for very large accounts. The soft timeout at 22s gives users partial results quickly.
3. **MCP runChild cap** (60s) is a separate concern — operations with 60s+ ScriptRunner timeouts may be killed by MCP. This is acceptable for manual CLI use but worth monitoring for MCP callers.
