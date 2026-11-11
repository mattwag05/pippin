import Foundation

enum MailBridge {
    // MARK: - Public API

    /// Outcome of any scan call (list/activity/search): messages plus a
    /// `timedOut` flag callers must surface so the user knows results may
    /// be incomplete and how to narrow the query. The three call sites used
    /// to define byte-identical wrapper structs each — this is the unified
    /// type, with type aliases below for the legacy names so existing
    /// callers stay compiling.
    struct ScanOutcome {
        let messages: [MailMessage]
        let timedOut: Bool
        /// Non-nil when the Envelope Index fast path threw and the call fell
        /// back to the slow JXA scan — the single-line reason, ready to
        /// surface as a warning so callers can see *why* they paid seconds
        /// instead of milliseconds. `nil` when the fast path succeeded or was
        /// intentionally skipped (disabled, `--body`, preview fetch).
        var fastPathNote: String? = nil
        /// Non-nil when the answer may be missing rows for a reason other than
        /// a timeout (the index candidate cap). Callers surface it as a warning
        /// and mark the envelope partial.
        var truncationNote: String? = nil
    }

    /// Most rows one list, search or activity call returns. A paginated caller
    /// passes `pageSentinel: true` to fetch one row more, which only tells it
    /// whether another page exists.
    static let rowCap = 500

    static func clampScanLimit(_ limit: Int, pageSentinel: Bool) -> Int {
        max(1, min(limit, rowCap + (pageSentinel ? 1 : 0)))
    }

    /// Advisory for a caller that asked for more than `rowCap` rows and got
    /// exactly the cap back: more may exist.
    static func rowCapNote(requested: Int, returned: Int) -> String? {
        guard requested > rowCap, returned == rowCap else { return nil }
        return "--limit \(requested) is above the \(rowCap)-row cap, so only \(rowCap) rows were returned and more may exist; page through them with --page-size \(rowCap) and --cursor"
    }

    static let candidateCapNote = "the index scan stopped at \(MailEnvelopeIndex.candidateCap) candidate rows before filling this request, so older matches may be missing; narrow with --after, --before, --since, --account or --mailbox"

    /// Single-line advisory for `ScanOutcome.fastPathNote`.
    static func fastPathFallbackNote(_ error: Error) -> String {
        let reason = String(describing: error).replacingOccurrences(of: "\n", with: " ")
        return "envelope-index fast path unavailable (\(reason)); fell back to slower JXA scan"
    }

    /// Outcome of `listMailboxes`: the rows plus the same `fastPathNote`
    /// contract as `ScanOutcome`. Separate type because mailbox rows aren't
    /// messages and this call has no soft timeout to report.
    struct MailboxesOutcome {
        let mailboxes: [Mailbox]
        var fastPathNote: String? = nil
    }

    typealias ListOutcome = ScanOutcome
    typealias ActivityOutcome = ScanOutcome
    typealias SearchOutcome = ScanOutcome

    /// Clamp a ScriptRunner hard-timeout below the MCP `runChild` cap
    /// (`MCPServerRuntime.defaultChildTimeoutSeconds`, 60s) when running under
    /// MCP, so a wedged osascript is reaped by ScriptRunner — returning a clean
    /// `.timeout` / partial results — before the MCP layer SIGKILLs the whole
    /// pippin child (an ungraceful `.childTimedOut`). The 22s soft cap fires
    /// long before this ceiling in normal operation, so the clamp only changes
    /// the pathological wedge case; in CLI there is no such cap, so the full
    /// cross-account-scaled value is used.
    static func mcpHardTimeout(_ seconds: Int) -> Int {
        clampHardTimeout(seconds, underMCP: isMCPContext())
    }

    /// Pure clamp logic (testable without mutating process env). Under MCP the
    /// ceiling is 55s — 5s below the 60s `runChild` cap, leaving the runtime
    /// room to SIGTERM/SIGKILL gracefully if the bridge somehow overruns.
    static func clampHardTimeout(_ seconds: Int, underMCP: Bool) -> Int {
        underMCP ? min(seconds, 55) : seconds
    }

    // MARK: - Envelope Index fast path (pippin-60x)

    /// Whether the Envelope Index fast path may run. Env kill switch
    /// (`PIPPIN_MAIL_FASTPATH=0` — used by e2e parity checks and as an
    /// emergency off) beats the `mail.fastPath` config key; absent both, ON.
    /// The fast path still falls back to JXA silently on any failure, so ON
    /// costs nothing when the index is unreadable (no Full Disk Access).
    static func fastPathEnabled(
        env: [String: String] = ProcessInfo.processInfo.environment,
        config: PippinConfig? = AIProviderFactory.loadConfig()
    ) -> Bool {
        if env["PIPPIN_MAIL_FASTPATH"] == "0" { return false }
        return config?.mail?.fastPath ?? true
    }

    /// JXA accounts-script row (`buildAccountsScript`): `id` is the account
    /// UUID that prefixes every Envelope Index `mailboxes.url` (verified ==
    /// `acct.id()` live, 2026-07-15).
    private struct AccountScriptRow: Decodable {
        let name: String
        let email: String
        let id: String?
    }

    /// One JXA round-trip for the account name→UUID map. Only called by
    /// `MailAccountsCache.ensure` on a cache miss — accounts change rarely.
    static func fetchAccountRecords() throws -> [MailAccountRecord] {
        let json = try runScript(buildAccountsScript(), timeoutSeconds: mcpHardTimeout(30), idempotent: true)
        return try decode([AccountScriptRow].self, from: json).compactMap { row in
            guard let id = row.id, !id.isEmpty else { return nil }
            return MailAccountRecord(name: row.name, email: row.email, uuid: id)
        }
    }

    /// Typed `--account` validation for list/search/activity, applied ABOVE
    /// the fast-path/JXA fork so both paths behave identically: an unknown
    /// account name is a typed `accountNotFound` (agent code
    /// `account_not_found`, exit 3) listing the real names, instead of an
    /// empty-ok result indistinguishable from an empty mailbox.
    /// `MailAccountsCache.ensure` refreshes on a name miss, so a just-added
    /// account passes after one JXA round-trip. If accounts can't be
    /// enumerated at all (no cache + Mail not authorized), validation is
    /// skipped and the query proceeds to surface its own error.
    static func validateAccount(_ name: String?) throws {
        guard let name else { return }
        let records = (try? MailAccountsCache.ensure(accountName: name) { try fetchAccountRecords() }) ?? []
        try ensureKnownAccount(name, in: records)
    }

    /// Pure core of `validateAccount` (unit-testable without Mail.app).
    /// Empty `records` = "couldn't enumerate accounts" → no-throw.
    static func ensureKnownAccount(_ name: String, in records: [MailAccountRecord]) throws {
        guard !records.isEmpty, !records.contains(where: { $0.name == name }) else { return }
        throw MailBridgeError.accountNotFound(name, available: records.map(\.name))
    }

