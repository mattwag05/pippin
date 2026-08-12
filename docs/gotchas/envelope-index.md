# Mail Envelope Index (pippin-60x — IMPLEMENTED 2026-07-15)

The fast path lives in `pippin/MailBridge/MailEnvelopeIndex.swift`, hooked at
the top of `MailBridge.listMessages`/`searchMessages`/`listActivity` (metadata
only; any failure falls back to JXA automatically — and since pippin-1son
(2026-07-30) the failure reason is captured in `ScanOutcome.fastPathNote` and
surfaced as an envelope `warnings` entry (agent) / stderr `Warning:` (text,
json), so a seconds-instead-of-milliseconds scan is self-diagnosing rather than
silent; a fast path *disabled* by env/config intentionally emits no note).
Kill switches:
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
- **🛑 Gmail mailboxes are LABEL VIEWS, not mailboxes (pippin-z0f6).** A
  message row points at exactly ONE mailbox (`messages.mailbox`). On Gmail that
  is almost always `[Gmail]/All Mail`: `INBOX`, `[Gmail]/Important`,
  `[Gmail]/Starred`, `[Gmail]/Sent Mail` and every custom label are *views*
  (`mailboxes.source` → the backing mailbox) whose membership lives in
  `labels(message_id, mailbox_id)`. `messages.mailbox` NEVER points at them, so
  the original `m.mailbox IN (...)` matched zero rows and reported a real inbox
  as **`status: ok, data: []`** — 5,422 inbox messages across three accounts,
  invisible, for the life of the fast path. `MailboxTargets` now splits a
  resolved target set by `source` and queries both models in one statement.
  Notes:
  - **Only All Mail / Trash / Spam / Drafts are real mailboxes on Gmail** —
    labels and real mailboxes coexist under one account, so this is per-mailbox,
    not per-account.
  - **A label hit's `m.mailbox` is the BACKING mailbox**, so the compound id
    must come from the matched target (`matchColumn`), not `m.mailbox`, or
    every id would say `All Mail` and `mail show`/`mark`/`move` would act on the
    wrong mailbox. A row matching both a real and a label target prefers the
    real one, keeping unfiltered ("all mailboxes") scans naming All Mail as
    before.
  - **A non-Gmail target set generates byte-identical SQL** to pre-fix — the
    labels join only appears when a label target is present.
  - **`--mailbox All Mail` is not a substitute for INBOX**: All Mail holds
    inbox and archived mail indistinguishably, which is why "just query All
    Mail" was rejected as a fix.
  - The pippin-60x e2e parity check samples ONE account and passed throughout;
    the pippin-z0f6 check asserts per-account that a fast-path empty inbox is
    matched by an empty JXA inbox.
- **Dedup mirrors JXA**: the same message can appear under more than one
  mailbox row (across accounts, or Gmail All Mail vs Trash) — key on
  `message_id_header`, fallback subject+sender+date; offset applies after dedup
  (search). Label matching does NOT duplicate rows: `labels` is only ever an
  `IN`-subquery, so one `messages` row yields one result row even when it
  satisfies both the real and the label branch.
- **Bodies are NOT in this DB** — `show`, previews-on-cache-miss, and all
  writes stay JXA. Fast-path activity/list previews reuse
  `assemblePreviews` + `buildBatchBodiesScript` + MailBodyCache (ids match, so
  cache keys line up).
- **`summaries` table (pippin-521, opt-in `mail.previewFromIndex`)** — Mail's
  own snippet text (`messages.summary` → `summaries.ROWID`, `summary` column).
  Three invariants from the deferral review, all still true: (1) the snippet is
  Mail's SEMANTIC summary, not the body's first N chars — preview-text
  consumers see drift, which is why the key defaults off; (2) only a fraction
  of messages carry one (~23% measured 2026-07-28, 6.3k of 27k) — absent rows
  MUST fall back to the batch body fetch (`assemblePreviews` treats them as
  ordinary misses); (3) a summary-served preview bypasses the MailBodyCache
  write-through, so a later `mail show` of that message pays a cold fetch.
  Priority in `assemblePreviews`: cached body > seeded snippet (e.g. a `--body`
  search match, pippin-1son) > summary > batch fetch. Enabled in this machine's
  `~/.config/pippin/config.json` since 2026-07-30 (backup: `config.json.bak-20260730`).
- **FDA required** (same class as Messages `chat.db`): the snapshot copy fails
  with EPERM → `accessDenied` → JXA fallback (reason in `warnings`). `doctor`
  reports fast-path availability as an informational check (`.skip`, never
  `.fail` — mail works either way).
