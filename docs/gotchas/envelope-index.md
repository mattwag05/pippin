# Mail Envelope Index (spike notes — pippin-60x)

Findings from the 2026-07-13 feasibility spike on reading
`~/Library/Mail/V<N>/MailData/Envelope Index` directly for `mail list`/`search`
metadata (full details in bead pippin-60x). Not yet implemented — this file
exists so the schema knowledge isn't lost.

- **WAL mode**: snapshot `Envelope Index` + `-wal` + `-shm` together before
  opening, or you read a stale checkpoint. Never open the live file read-write.
- **Core joins**: `messages` → `subjects` (subject text), `addresses` (sender;
  display name in `addresses.comment`), `mailboxes` (`url` =
  `imap://<ACCOUNT-UUID>/<path>`), `recipients` (to/cc via `type`).
  Dates are unix epoch (`date_received`, `date_sent`); `read`/`flagged`/
  `deleted`/`size` are columns on `messages`.
- **Version guard**: `properties` table (`version`=4, `minor_version`=90006 on
  macOS 27 beta / V10). Gate the fast path on known versions; fall back to JXA
  otherwise — the schema is Apple-private and can shift on any macOS update.
- **Perf**: subject+sender LIKE over 28K messages ≈ 31 ms (JXA equivalent:
  10–95 s budgets). Bodies are NOT in this DB — body fetch stays JXA +
  MailBodyCache.
- **Account names**: mailboxes are keyed by account UUID, not name. Map via one
  cached JXA `accounts()` call; `Accounts.plist` is not at `V10/MailData/` on
  this macOS.
- **FDA required** (same class as Messages `chat.db`); reads must silently fall
  back to JXA when unreadable. Never write to this DB.
