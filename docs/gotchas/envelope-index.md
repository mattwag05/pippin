# Mail Envelope Index (pippin-60x — IMPLEMENTED 2026-07-15)

The fast path lives in `pippin/MailBridge/MailEnvelopeIndex.swift`, hooked at
the top of `MailBridge.listMessages`/`searchMessages`/`listActivity` (metadata
only; any failure falls back to JXA silently). Kill switches:
`PIPPIN_MAIL_FASTPATH=0` env (per-invocation, used by the e2e parity check) >
`mail.fastPath: false` in `~/.config/pippin/config.json` > default ON.
`doctor --latency` passes `fastPath: false` so its probes still measure the
real JXA/Mail.app path. Measured live: cross-account list 360 ms (JXA budget
60 s), warm activity 90 ms, search 74 ms — and a forced-JXA comparison search
soft-timed-out at 22 s with 0 results for a query the index answered in 74 ms.

- **`msg.id()` == Envelope Index ROWID.** Mail's AppleScript message id IS the
  index ROWID (verified live both directions 2026-07-15), so fast-path compound
  ids (`account||mailboxLeaf||ROWID`) are byte-compatible with JXA ids —
  `show`/`mark`/`move` and MailBodyCache keys work unchanged across paths.
  Caveat: an index REBUILD (observed across a June→July macOS beta update)
  renumbers BOTH spaces together; ids cached across a rebuild (e.g. old
  MailBodyCache compound ids) go stale on both paths equally. Fallback key if
  the invariant ever breaks: `message_global_data.message_id_header` (RFC
  Message-ID, stored WITH `<>` brackets, 99.8% populated) ↔ JXA
  `msg.messageId()` (returns it WITHOUT brackets; `whose({messageId: bare})`
  resolves it).
- **`acct.id()` == the account UUID** prefixing every `mailboxes.url`
  (`scheme://UUID/percent-encoded/path`; schemes: imap, ews, local). Name→UUID
  map comes from one JXA accounts call cached at
  `~/.config/pippin/mail-accounts.json` (`MailAccountsCache`) — refreshed only
  on empty cache, `--account` name miss, or TTL-limited when the index
  references an unknown UUID. `local://` ("On My Mac") is invisible to JXA
  `accounts()` and is excluded on both paths.
- **WAL snapshot is mandatory for freshness**: an `immutable=1` open of the
  live file silently misses everything still in the WAL (verified: a
  minutes-old message was absent). `MailEnvelopeIndex.init(dbPath:)` copies
  db + `-wal` + `-shm` to a temp dir and opens the COPY (writable config — a
  readonly open can refuse WAL recovery; it's our copy). Freshness observed
  live: three separate inbound arrivals were visible through the fast path
  within ~2 minutes of delivery (Mail writes the index continuously while
  running). `read`-flag state lags only by Mail's own sync. Never open Mail's
  live files with a writable handle; never write SQL to any of this.
- **Version guard**: `properties` table `version`=4 (`minor_version`=90006 on
  macOS 27 beta / V10) — `MailEnvelopeIndex.knownVersions` gates the fast path;
  unknown version → JXA fallback + a `doctor` `.skip` notice. The V-number dir
  (`~/Library/Mail/V<N>`) is scanned, not hardcoded.
- **Mailbox names**: no type flags in the DB — special mailboxes resolve by
  decoded URL leaf against the same alias groups as JXA `resolveMailbox`
  (sent/{Sent, Sent Messages, Sent Mail, Sent Items}, trash/{…Deleted Items…},
  junk, drafts, inbox). Localized names may not match → `mailboxUnresolved` →
  JXA fallback (its `acct.sent()` accessors are locale-proof).
- **Date filters are UTC-midnight**: JXA's `new Date('YYYY-MM-DD')` parses as
  UTC. The fast path mirrors that (`parseFilterDateUTC`), NOT
  `MailBridge.parseFilterDate` (local, display-only) — using local midnight
  drops rows near day boundaries that JXA keeps.
- **Filter dates on `COALESCE(NULLIF(date_sent,0), NULLIF(date_received,0))`** —
  Apple leaves either column NULL or 0. GRDB NULL trap applies to every column
  (`row["x"] as T?` — see swift.md).
- **Dedup mirrors JXA**: Gmail lists one message in both INBOX and
  `[Gmail]/All Mail` — key on `message_id_header`, fallback
  subject+sender+date; offset applies after dedup (search).
- **Bodies are NOT in this DB** — `show`, previews-on-cache-miss, and all
  writes stay JXA. Fast-path activity/list previews reuse
  `assemblePreviews` + `buildBatchBodiesScript` + MailBodyCache (ids match, so
  cache keys line up).
- **FDA required** (same class as Messages `chat.db`): the snapshot copy fails
  with EPERM → `accessDenied` → silent JXA fallback. `doctor` reports fast-path
  availability as an informational check (`.skip`, never `.fail` — mail works
  either way).
