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
        _ = try runScript(script, timeoutSeconds: mcpHardTimeout(55))
    }

    static func listMessages(
        account: String? = nil,
        mailbox: String = "INBOX",
        unread: Bool = false,
        limit: Int = 50,
        offset: Int = 0,
        preview: Int? = nil,
        softTimeoutMs: Int = SoftTimeout.defaultMs
    ) throws -> ListOutcome {
        let crossAccount = (account == nil)
        let clampedLimit = max(1, min(limit, 500))
        let clampedOffset = max(0, offset)
        let script = buildListScript(
            account: account, mailbox: mailbox, unread: unread,
            limit: clampedLimit, offset: clampedOffset, preview: preview,
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
        let baseTimeout = crossAccount ? 60 : 10
        let timeout = (preview ?? 0) > 0 ? baseTimeout + 40 : baseTimeout
        let json = try runScript(script, timeoutSeconds: mcpHardTimeout(timeout))
        let wrapper = try decode(ListResponse.self, from: json)
        return ListOutcome(messages: wrapper.results, timedOut: wrapper.meta.timedOut)
    }

    static func listActivity(
        account: String? = nil,
        mailboxes: [String] = ["INBOX", "Sent"],
        since: Date? = nil,
        limit: Int = 50,
        preview: Int? = 200,
        softTimeoutMs: Int = SoftTimeout.defaultMs
    ) throws -> ActivityOutcome {
        let crossAccount = (account == nil)
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
        let json = try runScript(script, timeoutSeconds: mcpHardTimeout(timeout))
        let wrapper = try decode(ActivityResponse.self, from: json)
        return ActivityOutcome(messages: wrapper.results, timedOut: wrapper.meta.timedOut)
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
        verbose: Bool = false,
        softTimeoutMs: Int = SoftTimeout.defaultMs
    ) throws -> SearchOutcome {
        let crossAccount = (account == nil) && (mailbox == nil)
        let clampedOffset = max(0, offset)
        let script = buildSearchScript(
            query: query, account: account, mailbox: mailbox, searchBody: searchBody,
            limit: limit, offset: clampedOffset, after: after, before: before, to: to,
            softTimeoutMs: softTimeoutMs
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
        let json = try runScript(script, timeoutSeconds: mcpHardTimeout(timeout))
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
        return SearchOutcome(messages: wrapper.results, timedOut: wrapper.meta.timedOut)
    }

    static func markMessage(
        compoundId: String,
        read: Bool,
        dryRun: Bool = false
    ) throws -> MailActionResult {
        let (account, mailboxName, msgId) = try parseCompoundId(compoundId)
        let script = buildMarkScript(account: account, mailbox: mailboxName, messageId: msgId, read: read, dryRun: dryRun)
        // Write operation: use 20s timeout to accommodate cold Mail launch + IMAP round-trip
        let json = try runScript(script, timeoutSeconds: 20)
        return try decode(MailActionResult.self, from: json)
    }

    static func moveMessage(
        compoundId: String,
        toMailbox: String,
        dryRun: Bool = false
    ) throws -> MailActionResult {
        let (account, mailboxName, msgId) = try parseCompoundId(compoundId)
        guard toMailbox.count <= 256, toMailbox.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else {
            throw MailBridgeError.invalidMailbox(toMailbox)
        }
        let script = buildMoveScript(account: account, mailbox: mailboxName, messageId: msgId, toMailbox: toMailbox, dryRun: dryRun)
        // Move triggers IMAP MOVE server-side — use 45s timeout for slow servers
        let json = try runScript(script, timeoutSeconds: 45)
        return try decode(MailActionResult.self, from: json)
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
    ) throws -> MailActionResult {
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
        let json = try runScript(script, timeoutSeconds: 45)
        return try decode(MailActionResult.self, from: json)
    }

    static func listAttachments(compoundId: String, saveDir: String? = nil) throws -> [Attachment] {
        let (account, mailboxName, msgId) = try parseCompoundId(compoundId)
        let script = buildSaveAttachmentsScript(account: account, mailbox: mailboxName, messageId: msgId, saveDir: saveDir)
        // Gmail label fallback scans every mailbox for the id + IMAP body download for
        // attachment enumeration; 30s was insufficient on large accounts.
        let json = try runScript(script, timeoutSeconds: 90)
        return try decode([Attachment].self, from: json)
    }

    static func replyToMessage(
        compoundId: String,
        body: String,
        to overrideTo: [String]? = nil,
        cc: [String] = [],
        bcc: [String] = [],
        from accountName: String? = nil,
        attachmentPaths: [String] = [],
        dryRun: Bool = false
    ) throws -> MailActionResult {
        let original = try readMessage(compoundId: compoundId)
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
        let json = try runScript(script, timeoutSeconds: 45)
        return try decode(MailActionResult.self, from: json)
    }

    static func forwardMessage(
        compoundId: String,
        to: [String],
        body: String = "",
        cc: [String] = [],
        bcc: [String] = [],
        from accountName: String? = nil,
        attachmentPaths: [String] = [],
        dryRun: Bool = false
    ) throws -> MailActionResult {
        let original = try readMessage(compoundId: compoundId)
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
        let json = try runScript(script, timeoutSeconds: 45)
        return try decode(MailActionResult.self, from: json)
    }

    static func listAccounts() throws -> [MailAccount] {
        let script = buildAccountsScript()
        let json = try runScript(script)
        return try decode([MailAccount].self, from: json)
    }

    static func listMailboxes(account: String? = nil) throws -> [Mailbox] {
        let script = buildMailboxesScript(account: account)
        let json = try runScript(script)
        return try decode([Mailbox].self, from: json)
    }

    static func readMessage(compoundId: String) throws -> MailMessage {
        let (account, mailboxName, msgId) = try parseCompoundId(compoundId)
        let script = buildReadScript(account: account, mailbox: mailboxName, messageId: msgId)
        // Large messages with attachments trigger a full IMAP body download via msg.content();
        // 10s default times out on multi-hundred-KB messages. 45s matches send/move timeouts.
        let json = try runScript(script, timeoutSeconds: 45)
        return try decode(MailMessage.self, from: json)
    }

    // MARK: - Compound ID Parser

    /// Parse and validate a compound message ID ("account||mailbox||numericId").
    static func parseCompoundId(_ id: String) throws -> (account: String, mailbox: String, messageId: String) {
        let parts = id.components(separatedBy: "||")
        guard parts.count == 3 else {
            throw MailBridgeError.invalidMessageId(id)
        }
        let msgId = parts[2]
        guard !msgId.isEmpty, msgId.allSatisfy({ $0.isNumber }) else {
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
