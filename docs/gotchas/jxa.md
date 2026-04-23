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

## JXA `att.save()` attachment gotchas (pippin-20v, 2026-04-20)

- Key is `{in: Path(dest)}`, **not** `{to: ...}` — JXA maps the AppleScript preposition (`save a in POSIX file path`). `{to:}` raises -10000 "Some data was the wrong type."
- Pre-touch the save target before `att.save()`. `Path(dest)` coercion doesn't create the file; saving into a nonexistent path errors -10000. Use `Application.currentApplication().doShellScript('/usr/bin/touch ' + shellQuote(dest))`.
- Prefer `msg.source()` over `msg.content()` to trigger IMAP fetch for attachments. `content()` only guarantees the text body — attachment binaries can stay as metadata stubs. Fall back to `content()` if `source()` throws.
- Wrap `att.mimeType()` in try/catch with a fallback (e.g. `'application/octet-stream'`). It raises "AppleEvent handler failed" (-10000) on some IMAP-backed attachments even when the attachment is fully usable.
- Gmail label'd compound ids (e.g. `||Important||`) may not resolve cleanly via `resolveMailbox`; when the message isn't in the resolved mailbox, fall back to `collectAllMailboxes` + `.messages.whose({id})()` across every mailbox (skip the already-tried one).

## Shared mail validation helpers (`MailCommand.swift`)

`validateEmailAddresses(_:field:)` and `validateAttachmentPaths(_:)` are file-private free functions used by Send/Reply/Forward — add new outgoing commands there, not inline.

## Reply/Forward quoting

Happens in Swift (`buildReplyQuote`, `buildForwardPrefix`) before the JXA send script runs — not inside osascript. Subject de-duplication (`Re:`/`Fwd:`) also in Swift via `buildReplySubject`/`buildForwardSubject`.

## New bridge pattern (Audio / Contacts / Browser / Notes)

JXA/subprocess bridges follow MailBridge's pattern — `nonisolated(unsafe)` vars + `DispatchGroup` concurrent pipe drain + `DispatchWorkItem` SIGTERM→SIGKILL timeout. Copy `runScript` from any existing bridge. JXA bridges are `enum` with `static` methods (not class); commands are `ParsableCommand` (not Async).

## EventKit Reminders bridge

`EKEventStore.fetchReminders(matching:)` uses a completion handler and `EKReminder` is not `Sendable` — cannot use `withCheckedThrowingContinuation` in Swift 6 strict mode. Use `DispatchSemaphore` + `nonisolated(unsafe) var` instead. See `RemindersBridge.fetchRemindersSync()`.

## JXA typed error trap

JXA script errors always arrive as `scriptFailed(String)` — never as a typed Swift case like `noteNotFound`. Don't add typed not-found cases to JXA bridge error enums; they'll be dead code.

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

Defaults: 22s soft cap leaves ~8s headroom under the 30s ScriptRunner timeout and well under the 60s MCP `runChild` failsafe. Don't raise above ~50s without lowering the runChild cap to match.