    /// Build an Envelope Index reader for a query, or throw (→ JXA fallback).
    /// Self-heals the account cache when the index references a UUID the cache
    /// can't map (new account added since the cache was written) — at most one
    /// extra JXA refresh per `MailAccountsCache.isStale` TTL, so a permanently
    /// unmappable UUID can't re-trigger an Apple Event on every command.
    static func makeFastPathIndex(accountName: String?) throws -> MailEnvelopeIndex {
        guard let dbPath = MailEnvelopeIndex.defaultDBPath() else {
            throw MailEnvelopeIndexError.databaseNotFound("~/Library/Mail/V*/MailData/Envelope Index")
        }
        let accounts = try MailAccountsCache.ensure(accountName: accountName) {
            try fetchAccountRecords()
        }
        let index = try sharedFastPathIndex(dbPath: dbPath, accounts: accounts)
        if try !index.unknownAccountUUIDs().isEmpty {
            let (_, fetchedAt) = MailAccountsCache.load()
            if MailAccountsCache.isStale(fetchedAt: fetchedAt),
               let fresh = try? fetchAccountRecords(), !fresh.isEmpty {
                MailAccountsCache.save(fresh, fetchedAt: Date())
                return try sharedFastPathIndex(dbPath: dbPath, accounts: fresh)
            }
        }
        return index
    }

    private static let fastPathMemo: MailEnvelopeIndexMemo = {
        // A static is never deinitialized, so drop the snapshot at exit or its
        // temp dir would outlive the process.
        atexit { MailBridge.fastPathMemo.clear() }
        return MailEnvelopeIndexMemo()
    }()

    /// One snapshot per process while Mail's index is unchanged; see
    /// `MailEnvelopeIndexMemo` for the invalidation rule.
    private static func sharedFastPathIndex(
        dbPath: String, accounts: [MailAccountRecord]
    ) throws -> MailEnvelopeIndex {
        try fastPathMemo.index(dbPath: dbPath, accounts: accounts)
    }

    /// Per-account mailbox counts for `pippin status`. Tries the Envelope Index
    /// fast path (one SQLite scan, ~ms) and falls back to per-account JXA
    /// (`listMailboxes` × N accounts, ~seconds) on any failure — same fallback
    /// contract as list/search/activity. `accounts` is passed in so status
    /// doesn't re-enumerate. Returns name→count; a name absent from the result
    /// means the count couldn't be determined (caller defaults to 0).
    static func mailboxCounts(for accounts: [MailAccount]) -> [String: Int] {
        if fastPathEnabled(), let index = try? makeFastPathIndex(accountName: nil),
           let counts = try? index.mailboxCountsByAccount() {
            return counts
        }
        var counts: [String: Int] = [:]
        for account in accounts {
            counts[account.name] = (try? listMailboxes(account: account.name))?.mailboxes.count ?? 0
        }
        return counts
    }

    /// Minimal probe that exercises only the Mail.app ready-poll
    /// (`jsMailReadyPoll`) and returns. Used by `pippin doctor --latency` to
    /// isolate Mail.app launch/ready time from per-query (mailbox scan / body
    /// fetch) work — a slow ready-poll points at Mail.app startup/sync, a slow
    /// list/search points at the query itself.
    static func probeReady() throws {
        let script = """
        var mail = Application('Mail');
        \(jsMailReadyPoll(maxAttempts: 20))
        JSON.stringify({ready: true});
        """
        _ = try runScript(script, timeoutSeconds: mcpHardTimeout(55), idempotent: true)
    }

    static func listMessages(
        account: String? = nil,
        mailbox: String = "INBOX",
        unread: Bool = false,
        limit: Int = 50,
        offset: Int = 0,
        preview: Int? = nil,
        after: String? = nil,
        before: String? = nil,
        softTimeoutMs: Int = SoftTimeout.defaultMs,
        fastPath: Bool = true,
        pageSentinel: Bool = false,
        seekingAfter anchor: Cursor.Anchor? = nil
    ) throws -> ListOutcome {
        try validateAccount(account)
        let crossAccount = (account == nil)
        let (after, before) = dayFilterInstants(after: after, before: before)
        let clampedLimit = clampScanLimit(limit, pageSentinel: pageSentinel)
        let clampedOffset = max(0, offset)
        // Envelope Index fast path (pippin-60x): metadata-only scans answer from
        // Mail's on-disk SQLite in ~ms instead of a 10–100s JXA enumeration.
        // Preview lists fall through — bodies are not in the index (but
        // `listMessagesCached` pass 1 calls with `preview: nil`, so
        // `mail list --preview` still gets a fast metadata pass). Any failure
        // falls back to JXA silently: no FDA, unknown schema, unresolvable
        // account/mailbox — the fast path is an accelerator, never a gate.
        // `doctor --latency` passes `fastPath: false` to measure
        // the real JXA/Mail.app path.
        var fastPathNote: String?
        if fastPath, (preview ?? 0) == 0, fastPathEnabled() {
            do {
                let messages = try makeFastPathIndex(accountName: account).listMessages(
                    account: account, mailbox: mailbox, unread: unread,
                    limit: clampedLimit, offset: clampedOffset, after: after, before: before,
                    seekingAfter: anchor
                )
                return ListOutcome(messages: attachCachedAnomalies(messages), timedOut: false)
            } catch {
                fastPathNote = fastPathFallbackNote(error)
            }
        }
        // Pippin's own index: no Full Disk Access, verified by a live read.
        if fastPath, (preview ?? 0) == 0, let messages = listFromStore(
            account: account, mailbox: mailbox, unread: unread,
            limit: clampedLimit, offset: clampedOffset, after: after, before: before
        ) {
            return ListOutcome(messages: attachCachedAnomalies(messages), timedOut: false)
        }
        let script = buildListScript(
            account: account, mailbox: mailbox, unread: unread,
            limit: clampedLimit, offset: clampedOffset, preview: preview,
            after: after, before: before,
            softTimeoutMs: softTimeoutMs
        )
        // The JXA loop self-bounds via softTimeoutMs (default 22s) when preview
        // forces per-message body fetches.  50s was too tight for cross-account
        // scans with --limit 100 --preview 200 (e.g. CRM sync); 50s matches
        // listActivity and gives JXA enough headroom for JSON.stringify after
        // the soft cap fires.
        // Cross-account scans iterate multiple accounts' INBOXes, each with
        // 1000–2700 messages — 10s is far too short.  Use a 6× multiplier for
        // cross-account to avoid hard-timeout crashes (measured ~20s).
        let timeout = listScanTimeout(
            crossAccount: crossAccount, fetchesBodies: (preview ?? 0) > 0, softTimeoutMs: softTimeoutMs
        )
        let json = try runScript(script, timeoutSeconds: mcpHardTimeout(timeout), idempotent: true)
        let wrapper = try decode(ListResponse.self, from: json)
        return ListOutcome(
            messages: attachCachedAnomalies(wrapper.results),
            timedOut: wrapper.meta.timedOut,
            fastPathNote: fastPathNote
        )
    }

