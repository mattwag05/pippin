import Foundation

enum MailBridge {
    // MARK: - Public API

    /// Outcome of a list call: messages plus a `timedOut` flag the caller
    /// should surface so the user knows results may be incomplete and how to
    /// narrow the query.
    struct ListOutcome {
        let messages: [MailMessage]
        let timedOut: Bool
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
        let clampedLimit = max(1, min(limit, 500))
        let clampedOffset = max(0, offset)
        let script = buildListScript(
            account: account, mailbox: mailbox, unread: unread,
            limit: clampedLimit, offset: clampedOffset, preview: preview,
            softTimeoutMs: softTimeoutMs
        )
        // The JXA loop self-bounds via softTimeoutMs (default 22s) when preview
        // forces per-message body fetches. ScriptRunner timeout is a hard
        // failsafe well under the 60s MCP runChild cap.
        let timeout = (preview ?? 0) > 0 ? 30 : 10
        let json = try runScript(script, timeoutSeconds: timeout)
        let wrapper = try decode(ListResponse.self, from: json)
        return ListOutcome(messages: wrapper.results, timedOut: wrapper.meta.timedOut)
    }

    /// Outcome of an activity call: same shape as `ListOutcome`, separate type
    /// so it's grep-able and can diverge if activity grows extra metadata.
    struct ActivityOutcome {
        let messages: [MailMessage]
        let timedOut: Bool
    }

    static func listActivity(
        account: String? = nil,
        mailboxes: [String] = ["INBOX", "Sent"],
        since: Date? = nil,
        limit: Int = 50,
        preview: Int? = 200,
        softTimeoutMs: Int = SoftTimeout.defaultMs
    ) throws -> ActivityOutcome {
        let script = buildActivityScript(
            account: account, mailboxes: mailboxes, since: since,
            limit: limit, preview: preview, softTimeoutMs: softTimeoutMs
        )
        // Lowered from 120s — the prior value exceeded the 60s MCP runChild cap
        // so every preview-on activity call was reliably killed before JXA
        // returned. JXA self-bounds via softTimeoutMs (default 22s); 50s gives
        // enough headroom for sort + JSON.stringify after the soft cap fires.
        let timeout = (preview ?? 0) > 0 ? 50 : 30
        let json = try runScript(script, timeoutSeconds: timeout)
        let wrapper = try decode(ActivityResponse.self, from: json)
        return ActivityOutcome(messages: wrapper.results, timedOut: wrapper.meta.timedOut)
    }

    /// Outcome of a search call: the matched messages plus a `timedOut` flag
    /// that callers should surface to the user (text/JSON/agent format) so they
    /// know to narrow the query when results may be incomplete.
    struct SearchOutcome {
        let messages: [MailMessage]
        let timedOut: Bool
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
        softTimeoutMs: Int = 22000
    ) throws -> SearchOutcome {
        let clampedOffset = max(0, offset)
        let script = buildSearchScript(
            query: query, account: account, mailbox: mailbox, searchBody: searchBody,
            limit: limit, offset: clampedOffset, after: after, before: before, to: to,
            softTimeoutMs: softTimeoutMs
        )
        // The JXA loop self-bounds via softTimeoutMs (default 22s) and returns
        // partial results with meta.timedOut=true. ScriptRunner timeout is a
        // hard failsafe slightly above that to allow JSON serialization.
        let json = try runScript(script, timeoutSeconds: 30)
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

    /// Internal so tests can verify backward-compatible JSON decoding when
    /// older JXA scripts omit the `timedOut` field.
    struct SearchMeta: Decodable {
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

    struct SearchResponse: Decodable {
        let results: [MailMessage]
        let meta: SearchMeta
    }

    /// `MailBridge.listMessages` result envelope. Same shape as `SearchMeta`;
    /// kept as a dedicated type so test fixtures and any future divergence
    /// (e.g. list-specific telemetry) stay grep-able.
    struct ListMeta: Decodable {
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

    struct ListResponse: Decodable {
        let results: [MailMessage]
        let meta: ListMeta
    }

    /// `MailBridge.listActivity` result envelope.
    struct ActivityMeta: Decodable {
        let accountsScanned: Int
        let mailboxesScanned: Int
        let messagesExamined: Int
        let timedOut: Bool

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accountsScanned = try container.decode(Int.self, forKey: .accountsScanned)
            mailboxesScanned = try container.decode(Int.self, forKey: .mailboxesScanned)
            messagesExamined = try container.decode(Int.self, forKey: .messagesExamined)
            timedOut = try container.decodeIfPresent(Bool.self, forKey: .timedOut) ?? false
        }

        private enum CodingKeys: String, CodingKey {
            case accountsScanned, mailboxesScanned, messagesExamined, timedOut
        }
    }

    struct ActivityResponse: Decodable {
        let results: [MailMessage]
        let meta: ActivityMeta
    }
}
