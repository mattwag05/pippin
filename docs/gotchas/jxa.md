# JXA / Apple-App Bridge Gotchas

Session learnings for Mail, Notes, Reminders, Calendar, and the Audio/Contacts/Browser/Notes bridge family. Load this when touching any `*Bridge/` directory.

## Compound message ID

Format: `account||mailbox||numericId`. Parsed in `MailBridge` and `CompoundId` helpers. `mailbox` reflects the *resolved* mailbox name (e.g. `[Gmail]/Trash`), not the user-supplied alias.

## JXA script builders (`MailBridge.swift`)

- Scripts are built as Swift string templates and run via `osascript`.
- Shared helpers: `jsFindMailboxByName()`, `jsResolveMailbox()`, `jsMailReadyPoll()`.
- `jsResolveMailbox()` resolves user aliases (`Trash`, `Junk`, `Sent`, `Drafts`) to the provider-correct mailbox via JXA special accessors (`acct.trash()`, etc.) — required because folder names vary by provider (Gmail, iCloud, Exchange).
- Tests assert on generated script *strings* — no osascript execution needed.

## IMAP body fetch

- Always call `msg.content()` before `msg.htmlContent()` — `content()` triggers the IMAP body download.
- Retry `htmlContent()` once after `delay(0.5)` if still null.
- **`msg.content()` is THE expensive operation** (~1–2s/message; the root cause of `mail list --preview` / `search --body` / `show` timeouts). `MailBridge.readMessage` is the single Swift seam for it and now reads/writes through `MailBodyCache` (`pippin/MailBridge/MailBodyCache.swift`, `~/.config/pippin/mail-cache.db`), keyed by the immutable compound id — repeat reads are ~75× faster and `mail index`'s per-message N+1 is amortized. Pass `cache: nil` to `readMessage` to force a live fetch (`mail show --no-cache`). The cache stores the whole `MailMessage`, so read/unread state is as-of cache time; `mail search` (and any non-preview `mail list`) deliberately bypass it and stay live.

### Bulk preview caching — `mail list --preview N` (pippin-8fq)

`mail list --preview N` now reads/writes through `MailBodyCache` too, via a **2-pass** design in `MailBridge.listMessagesCached` (NOT N single-message `readMessage` spawns — that would be slower than today on a cold cache):

1. **Metadata pass** — `listMessages(preview: nil)`: cheap enumeration, no `msg.content()`. Yields the **live** read/unread + metadata rows with compound ids.
2. **Batch body pass** — for rows whose body is already cached, derive the preview locally; for misses, fetch every body in ONE osascript via `buildBatchBodiesScript` (miss ids grouped by account+mailbox, each mailbox resolved once), then write them through the cache.

Key invariants:
- **Always-on**, no flag; `mail list --preview --no-cache` opts out (every row treated as a miss → live fetch, no cache I/O). MCP clients / morning-briefing benefit automatically since they shell out to the CLI.
- **Output borrows only `bodyPreview` from the cache** — read/unread and all other metadata stay live from pass 1 (the cached `read` snapshot is never surfaced). The truncation lives in Swift (`MailBridge.bodyPreview`, UTF-16 units to match JS `substring`), so cached-hit and fresh-miss previews are derived identically.
- **`timedOut` is OR'd across both passes** (`pass1.timedOut || fetchTimedOut`) — either cutting off = partial results.
- **Cache entries stay first-class**: `buildBatchBodiesScript` returns the full message shape (body + htmlBody + headers + attachments) like `buildReadScript` — *including* the `delay(0.5)` htmlContent retry — so a preview-warmed entry is byte-for-byte as complete as a `mail show` fetch and never poisons a later `mail show` (HTML mail returns null htmlBody on the first attempt right after `content()`, so the retry is load-bearing, not optional). The compounded per-message delay is bounded by `softTimeoutMs`; a large miss batch that overruns just leaves later ids for the next run.

**`mail search --body` is still deferred (pippin-1wy)** — its body match lives inside the JXA loop interleaved with dedup / offset / limit / newest-first ordering, so moving it to Swift risks changing search output; revisit once the batch path bakes in.

## JXA `att.save()` attachment gotchas (pippin-20v, 2026-04-20)

