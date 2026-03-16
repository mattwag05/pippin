import Foundation

enum MailBridge {
    // MARK: - Public API

    static func listMessages(
        account: String? = nil,
        mailbox: String = "INBOX",
        unread: Bool = false,
        limit: Int = 50,
        offset: Int = 0
    ) throws -> [MailMessage] {
        let clampedLimit = max(1, min(limit, 500))
        let clampedOffset = max(0, offset)
        let script = buildListScript(account: account, mailbox: mailbox, unread: unread, limit: clampedLimit, offset: clampedOffset)
        let json = try runScript(script)
        return try decode([MailMessage].self, from: json)
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
        verbose: Bool = false
    ) throws -> [MailMessage] {
        let clampedOffset = max(0, offset)
        let script = buildSearchScript(
            query: query, account: account, mailbox: mailbox, searchBody: searchBody,
            limit: limit, offset: clampedOffset, after: after, before: before, to: to
        )
        // Search scans all mailboxes — use 60s timeout to accommodate large inboxes
        let json = try runScript(script, timeoutSeconds: 60)
        let wrapper = try decode(SearchResponse.self, from: json)
        if verbose {
            let stderr = FileHandle.standardError
            let meta = wrapper.meta
            let lines = [
                "[search] accounts scanned: \(meta.accountsScanned)",
                "[search] mailboxes scanned: \(meta.mailboxesScanned)",
                "[search] messages examined: \(meta.messagesExamined)",
                "[search] body search: \(searchBody ? "on" : "off (use --body to search message content)")",
            ]
            for line in lines {
                stderr.write(Data((line + "\n").utf8))
            }
        }
        return wrapper.results
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
        let json = try runScript(script, timeoutSeconds: 30)
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
        let json = try runScript(script)
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

    private struct SearchMeta: Decodable {
        let accountsScanned: Int
        let mailboxesScanned: Int
        let messagesExamined: Int
    }

    private struct SearchResponse: Decodable {
        let results: [MailMessage]
        let meta: SearchMeta
    }
}