    /// Keyset position of a listed row, so the next page can seek past it rather
    /// than skip a count of rows that new mail may have shifted. Mirrors the
    /// Envelope Index order (received date, else sent date; then ROWID).
    static func pageAnchor(_ message: MailMessage) -> Cursor.Anchor? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let rowid = message.id.components(separatedBy: "||").last.flatMap({ Int64($0) }),
              let date = iso.date(from: message.receivedAt ?? message.date)
        else { return nil }
        return Cursor.Anchor(epoch: Int64(date.timeIntervalSince1970), rowid: rowid)
    }

    /// `--after` and `--before` each name a whole calendar day in the user's
    /// time zone, both inclusive, as their help text says. Returns the two
    /// bounds as UTC instants every read path (Envelope Index, store, JXA)
    /// parses alike: the first second of the `after` day and the last second of
    /// the `before` day. Anything that is not `YYYY-MM-DD` passes through.
    ///
    /// The paths used to read the bare day as UTC midnight, so `--before`
    /// dropped its own day and both bounds were hours off local time (DAT-11).
    static func dayFilterInstants(
        after: String?, before: String?, timeZone: TimeZone = .current
    ) -> (after: String?, before: String?) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = calendar
        parser.timeZone = timeZone
        parser.dateFormat = "yyyy-MM-dd"
        let iso = ISO8601DateFormatter()
        func dayStart(_ day: String) -> Date? {
            day.count == 10 ? parser.date(from: day) : nil
        }
        let lower = after.map { day in dayStart(day).map(iso.string(from:)) ?? day }
        let upper = before.map { day in
            dayStart(day)
                .flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
                .map { iso.string(from: $0.addingTimeInterval(-1)) } ?? day
        }
        return (lower, upper)
    }

    /// Parse a `--before`/`--after` filter (`YYYY-MM-DD`, local midnight) the
    /// same way the JXA `new Date(str)` comparison does, for the shortfall check.
    static func parseFilterDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f.date(from: s)
    }

    /// Hard timeout (seconds) for a `mail list`-style scan. Cross-account inboxes
    /// are far larger (5 accounts × 1000–2700 msgs), and a preview/body fetch
    /// adds per-message `msg.content()` IMAP cost. Shared by `listMessages` and
    /// the `listMessagesCached` batch-body pass so the two list paths' timeout
    /// scaling can't drift. (Activity uses a different, larger base — see
    /// `listActivity`.)
    ///
    /// The hard timeout never drops below the script's own soft cap plus
    /// `softCapHeadroomSeconds`, so a slow scan stops itself and returns its
    /// rows with `partial: true` instead of being killed. A fixed 10s
    /// single-account base sat below the 22s soft cap, so a slow JXA scan
    /// (`--unread`, `--limit 500`) never reached it: ScriptRunner killed the
    /// script at 10s, relaunched Mail, retried, and failed again at ~20.6s
    /// (pippin-zzdd, pippin-9rf0).
    static func listScanTimeout(
        crossAccount: Bool,
        fetchesBodies: Bool,
        softTimeoutMs: Int = SoftTimeout.defaultMs
    ) -> Int {
        let base = crossAccount ? 60 : 10
        let scaled = fetchesBodies ? base + 40 : base
        return max(scaled, SoftTimeout.clamp(softTimeoutMs) / 1000 + softCapHeadroomSeconds)
    }

    /// Time after the soft cap for the script to sort, slice and serialize the
    /// rows it already gathered.
    static let softCapHeadroomSeconds = 15

    static func listActivity(
        account: String? = nil,
        mailboxes: [String] = ["INBOX", "Sent"],
        since: Date? = nil,
        limit: Int = 50,
        preview: Int? = 200,
        softTimeoutMs: Int = SoftTimeout.defaultMs,
        fastPath: Bool = true
    ) throws -> ActivityOutcome {
        try validateAccount(account)
        let crossAccount = (account == nil)
        // Envelope Index fast path (pippin-60x): metadata from SQLite, previews
        // (activity defaults to 200 chars) via the same MailBodyCache + batch
        // JXA machinery as `mail list --preview` — cache hits skip osascript
        // entirely, misses cost one bounded batch fetch. JXA fallback on any
        // index failure.
        var fastPathNote: String?
        var indexed: (index: MailEnvelopeIndex, metadata: [MailMessage])?
        var truncationNote: String?
        if fastPath, fastPathEnabled() {
            do {
                let index = try makeFastPathIndex(accountName: account)
                let scan = try index.activityScan(
                    account: account, mailboxes: mailboxes, since: since, limit: limit
                )
                indexed = (index, scan.messages)
                truncationNote = scan.hitCandidateCap ? candidateCapNote : nil
            } catch {
                fastPathNote = fastPathFallbackNote(error)
            }
        }
        if let (index, metadata) = indexed {
            let previewChars = (preview ?? 0) > 0 ? max(1, min(preview ?? 0, 4000)) : 0
            guard previewChars > 0 else {
                return ActivityOutcome(
                    messages: attachCachedAnomalies(metadata), timedOut: false, truncationNote: truncationNote
                )
            }
            let assembled = try assemblePreviews(
                metadata: metadata,
                previewChars: previewChars,
                cache: MailBodyCache.shared,
                summaries: indexSummaries(index, for: metadata),
                fetchMisses: { ids in
                    try batchFetchBodies(ids: ids, crossAccount: crossAccount, softTimeoutMs: softTimeoutMs)
                }
            )
            return ActivityOutcome(
                messages: attachCachedAnomalies(assembled.messages), timedOut: assembled.fetchTimedOut,
                truncationNote: truncationNote
            )
        }
        let script = buildActivityScript(
            account: account, mailboxes: mailboxes, since: since,
            limit: limit, preview: preview, softTimeoutMs: softTimeoutMs
        )
        // Cross-account activity scans 5 accounts × 2 mailboxes × 500 msgs =
        // 5000 messages. 50s was too short, 60s is the MCP runChild cap.
        // Raise base to 75s for cross-account to give the 22s soft cap +
        // JSON.stringify enough headroom before the ScriptRunner cap fires.
        let baseTimeout = crossAccount ? 75 : 30
        let timeout = (preview ?? 0) > 0 ? baseTimeout + 40 : baseTimeout
        let json = try runScript(script, timeoutSeconds: mcpHardTimeout(timeout), idempotent: true)
        let wrapper = try decode(ActivityResponse.self, from: json)
        return ActivityOutcome(
            messages: attachCachedAnomalies(wrapper.results),
            timedOut: wrapper.meta.timedOut,
            fastPathNote: fastPathNote
        )
    }

    static func searchMessages(
        query: String,
        account: String? = nil,
        mailbox: String? = nil,
        searchBody: Bool = false,
        limit: Int = 10,
        offset: Int = 0,
        after: String? = nil,
        before: String? = nil,
        to: String? = nil,
        from: String? = nil,
        verbose: Bool = false,
        softTimeoutMs: Int = SoftTimeout.defaultMs,
        fastPath: Bool = true,
        preview: Int? = nil,
        pageSentinel: Bool = false
    ) throws -> SearchOutcome {
        try validateAccount(account)
        let crossAccount = (account == nil) && (mailbox == nil)
        let (after, before) = dayFilterInstants(after: after, before: before)
        let clampedOffset = max(0, offset)
        // Envelope Index fast path (pippin-60x): subject/sender LIKE across the
        // whole index in ~ms (measured 31ms over 28k messages) vs a 45–95s JXA
        // window scan — and it can't miss old matches the way the newest-N JXA
        // window can. `--body` falls through (bodies are not in the index).
        var fastPathNote: String?
        if fastPath, !searchBody, fastPathEnabled() {
            do {
                let scan = try makeFastPathIndex(accountName: account).searchScan(
                    query: query, account: account, mailbox: mailbox,
                    limit: limit, offset: clampedOffset, after: after, before: before,
                    to: to, from: from
                )
                if verbose {
                    let line = "[search] fast path: envelope index (full-index scan, JXA bypassed)\n"
                    FileHandle.standardError.write(Data(line.utf8))
                }
                return SearchOutcome(
                    messages: attachCachedAnomalies(scan.messages), timedOut: false,
                    truncationNote: scan.hitCandidateCap ? candidateCapNote : nil
                )
            } catch {
                fastPathNote = fastPathFallbackNote(error)
            }
        }
        // Recipients and bodies are not in the store, so those searches read Mail.
        if fastPath, !searchBody, to == nil, let messages = searchFromStore(
            query: query, account: account, mailbox: mailbox,
            limit: limit, offset: clampedOffset, after: after, before: before, from: from
        ) {
            return SearchOutcome(messages: attachCachedAnomalies(messages), timedOut: false)
        }
        let script = buildSearchScript(
            query: query, account: account, mailbox: mailbox, searchBody: searchBody,
            limit: limit, offset: clampedOffset, after: after, before: before, to: to,
            from: from, softTimeoutMs: softTimeoutMs, preview: preview, pageSentinel: pageSentinel
        )
        // Cross-account (no --account, no --mailbox) iterates 5 accounts ×
        // ~21 mailboxes = 100+ mailbox scans.  When --body is on, each match
        // forces msg.content() (IMAP body download).  30s is far too tight.
        // CLI hard caps: 95s cross-account --body (from measured 120s+ runs),
        // 65s cross-account no --body, 75s single-account --body, 45s
        // single-account no --body. Under MCP these are clamped to 55s by
        // mcpHardTimeout so the bridge self-reaps before the 60s runChild cap.
        let baseTimeout = crossAccount ? 50 : 30
        let timeout = searchBody ? baseTimeout + 45 : baseTimeout + 15
        let json = try runScript(script, timeoutSeconds: mcpHardTimeout(timeout), idempotent: true)
        let wrapper = try decode(SearchResponse.self, from: json)
        if verbose {
            let stderr = FileHandle.standardError
            let meta = wrapper.meta
            let lines = [
                "[search] accounts scanned: \(meta.accountsScanned)",
                "[search] mailboxes scanned: \(meta.mailboxesScanned)",
                "[search] messages examined: \(meta.messagesExamined)",
                "[search] body search: \(searchBody ? "on" : "off (use --body to search message content)")",
                "[search] timed out: \(meta.timedOut ? "yes (returning partial results)" : "no")",
            ]
            for line in lines {
                stderr.write(Data((line + "\n").utf8))
            }
        }
        return SearchOutcome(
            messages: attachCachedAnomalies(wrapper.results),
            timedOut: wrapper.meta.timedOut,
            fastPathNote: fastPathNote
        )
    }

    /// A timed-out scan can only establish absence after it inspected the full
    /// search space. Nonempty timed-out results remain useful partial results.
    static func requireCompleteSearch(resultCount: Int, timedOut: Bool) throws {
        if timedOut, resultCount == 0 {
            throw MailBridgeError.searchIncomplete
        }
    }

    static func markMessage(
        compoundId: String,
        read: Bool,
        dryRun: Bool = false,
        expectMessageId: String? = nil
    ) throws -> BridgeActionResult {
        let (account, mailboxName, msgId) = try parseCompoundId(compoundId)
        let script = buildMarkScript(
            account: account, mailbox: mailboxName, messageId: msgId, read: read, dryRun: dryRun,
            expectMessageId: expectMessageId
        )
        // Write operation: use 20s timeout to accommodate cold Mail launch + IMAP round-trip
        let json = try runScript(script, timeoutSeconds: 20, idempotent: true)
        return try decode(BridgeActionResult.self, from: json)
    }

    static func moveMessage(
        compoundId: String,
        toMailbox: String,
        dryRun: Bool = false,
        expectMessageId: String? = nil,
        locateByMessageId: Bool = false
    ) throws -> BridgeActionResult {
        let (account, mailboxName, msgId) = try parseCompoundId(compoundId)
        guard toMailbox.count <= 256, toMailbox.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else {
            throw MailBridgeError.invalidMailbox(toMailbox)
        }
        let script = buildMoveScript(
            account: account, mailbox: mailboxName, messageId: msgId, toMailbox: toMailbox, dryRun: dryRun,
            expectMessageId: expectMessageId, locateByMessageId: locateByMessageId
        )
        // Move triggers IMAP MOVE server-side — use 45s timeout for slow servers
        let json = try runScript(script, timeoutSeconds: 45)
        return try decode(BridgeActionResult.self, from: json)
    }

    static func sendMessage(
        to: [String],
        subject: String,
        body: String,
        cc: [String] = [],
        bcc: [String] = [],
        from accountName: String? = nil,
        attachmentPaths: [String] = [],
        dryRun: Bool = false
    ) throws -> BridgeActionResult {
        let script = buildSendScript(
            to: to,
            subject: subject,
            body: body,
            cc: cc,
            bcc: bcc,
            from: accountName,
            attachmentPaths: attachmentPaths,
            dryRun: dryRun
        )
        // Send triggers SMTP handshake — use 45s timeout
        let json = try runScript(script, timeoutSeconds: 45, sending: !dryRun)
        return try decode(BridgeActionResult.self, from: json)
    }

    static func listAttachments(
        compoundId: String, saveDir: String? = nil, expectMessageId: String? = nil
    ) throws -> [Attachment] {
        let (account, mailboxName, msgId) = try parseCompoundId(compoundId)
        // Mail saves into a staging directory under index names. The sender's
        // file names only ever reach `finalizeSavedAttachments`, in Swift.
        let staging = saveDir.map { URL(fileURLWithPath: $0).appendingPathComponent(".pippin-saving-\(UUID().uuidString)") }
        if let staging {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        }
        // Also removes the zero-byte placeholder of any save that failed.
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
        let script = buildSaveAttachmentsScript(
            account: account, mailbox: mailboxName, messageId: msgId, saveDir: staging?.path,
            expectMessageId: expectMessageId
        )
        // Gmail label fallback scans every mailbox for the id + IMAP body download for
        // attachment enumeration; 30s was insufficient on large accounts.
        let json = try runScript(script, timeoutSeconds: 90, idempotent: saveDir == nil)
        let staged = try decode([Attachment].self, from: json)
        guard let saveDir else { return staged }
        return finalizeSavedAttachments(staged, saveDir: saveDir)
    }

    /// Move each staged attachment to a safe, unused name directly inside
    /// `saveDir`. Never overwrites: a taken name gets " (1)", " (2)", and so on.
    /// A row that could not be saved keeps `savedPath` nil and says why.
    static func finalizeSavedAttachments(_ staged: [Attachment], saveDir: String) -> [Attachment] {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: saveDir).standardizedFileURL
        return staged.enumerated().map { index, row in
            func result(path: String? = nil, error: String? = nil) -> Attachment {
                Attachment(name: row.name, mimeType: row.mimeType, size: row.size, savedPath: path, saveError: error)
            }
            guard let stagedPath = row.savedPath, fm.fileExists(atPath: stagedPath) else {
                return result(error: row.saveError ?? "Mail did not write the file")
            }
            let name = safeAttachmentName(row.name, index: index)
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            var destination = dir.appendingPathComponent(name)
            var suffix = 0
            // attributesOfItem does not follow links, so a dangling link counts as taken.
            while (try? fm.attributesOfItem(atPath: destination.path)) != nil {
                suffix += 1
                destination = dir.appendingPathComponent(ext.isEmpty ? "\(stem) (\(suffix))" : "\(stem) (\(suffix)).\(ext)")
            }
            guard destination.standardizedFileURL.deletingLastPathComponent().path == dir.path else {
                return result(error: "refused: the file name would leave the save directory")
            }
            do {
                // moveItem fails rather than replace, so a name taken since the check is not overwritten.
                try fm.moveItem(atPath: stagedPath, toPath: destination.path)
                return result(path: destination.path)
            } catch {
                return result(error: error.localizedDescription)
            }
        }
    }

    /// A sender-chosen attachment name reduced to a plain file name: last path
    /// component only, no control or invisible formatting characters (NUL,
    /// newlines, bidi overrides), no leading dots. `attachment-<n>` when
    /// nothing is left.
    static func safeAttachmentName(_ raw: String, index: Int) -> String {
        let base = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let hidden: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator]
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: base.unicodeScalars.filter { !hidden.contains($0.properties.generalCategory) })
        let name = String(String(kept).drop(while: { $0 == "." || $0 == " " }))
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "attachment-\(index + 1)" : name
    }

    static func replyToMessage(
        compoundId: String,
        body: String,
        to overrideTo: [String]? = nil,
        cc: [String] = [],
        bcc: [String] = [],
        from accountName: String? = nil,
        attachmentPaths: [String] = [],
        dryRun: Bool = false,
        expectMessageId: String? = nil
    ) throws -> BridgeActionResult {
        let original = try readMessage(compoundId: compoundId)
        try requireIdentity(of: original, expectMessageId: expectMessageId)
        let replyTo = overrideTo ?? [original.from]
        let replySubject = buildReplySubject(original.subject)
        let quotedBody = buildReplyQuote(date: original.date, from: original.from, body: original.body ?? "")
        let fullBody = body + "\n\n" + quotedBody
        let script = buildSendScript(
            to: replyTo,
            subject: replySubject,
            body: fullBody,
            cc: cc,
            bcc: bcc,
            from: accountName,
            attachmentPaths: attachmentPaths,
            dryRun: dryRun
        )
        let json = try runScript(script, timeoutSeconds: 45, sending: !dryRun)
        return try decode(BridgeActionResult.self, from: json)
    }

    static func forwardMessage(
        compoundId: String,
        to: [String],
        body: String = "",
        cc: [String] = [],
        bcc: [String] = [],
        from accountName: String? = nil,
        attachmentPaths: [String] = [],
        dryRun: Bool = false,
        expectMessageId: String? = nil
    ) throws -> BridgeActionResult {
        let original = try readMessage(compoundId: compoundId)
        try requireIdentity(of: original, expectMessageId: expectMessageId)
        let fwdSubject = buildForwardSubject(original.subject)
        let prefix = buildForwardPrefix(from: original.from, date: original.date, subject: original.subject, to: original.to, body: original.body ?? "")
        let fullBody = body.isEmpty ? prefix : body + "\n\n" + prefix
        let script = buildSendScript(
            to: to,
            subject: fwdSubject,
            body: fullBody,
            cc: cc,
            bcc: bcc,
            from: accountName,
            attachmentPaths: attachmentPaths,
            dryRun: dryRun
        )
        let json = try runScript(script, timeoutSeconds: 45, sending: !dryRun)
        return try decode(BridgeActionResult.self, from: json)
    }

    /// Asks Mail for the account names (one Apple Event, about 15 ms per extra event) and takes
    /// email and id from the account cache when the names match it and the cache is under an hour
    /// old. Otherwise the full script runs and refreshes the cache (pippin-k177).
    static func listAccounts(cachePath: String = MailAccountsCache.defaultPath()) throws -> [MailAccount] {
        let (cached, fetchedAt) = MailAccountsCache.load(path: cachePath)
        if !cached.isEmpty, !MailAccountsCache.isStale(fetchedAt: fetchedAt) {
            let names = try decode([String].self, from: runScript(buildAccountNamesScript(), idempotent: true))
            if let hit = cachedAccounts(names: names, cached: cached) { return hit }
        }
        let rows = try decode([AccountScriptRow].self, from: runScript(buildAccountsScript(), idempotent: true))
        let records = rows.compactMap { row in
            row.id.flatMap { $0.isEmpty ? nil : MailAccountRecord(name: row.name, email: row.email, uuid: $0) }
        }
        if records.count == rows.count { MailAccountsCache.save(records, fetchedAt: Date(), path: cachePath) }
        return rows.map { MailAccount(name: $0.name, email: $0.email) }
    }

    /// The cached accounts, in Mail's order, when Mail reports exactly the cached names.
    static func cachedAccounts(names: [String], cached: [MailAccountRecord]) -> [MailAccount]? {
        guard !names.isEmpty, names == cached.map(\.name) else { return nil }
        return cached.map { MailAccount(name: $0.name, email: $0.email) }
    }

    /// Per-mailbox message/unread counts. Envelope Index fast path first
    /// (pippin-zxsq): the index counts the per-message `read` flags, which JXA's
    /// `mb.unreadCount()` disagrees with by more than an order of magnitude on
    /// large mailboxes (8 vs 140, 34 vs 468) — always under-reporting. The fast
    /// path is therefore a CORRECTNESS fix here, not just a speed one (~15ms vs
    /// ~5.4s), so the JXA fallback carries a warning: its unread numbers are the
    /// known-low ones.
    static func listMailboxes(account: String? = nil) throws -> MailboxesOutcome {
        try validateAccount(account)
        var fastPathNote: String?
        if fastPathEnabled() {
            do {
                let mailboxes = try makeFastPathIndex(accountName: account).mailboxSummaries(account: account)
                return MailboxesOutcome(mailboxes: mailboxes)
            } catch {
                fastPathNote = fastPathFallbackNote(error) + Self.unreadUnderReportNote
            }
        }
        let script = buildMailboxesScript(account: account)
        let json = try runScript(script, idempotent: true)
        return try MailboxesOutcome(
            mailboxes: decode([Mailbox].self, from: json),
            fastPathNote: fastPathNote
        )
    }

    /// Appended to the fast-path fallback advisory for `mail mailboxes` — the
    /// JXA path's unread numbers are not merely slower to get, they are wrong.
    static let unreadUnderReportNote = " — unreadCount comes from Mail's own cached property on this path and is known to under-report large mailboxes (pippin-zxsq); cross-check with `mail list --unread`"

    /// Read a full message (body + headers + attachments) by compound id.
    ///
    /// The body fetch (`msg.content()`) is the expensive IMAP download, so a
    /// cached copy is served when `cache` holds one for the SAME message: the
    /// id's current date comes from the Envelope Index (`cacheIdentities`) and
    /// must match the cached copy (pippin-pvak). When the index can't vouch
    /// for the id (fast path off or unreadable), the read is live. Pass
    /// `cache: nil` (e.g. `mail show --no-cache`) to force a live fetch.
    /// `mail list`/`search` deliberately do NOT use this path, so their
    /// read/unread metadata stays live.
    static func readMessage(compoundId: String, cache: MailBodyCache? = MailBodyCache.shared) throws -> MailMessage {
        let identity = cache == nil ? nil : cacheIdentities(for: [compoundId])[compoundId]
        return try readMessage(compoundId: compoundId, cache: cache, identity: identity)
    }

    /// `readMessage` for a caller that already holds the message's list row:
    /// its `date` is the cache identity, so no Envelope Index snapshot is
    /// taken (`mail cache warm` and `mail index` loop over many rows).
    static func readMessage(row: MailMessage, cache: MailBodyCache? = MailBodyCache.shared) throws -> MailMessage {
        try readMessage(compoundId: row.id, cache: cache, identity: row.date)
    }

    private static func readMessage(compoundId: String, cache: MailBodyCache?, identity: String?) throws -> MailMessage {
        if let cached = cachedMessage(compoundId: compoundId, cache: cache, identity: identity) {
            return cached.withDetectedHeaderAnomalies(extra: baselineWarnings(for: cached))
        }
        let (account, mailboxName, msgId) = try parseCompoundId(compoundId)
        let script = buildReadScript(account: account, mailbox: mailboxName, messageId: msgId)
        // Large messages with attachments trigger a full IMAP body download via msg.content();
        // 10s default times out on multi-hundred-KB messages. 45s matches send/move timeouts.
        let json = try runScript(script, timeoutSeconds: 45, idempotent: true)
        let message = try decode(MailMessage.self, from: json)
        cache?.put(message)
        return message.withDetectedHeaderAnomalies(extra: baselineWarnings(for: message))
    }

    /// The cached copy of `compoundId`, only when its identity is known and
    /// matches. `identity == nil` (nothing can vouch for the id) is a miss.
    static func cachedMessage(compoundId: String, cache: MailBodyCache?, identity: String?) -> MailMessage? {
        guard let cache, let identity else { return nil }
        return cache.get(compoundId: compoundId, expectedDate: identity)
    }

    /// Current date per compound id, for cache validation on paths with no list
    /// row in hand: from the Envelope Index when readable, otherwise one live
    /// read. Empty on failure, which makes every cache read a miss.
    static func cacheIdentities(for compoundIds: [String]) -> [String: String] {
        if fastPathEnabled(), let index = try? makeFastPathIndex(accountName: nil),
           let dates = try? index.sentDatesByCompoundId(for: compoundIds) {
            return dates
        }
        guard let facts = try? liveMetaFacts(compoundIds) else { return [:] }
        return facts.compactMapValues(\.dateSent)
    }

    /// Batch read (`mail show <id> <id> …`): warm the cache for all misses in
    /// ONE osascript (`buildBatchBodiesScript` resolves each mailbox once —
    /// batch rows are as complete as a single-show fetch), then assemble per id
    /// from the cache. Ids the batch's soft timeout skipped (or whose identity
    /// the index can't vouch for) fall back to an individual live fetch,
    /// which is correct but slower. With `cache: nil` (`--no-cache`) there is nothing
    /// to warm; every id is a live single fetch.
    static func readMessages(compoundIds: [String], cache: MailBodyCache? = MailBodyCache.shared) throws -> [MailMessage] {
        let identities = cache == nil ? [:] : cacheIdentities(for: compoundIds)
        if let cache, compoundIds.count > 1 {
            let cached = cache.getMany(expectedDates: identities)
            let misses = compoundIds.filter { cached[$0] == nil }
            if !misses.isEmpty {
                let accounts = Set(misses.compactMap { try? parseCompoundId($0).account })
                let fetched = try batchFetchBodies(
                    ids: misses, crossAccount: accounts.count > 1, softTimeoutMs: SoftTimeout.defaultMs
                )
                for fresh in fetched.messages {
                    cache.put(fresh)
                }
            }
        }
        return try compoundIds.map { try readMessage(compoundId: $0, cache: cache, identity: identities[$0]) }
    }

    /// Raw RFC822 source for a message (pippin-fwa). Used by `mail verify` for
    /// the deep auth-chain parse; nil when Mail can't produce the source (the
    /// verify report then omits the chain rather than failing).
    static func readRawSource(compoundId: String) throws -> String? {
        let (account, mailboxName, msgId) = try parseCompoundId(compoundId)
        let script = buildSourceScript(account: account, mailbox: mailboxName, messageId: msgId)
        // source() can force a full RFC822 download incl. attachments — same
        // cost class as saveAttachments (90s there); readMessage usually ran
        // first so the body is already local.
        let json = try runScript(script, timeoutSeconds: mcpHardTimeout(90), idempotent: true)
        struct SourceRow: Decodable { let source: String? }
        return try decode(SourceRow.self, from: json).source
    }

    /// Attach header-anomaly warnings to scan rows (list/search/activity) from
    /// already-cached data (pippin-fwa). Those paths never fetch headers (cost),
    /// but any message previously read via `mail show`/preview batch has its
    /// headers in `MailBodyCache` — run the stateless checks plus a compare-only
    /// baseline check against those. Rows with no cached headers stay untouched
    /// (nil anomalies ≠ verified clean). Zero Apple Events, two local SQLite DBs.
    static func attachCachedAnomalies(
        _ messages: [MailMessage],
        cache: MailBodyCache? = MailBodyCache.shared,
        store: SenderBaselineStore? = SenderBaselineStore.shared
    ) -> [MailMessage] {
        guard let cache, !messages.isEmpty else { return messages }
        let cached = cache.getMany(expectedDates: rowDates(messages))
        return messages.map { msg in
            guard let hit = cached[msg.id], let headers = hit.headers, !headers.isEmpty else { return msg }
            // Use the cached row's from/to — scan rows emit to: [] on some paths,
            // which would false-positive the hidden-recipients check.
            var warnings = HeaderAnomalies.detect(from: hit.from, to: hit.to, headers: headers) ?? []
            if let store, let sender = HeaderAnomalies.emailAddress(in: hit.from) {
                warnings += store.check(
                    compoundId: msg.id, sender: sender,
                    fingerprint: SenderFingerprint.extract(headers: headers)
                )
            }
            return warnings.isEmpty ? msg : msg.withHeaderAnomalies(warnings)
        }
    }

    /// Sender-baseline deviation check (pippin-ml9): compare this message's
    /// header fingerprint against the sender's history, record it, and return
    /// warnings. No-ops (empty) when headers are missing or the store is
    /// unavailable — never blocks a read.
    static func baselineWarnings(for message: MailMessage, store: SenderBaselineStore? = SenderBaselineStore.shared) -> [String] {
        guard let store,
              let headers = message.headers, !headers.isEmpty,
              let sender = HeaderAnomalies.emailAddress(in: message.from) else { return [] }
        return store.checkAndRecord(
            compoundId: message.id, sender: sender,
            fingerprint: SenderFingerprint.extract(headers: headers)
        )
    }

    // MARK: - Cached bulk preview (mail list --preview)

    /// Envelope Index summaries for preview assembly (pippin-521), gated on the
    /// opt-in `mail.previewFromIndex` config key. `[:]` when off or on any
    /// index failure — preview assembly then behaves exactly as before.
    static func indexSummaries(
        _ index: MailEnvelopeIndex,
        for metadata: [MailMessage],
        config: PippinConfig? = AIProviderFactory.loadConfig()
    ) -> [String: String] {
        guard config?.mail?.previewFromIndex == true else { return [:] }
        return (try? index.summariesByCompoundId(for: metadata.map(\.id))) ?? [:]
    }

    /// `mail list --preview N` routed through `MailBodyCache`.
    ///
    /// Two passes, instead of fetching every body inline in the JXA enum loop
    /// (`buildListScript` with `preview > 0`):
    ///  1. Metadata-only enumeration (`listMessages(preview: nil)`) — cheap, no
    ///     `msg.content()`. Yields the **live** read/unread + metadata rows.
    ///  2. For rows whose body is already cached, derive the preview locally; for
    ///     misses, fetch all bodies in ONE batch osascript (`buildBatchBodiesScript`)
    ///     and write them through the cache.
    ///
    /// Cold cache ≈ the old single-pass cost + one cheap metadata pass; a fully
    /// warm cache skips pass 2's osascript entirely. Pass `cache: nil`
    /// (`--no-cache`) to force every row to be a miss (live fetch, no cache I/O).
    /// The output borrows only `bodyPreview` from the cache — read/unread and all
    /// other metadata stay live from pass 1 (the cached `read` flag is a stale
    /// snapshot and is never surfaced here).
    static func listMessagesCached(
        account: String? = nil,
        mailbox: String = "INBOX",
        unread: Bool = false,
        limit: Int = 50,
        offset: Int = 0,
        preview: Int,
        after: String? = nil,
        before: String? = nil,
        cache: MailBodyCache? = MailBodyCache.shared,
        softTimeoutMs: Int = SoftTimeout.defaultMs,
        pageSentinel: Bool = false,
        seekingAfter anchor: Cursor.Anchor? = nil
    ) throws -> ListOutcome {
        // Match buildListScript's previewChars clamp ([1, 4000]).
        let previewChars = max(1, min(preview, 4000))
        let crossAccount = (account == nil)
        let pass1 = try listMessages(
            account: account, mailbox: mailbox, unread: unread,
            limit: limit, offset: offset, preview: nil,
            after: after, before: before, softTimeoutMs: softTimeoutMs, pageSentinel: pageSentinel,
            seekingAfter: anchor
        )
        // pippin-521: opt-in summary previews. Config-gated BEFORE the index
        // build — the snapshot copy isn't free, so the default-off path never
        // pays it. (pass 1's own fast-path index was internal to listMessages;
        // one extra snapshot here only on the opt-in path.)
        var summaries: [String: String] = [:]
        if AIProviderFactory.loadConfig()?.mail?.previewFromIndex == true, fastPathEnabled(),
           let index = try? makeFastPathIndex(accountName: account) {
            summaries = indexSummaries(index, for: pass1.messages)
        }
        let assembled = try assemblePreviews(
            metadata: pass1.messages,
            previewChars: previewChars,
            cache: cache,
            summaries: summaries,
            fetchMisses: { ids in
                try batchFetchBodies(ids: ids, crossAccount: crossAccount, softTimeoutMs: softTimeoutMs)
            }
        )
        return ListOutcome(messages: assembled.messages, timedOut: pass1.timedOut || assembled.fetchTimedOut)
    }

    /// Fetch N message bodies in ONE batch osascript (`buildBatchBodiesScript`).
    /// The shared `fetchMisses` implementation for every preview-assembly path
    /// (list, activity, search). Misses fetch bodies via `msg.content()` — same
    /// cost profile as a preview list, so reuse its preview-scaled hard timeout.
    static func batchFetchBodies(
        ids: [String], crossAccount: Bool, softTimeoutMs: Int
    ) throws -> (messages: [MailMessage], timedOut: Bool) {
        guard !ids.isEmpty else { return (messages: [], timedOut: false) }
        let script = buildBatchBodiesScript(compoundIds: ids, softTimeoutMs: softTimeoutMs)
        let json = try runScript(script, timeoutSeconds: mcpHardTimeout(listScanTimeout(
            crossAccount: crossAccount, fetchesBodies: true, softTimeoutMs: softTimeoutMs
        )), idempotent: true)
        let wrapper = try decode(ScanResponse.self, from: json)
        return (messages: wrapper.results, timedOut: wrapper.meta.timedOut)
    }

    /// `mail search --preview N`: fill `bodyPreview` on search hits through the
    /// same cache-first assembly as `mail list --preview`. Priority per hit:
    /// cached body > snippet already captured by a `--body` JXA match (seeded so
    /// it is never refetched) > opt-in index summary (pippin-521) > one batch
    /// osascript for the misses (write-through cache, so a follow-up `mail show`
    /// is free).
    static func attachSearchPreviews(
        _ messages: [MailMessage],
        previewChars: Int,
        account: String?,
        cache: MailBodyCache? = MailBodyCache.shared,
        softTimeoutMs: Int = SoftTimeout.defaultMs
    ) throws -> (messages: [MailMessage], timedOut: Bool) {
        let clamped = max(1, min(previewChars, 4000))
        let crossAccount = (account == nil)
        var seeds: [String: String] = [:]
        for msg in messages {
            if let existing = msg.bodyPreview, !existing.isEmpty { seeds[msg.id] = existing }
        }
        if AIProviderFactory.loadConfig()?.mail?.previewFromIndex == true, fastPathEnabled(),
           let index = try? makeFastPathIndex(accountName: account) {
            seeds.merge(indexSummaries(index, for: messages)) { existing, _ in existing }
        }
        let assembled = try assemblePreviews(
            metadata: messages, previewChars: clamped, cache: cache, summaries: seeds,
            fetchMisses: { ids in
                try batchFetchBodies(ids: ids, crossAccount: crossAccount, softTimeoutMs: softTimeoutMs)
            }
        )
        return (messages: assembled.messages, timedOut: assembled.fetchTimedOut)
    }

    /// Pure assembly step for `listMessagesCached` — no Mail.app, no I/O beyond
    /// the cache and the injected `fetchMisses` closure, so it is unit-testable
    /// with a temp-db cache + a stub fetcher.
    ///
    /// Partitions `metadata` into cache hits (body already cached) and misses,
    /// fetches the miss bodies via `fetchMisses`, writes them through the cache,
    /// then returns the metadata rows with `bodyPreview` filled (cached or fresh
    /// body, truncated by `bodyPreview(_:chars:)`). Order is preserved; a row
    /// whose body is neither cached nor returned (e.g. the fetch timed out before
    /// reaching it) gets no `bodyPreview`.
    ///
    /// `summaries` (pippin-521, opt-in via `mail.previewFromIndex`) supplies
    /// Envelope Index snippet text per compound id: a row that misses the cache
    /// but has a summary takes the (truncated) summary as its preview and is
    /// NOT fetched — deliberately skipping the cache write-through (the summary
    /// is not the body). Priority: cached body > summary > batch fetch.
    static func assemblePreviews(
        metadata: [MailMessage],
        previewChars: Int,
        cache: MailBodyCache?,
        summaries: [String: String] = [:],
        fetchMisses: (_ ids: [String]) throws -> (messages: [MailMessage], timedOut: Bool)
    ) rethrows -> (messages: [MailMessage], fetchTimedOut: Bool) {
        let cached = cache?.getMany(expectedDates: rowDates(metadata)) ?? [:]
        var bodyByID: [String: String] = [:]
        var missIDs: [String] = []
        for msg in metadata {
            if let body = cached[msg.id]?.body, !body.isEmpty {
                bodyByID[msg.id] = body
            } else if let summary = summaries[msg.id] {
                bodyByID[msg.id] = summary
            } else {
                missIDs.append(msg.id)
            }
        }
        let fetched = try fetchMisses(missIDs)
        for fresh in fetched.messages {
            cache?.put(fresh)
            if let body = fresh.body, !body.isEmpty {
                bodyByID[fresh.id] = body
            }
        }
        let assembled = metadata.map { msg in
            msg.withBodyPreview(bodyByID[msg.id].map { bodyPreview($0, chars: previewChars) })
        }
        return (messages: assembled, fetchTimedOut: fetched.timedOut)
    }

    /// Each row's own `date`, keyed by id: the identity a cached body must
    /// match before it may stand in for that row (pippin-pvak).
    static func rowDates(_ rows: [MailMessage]) -> [String: String] {
        Dictionary(rows.map { ($0.id, $0.date) }, uniquingKeysWith: { first, _ in first })
    }

    /// Truncate a body to a preview string, matching the JXA semantics in
    /// `buildListScript` (`s.length > N ? s.substring(0,N) + '…' : s`). JS strings
    /// are UTF-16, so the cut is on UTF-16 code units, not Swift Characters —
    /// keeping the cached-derived preview byte-identical to a JXA-derived one.
    static func bodyPreview(_ body: String, chars: Int) -> String {
        // Walk at most chars+1 UTF-16 units instead of materializing the whole
        // body (bodies run to hundreds of KB; chars clamps to ≤4000). A valid
        // cut index < endIndex means count > chars (truncate); endIndex or nil
        // means count ≤ chars (return whole body) — matching JS `s.length > N`.
        let utf16 = body.utf16
        guard let cut = utf16.index(utf16.startIndex, offsetBy: chars, limitedBy: utf16.endIndex),
              cut != utf16.endIndex
        else { return body }
        return String(decoding: utf16[..<cut], as: UTF16.self) + "…"
    }

    // MARK: - Compound ID Parser

    /// Parse and validate a compound message ID ("account||mailbox||numericId").
    static func parseCompoundId(_ id: String) throws -> (account: String, mailbox: String, messageId: String) {
        let parts = id.components(separatedBy: "||")
        guard parts.count == 3 else {
            throw MailBridgeError.invalidMessageId(id)
        }
        let msgId = parts[2]
        // ASCII digits only: `isNumber` also accepts other scripts' digits and
        // characters like "½", and this value is written into the script unquoted.
        guard !msgId.isEmpty, msgId.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
            throw MailBridgeError.invalidMessageId(id)
        }
        return (parts[0], parts[1], msgId)
    }

    // MARK: - Private Types

    /// Telemetry envelope returned by every JXA scan script. The three call
    /// sites used to define byte-identical types (SearchMeta/ListMeta/
    /// ActivityMeta) — this is the unified Decodable, with aliases below
    /// for the legacy names so tests and any external readers don't churn.
    /// Internal so tests can verify backward-compatible JSON decoding when
    /// older JXA scripts omit the `timedOut` field.
    struct ScanMeta: Decodable {
        let accountsScanned: Int
        let mailboxesScanned: Int
        let messagesExamined: Int
        let timedOut: Bool

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accountsScanned = try container.decode(Int.self, forKey: .accountsScanned)
            mailboxesScanned = try container.decode(Int.self, forKey: .mailboxesScanned)
            messagesExamined = try container.decode(Int.self, forKey: .messagesExamined)
            // Backward-compatible: scripts that don't emit timedOut default to false.
            timedOut = try container.decodeIfPresent(Bool.self, forKey: .timedOut) ?? false
        }

        private enum CodingKeys: String, CodingKey {
            case accountsScanned, mailboxesScanned, messagesExamined, timedOut
        }
    }

    typealias SearchMeta = ScanMeta
    typealias ListMeta = ScanMeta
    typealias ActivityMeta = ScanMeta

    /// JXA result envelope: results + scan telemetry. Same triplet
    /// collapse as `ScanMeta` — Search/List/Activity decoded the same shape.
    struct ScanResponse: Decodable {
        let results: [MailMessage]
        let meta: ScanMeta
    }

    typealias SearchResponse = ScanResponse
    typealias ListResponse = ScanResponse
    typealias ActivityResponse = ScanResponse
}