- Key is `{in: Path(dest)}`, **not** `{to: ...}` — JXA maps the AppleScript preposition (`save a in POSIX file path`). `{to:}` raises -10000 "Some data was the wrong type."
- Pre-touch the save target before `att.save()`. `Path(dest)` coercion doesn't create the file; saving into a nonexistent path errors -10000. Use `Application.currentApplication().doShellScript('/usr/bin/touch ' + shellQuote(dest))`.
- Prefer `msg.source()` over `msg.content()` to trigger IMAP fetch for attachments. `content()` only guarantees the text body — attachment binaries can stay as metadata stubs. Fall back to `content()` if `source()` throws.
- Wrap `att.mimeType()` in try/catch with a fallback (e.g. `'application/octet-stream'`). It raises "AppleEvent handler failed" (-10000) on some IMAP-backed attachments even when the attachment is fully usable.
- Gmail label'd compound ids (e.g. `||Important||`) may not resolve cleanly via `resolveMailbox`; when the message isn't in the resolved mailbox, fall back to `collectAllMailboxes` + `.messages.whose({id})()` across every mailbox (skip the already-tried one).
- `mb.messages.whose({id: x})()` accepts `x` as a **string** as well as a number — JXA coerces it to the numeric id match (confirmed via `buildBatchBodiesScript`, which injects ids as JSON strings). So a batch of ids serialized through `JSONEncoder` works without converting them back to `Int`.

## Per-attachment try/catch required in *read* scripts too

The same `att.mimeType()` (and `att.name()`) flakiness that bit `buildSaveAttachmentsScript` also bites any script that just enumerates attachment metadata. A single outer try/catch around the loop swallows the *entire* iteration when one field accessor throws, returning `attachments: []` even though `hasAttachment: true`. Mirror the save-script pattern: one try/catch around `msg.mailAttachments()` to populate `atts`, then per-attachment try/catch around each of `att.name()`, `att.mimeType()`, `att.fileSize()` / `downloadedSize()` with sensible fallbacks (`'attachment_' + i`, `'application/octet-stream'`, `0`). Regression test: `JXAScriptBuilderTests.testReadScriptHandlesAttachmentMimeTypeFailure`.

## Shared mail validation helpers (`MailCommand.swift`)

`validateEmailAddresses(_:field:)` and `validateAttachmentPaths(_:)` are file-private free functions used by Send/Reply/Forward — add new outgoing commands there, not inline.

## Reply/Forward quoting

Happens in Swift (`buildReplyQuote`, `buildForwardPrefix`) before the JXA send script runs — not inside osascript. Subject de-duplication (`Re:`/`Fwd:`) also in Swift via `buildReplySubject`/`buildForwardSubject`.

## New bridge pattern (Audio / Contacts / Browser / Notes)

JXA/subprocess bridges follow MailBridge's pattern — `nonisolated(unsafe)` vars + `DispatchGroup` concurrent pipe drain + `DispatchWorkItem` SIGTERM→SIGKILL timeout. Copy `runScript` from any existing bridge. JXA bridges are `enum` with `static` methods (not class); commands are `ParsableCommand` (not Async).

## EventKit Reminders bridge

`EKEventStore.fetchReminders(matching:)` uses a completion handler and `EKReminder` is not `Sendable` — cannot use `withCheckedThrowingContinuation` in Swift 6 strict mode. Use `DispatchSemaphore` + `nonisolated(unsafe) var` instead. See `RemindersBridge.fetchRemindersSync()`.

## Verifying privacy-gated commands — TCC blocks the freshly-built binary

Running `.build/release/pippin calendar create` / `reminders` / `contacts` / `memos transcribe` from a test shell often fails with `access_denied` (exit 4) even when the code is correct: macOS TCC attaches the Calendars/Contacts/Reminders/Full-Disk grant to the *launching app* (Terminal/iTerm/the test runner), not the unsigned freshly-built binary. That's an environment limit, not your change.

To verify parse/validation logic without the grant, branch on the exit code: **exit 4** = input parsed + validated, reached the bridge (only TCC stopped it); **exit 2** = rejected at validation. Lock the actual semantics (wall-clock time, etc.) in unit tests against the pure helper, and use the real binary only to confirm "reached the bridge, didn't reject."

## JXA typed error trap

JXA script errors arrive from `ScriptRunner` as a generic non-zero-exit failure, so a typed case like `noteNotFound` only exists if you *map* it in. The pattern (see `NotesBridge.mapScriptFailure`, `MailBridgeRunner.mapScriptFailure`): have the JXA script emit a sentinel (`NOTESBRIDGE_ERR_NOT_FOUND: <id>`, or rely on Mail's native `Message not found (-2700)`), then at the single seam where `runScript` turns a ScriptRunner failure into a `*BridgeError`, detect the sentinel/signature and throw the typed `.xNotFound(id)` case (agent code `x_not_found` → exit 3 automatically via `PippinExitCode`). Do this in ONE seam per bridge, not per call site. Without the mapping seam, every failure collapses to `script_failed`/exit 5 — which is what shipped the not-found-classification bug the E2E audit caught (2026-07-15).

## Notes IDs prefix trap

Notes IDs start with `x-coredata://` — `String(id.prefix(8))` always yields `"x-coreda"`. Use `id.components(separatedBy: "/").last` for display.

## Memos progress output in agent mode

Progress `print()` calls guarded by `!outputOptions.isJSON` also need `&& !outputOptions.isAgent` — otherwise stdout is corrupted in agent mode.

## `CalendarBridge` is `@unchecked Sendable` — parallelize reads

Multiple `bridge.listEvents(from:to:)` calls in the same command can run concurrently via `async let` (see `DigestCommand.swift` for today/upcoming pattern). Same applies anywhere you need a day-scoped + range-scoped read together.

## Soft timeout inside long-running JXA loops (mail + notes search/list/folders)

Any JXA loop that walks an unbounded collection (mailboxes, messages, notes, folders) must self-bound — the MCP `runChild` 60s hard cap will SIGKILL the child otherwise, leaving the user with no partial results.

Pattern (used by `MailBridge.buildSearchScript`, `NotesBridge.buildSearchScript`/`buildListScript`/`buildListFoldersScript`):
1. Take `softTimeoutMs: Int = 22000` builder param. Clamp to [1000, 300_000].
2. Inject `var _start = Date.now(); var _meta = { timedOut: false };` at the top of the script.
3. At the top of every iteration that does Apple-side I/O (per-mailbox, per-message, per-note, per-folder):
   ```js
   if (Date.now() - _start > softTimeoutMs) { _meta.timedOut = true; break; }
   ```
4. Wrap output as `JSON.stringify({results: results, meta: _meta})`.

In Swift the bridge returns `Outcome<T> { results, timedOut }` (mail uses a domain-specific `SearchOutcome { messages, timedOut }`; notes uses a generic `Outcome<T>`). Commands surface the flag via `output.emit(payload, timedOut:, timedOutHint:) { renderText() }` — that helper writes a stderr `Warning:`, threads `[hint]` into the agent envelope's `warnings: [...]`, and appends a `(partial results — ...)` trailer in text mode.

Defaults: the 22s soft cap (`SoftTimeout.defaultMs`) fires well before the caller-supplied ScriptRunner hard cap and the 60s MCP `runChild` failsafe (under MCP, `MailBridge.clampHardTimeout` pins hard caps to 55s). ScriptRunner's `timeoutSeconds` is caller-supplied, not a fixed constant — see `MailBridge.swift` for the per-method values. Don't raise a hard cap above the runChild failsafe without lowering it to match.

## Bulk property access — soft timeout alone doesn't save you (pippin-mo7)

A soft timeout self-bounds a JXA loop, but if the per-iteration body does **one Apple Event per item** (`notes[j].modificationDate()`, `msgs[j].dateSent()`), a large collection can spend the *entire* budget before the loop emits anything — the caller gets `timedOut=true` with **empty** results, which reads as "zero items" not "partial". `notes list`/`search` returned nothing on big vaults for exactly this reason.

Fix: fetch the property for the whole collection in **one** Apple Event via the bulk getter on the *plural specifier* (not the materialized array): `_notesRef.modificationDate()` returns a parallel array of all dates. Keep the specifier (`_notesRef = app.notes`), materialize elements once (`notes = _notesRef()`), bulk-fetch (`_mods = _notesRef.modificationDate()`), then the bounded loop is **pure JS** (zero Apple Events) and never starves. See `NotesBridge.jsResolveNotesAndBulkMods`. Per-note `.body()`/`.plaintext()` stay per-item but only for the returned page.

## Messages bodies live in `attributedBody` (typedstream), not `text` (pippin-cc1)

`MessagesBridge`/`MessagesDatabase` reads `~/Library/Messages/chat.db` via GRDB (not
JXA), but it shares the "the obvious column is empty" trap. On modern macOS the
`message.text` column is **NULL/empty** for almost all messages; the real body is in
`message.attributedBody` as a **typedstream** (the old `NSArchiver` format, header
`\x04\x0bstreamtyped…`) — *not* an `NSKeyedArchiver` plist, so `NSKeyedUnarchiver`
**cannot** read it. The symmetric decoder is the deprecated `NSUnarchiver`, wrapped in
an ObjC `@try/@catch` shim (`CTypedStreamDecode` / `PippinDecodeAttributedBody`) because
it raises an uncatchable-from-Swift `NSException` on foreign/truncated blobs.
`MessagesDatabase.resolveBody(text:attributedBody:)` prefers a non-empty `text`, else
decodes the blob; strip the U+FFFC object-replacement marker (inline attachments) so
attachment-only messages read as "no text". SQLite `LIKE` does **not** match into BLOB
columns, so `search` can't prefilter on the blob — it decode-scans a bounded recent
window in Swift (`searchAttributedScanCap`). Reading chat.db needs Full Disk Access for
the *launching* binary's path (see permissions.md / the disclaim model).
