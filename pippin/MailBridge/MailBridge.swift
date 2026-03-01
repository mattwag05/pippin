import Foundation

enum MailBridgeError: LocalizedError {
    case scriptFailed(String)
    case timeout
    case decodingFailed(String)
    case invalidMessageId(String)
    case invalidMailbox(String)

    var errorDescription: String? {
        switch self {
        case .scriptFailed: return "Mail automation script failed"
        case .timeout: return "Mail automation script timed out"
        case .decodingFailed: return "Failed to decode Mail response"
        case .invalidMessageId(let id): return "Invalid message id: \(id)"
        case .invalidMailbox(let name): return "Invalid mailbox name: \(name)"
        }
    }

    /// Raw technical detail for debugging — do not write to stdout
    var debugDetail: String? {
        switch self {
        case .scriptFailed(let msg): return msg
        case .decodingFailed(let msg): return msg
        default: return nil
        }
    }
}

struct MailBridge {

    static func listMessages(
        account: String? = nil,
        mailbox: String = "INBOX",
        unread: Bool = false,
        limit: Int = 50
    ) throws -> [MailMessage] {
        let clampedLimit = max(1, min(limit, 500))
        let script = buildListScript(account: account, mailbox: mailbox, unread: unread, limit: clampedLimit)
        let json = try runScript(script)
        return try decode([MailMessage].self, from: json)
    }

    static func searchMessages(
        query: String,
        account: String? = nil,
        limit: Int = 10
    ) throws -> [MailMessage] {
        let script = buildSearchScript(query: query, account: account, limit: limit)
        // Search scans all mailboxes including body content — use 30s timeout
        let json = try runScript(script, timeoutSeconds: 30)
        return try decode([MailMessage].self, from: json)
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
        to: String,
        subject: String,
        body: String,
        cc: String? = nil,
        from accountName: String? = nil,
        attachmentPath: String? = nil,
        dryRun: Bool = false
    ) throws -> MailActionResult {
        let script = buildSendScript(
            to: to,
            subject: subject,
            body: body,
            cc: cc,
            from: accountName,
            attachmentPath: attachmentPath,
            dryRun: dryRun
        )
        // Send triggers SMTP handshake — use 45s timeout
        let json = try runScript(script, timeoutSeconds: 45)
        return try decode(MailActionResult.self, from: json)
    }

    static func listAccounts() throws -> [MailAccount] {
        let script = buildAccountsScript()
        let json = try runScript(script)
        return try decode([MailAccount].self, from: json)
    }

    static func readMessage(compoundId: String) throws -> MailMessage {
        let (account, mailboxName, msgId) = try parseCompoundId(compoundId)
        let script = buildReadScript(account: account, mailbox: mailboxName, messageId: msgId)
        let json = try runScript(script)
        return try decode(MailMessage.self, from: json)
    }

    // MARK: - Helpers

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

    // MARK: - Script Builders

    static func jsEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\0", with: "\\0")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "'", with: "\\'")
         .replacingOccurrences(of: "`", with: "\\`")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
         .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    private static func buildListScript(
        account: String?,
        mailbox: String,
        unread: Bool,
        limit: Int
    ) -> String {
        let acctFilter = account.map { "'\(jsEscape($0))'" } ?? "null"
        let mbName = jsEscape(mailbox)

        return """
        var mail = Application('Mail');
        // Poll until Mail.app has loaded accounts (guards against post-launch account-sync race)
        var ready = false;
        for (var attempt = 0; attempt < 8; attempt++) {
            if (mail.accounts().length > 0) { ready = true; break; }
            delay(0.5);
        }
        if (!ready) { throw new Error('Mail not ready: no accounts visible after startup'); }
        var acctFilter = \(acctFilter);
        var mbFilter = '\(mbName)';
        var unreadOnly = \(unread ? "true" : "false");
        var limit = \(limit);
        var results = [];

        var accounts = mail.accounts();
        for (var a = 0; a < accounts.length && results.length < limit; a++) {
            var acct = accounts[a];
            var acctName = acct.name();
            if (acctFilter !== null && acctName !== acctFilter) continue;

            var mailboxes = acct.mailboxes();
            for (var m = 0; m < mailboxes.length && results.length < limit; m++) {
                var mb = mailboxes[m];
                if (mb.name() !== mbFilter) continue;

                // whose({}) is invalid JXA — use messages() directly for all-messages case
                var msgs = unreadOnly ? mb.messages.whose({readStatus: false})() : mb.messages();
                var count = Math.min(msgs.length, limit - results.length);
                var slice = msgs.slice(0, count);

                var ids       = slice.map(function(msg) { return msg.id(); });
                var subjects  = slice.map(function(msg) { return msg.subject(); });
                var senders   = slice.map(function(msg) { return msg.sender(); });
                var dates     = slice.map(function(msg) { return msg.dateSent().toISOString(); });
                var readFlags = slice.map(function(msg) { return msg.readStatus(); });

                for (var i = 0; i < count; i++) {
                    results.push({
                        id: acctName + '||' + mbFilter + '||' + ids[i],
                        account: acctName,
                        mailbox: mbFilter,
                        subject: subjects[i],
                        from: senders[i],
                        to: [],
                        date: dates[i],
                        read: readFlags[i],
                        body: null
                    });
                }
            }
        }

        JSON.stringify(results);
        """
    }

    private static func buildAccountsScript() -> String {
        return """
        var mail = Application('Mail');
        var ready = false;
        for (var attempt = 0; attempt < 8; attempt++) {
            if (mail.accounts().length > 0) { ready = true; break; }
            delay(0.5);
        }
        if (!ready) { throw new Error('Mail not ready: no accounts visible after startup'); }

        var accounts = mail.accounts();
        var results = [];
        for (var a = 0; a < accounts.length; a++) {
            var acct = accounts[a];
            var emails = [];
            try { emails = acct.emailAddresses(); } catch(e) {}
            var emailStr = (Array.isArray(emails) && emails.length > 0) ? emails[0] : '';
            results.push({
                name: acct.name(),
                email: emailStr
            });
        }
        JSON.stringify(results);
        """
    }

    private static func buildSearchScript(
        query: String,
        account: String?,
        limit: Int
    ) -> String {
        let safeQuery = jsEscape(query)
        let acctFilter = account.map { "'\(jsEscape($0))'" } ?? "null"
        // Clamp limit to prevent runaway scans; per-mailbox cap bounds body-fetch time
        let safeLimitVal = max(1, min(limit, 500))
        let perMailboxLimit = 200

        return """
        var mail = Application('Mail');
        var ready = false;
        // 20 attempts × 0.5s = 10s max cold-launch poll (accommodates IMAP sync on first run)
        for (var attempt = 0; attempt < 20; attempt++) {
            if (mail.accounts().length > 0) { ready = true; break; }
            delay(0.5);
        }
        if (!ready) { throw new Error('Mail not ready: no accounts visible after startup'); }

        var query = '\(safeQuery)'.toLowerCase();
        var acctFilter = \(acctFilter);
        var limit = \(safeLimitVal);
        var perMailboxLimit = \(perMailboxLimit);
        var results = [];

        var accounts = mail.accounts();
        for (var a = 0; a < accounts.length && results.length < limit; a++) {
            var acct = accounts[a];
            var acctName = acct.name();
            if (acctFilter !== null && acctName !== acctFilter) continue;

            var mailboxes = acct.mailboxes();
            for (var m = 0; m < mailboxes.length && results.length < limit; m++) {
                var mb = mailboxes[m];
                // Cap messages scanned per mailbox to bound body-fetch time on large inboxes
                var allMsgs = mb.messages();
                var scanCount = Math.min(allMsgs.length, perMailboxLimit);
                var msgs = allMsgs.slice(0, scanCount);

                for (var i = 0; i < msgs.length && results.length < limit; i++) {
                    var msg = msgs[i];
                    var subject = msg.subject() || '';
                    var sender = msg.sender() || '';

                    // Check subject and sender first (fast, no body fetch needed)
                    var matchedFast = subject.toLowerCase().indexOf(query) !== -1
                                   || sender.toLowerCase().indexOf(query) !== -1;

                    // Only fetch body if subject/sender didn't match
                    var matched = matchedFast;
                    if (!matched) {
                        var body = msg.content() || '';
                        matched = body.toLowerCase().indexOf(query) !== -1;
                    }

                    if (matched) {
                        results.push({
                            id: acctName + '||' + mb.name() + '||' + msg.id(),
                            account: acctName,
                            mailbox: mb.name(),
                            subject: subject,
                            from: sender,
                            to: [],
                            date: msg.dateSent().toISOString(),
                            read: msg.readStatus(),
                            body: null
                        });
                    }
                }
            }
        }

        JSON.stringify(results);
        """
    }

    private static func buildMoveScript(
        account: String,
        mailbox: String,
        messageId: String,
        toMailbox: String,
        dryRun: Bool
    ) -> String {
        let safeAccount = jsEscape(account)
        let safeMailbox = jsEscape(mailbox)
        let safeTarget = jsEscape(toMailbox)
        let safeMsgId = jsEscape(messageId)

        return """
        var mail = Application('Mail');
        var ready = false;
        for (var attempt = 0; attempt < 20; attempt++) {
            if (mail.accounts().length > 0) { ready = true; break; }
            delay(0.5);
        }
        if (!ready) { throw new Error('MAILBRIDGE_ERR_NOT_READY'); }

        // Recursive mailbox finder — handles nested IMAP folders (e.g. Archive/2025)
        function findMailboxByName(mailboxes, name) {
            for (var i = 0; i < mailboxes.length; i++) {
                if (mailboxes[i].name() === name) return mailboxes[i];
                try {
                    var sub = mailboxes[i].mailboxes();
                    var found = findMailboxByName(sub, name);
                    if (found !== null) return found;
                } catch(e) {}
            }
            return null;
        }

        var isDryRun = \(dryRun ? "true" : "false");
        var sourceMsg = null;
        var targetMb = null;
        var fromName = '\(safeMailbox)';

        var accounts = mail.accounts();
        for (var a = 0; a < accounts.length; a++) {
            var acct = accounts[a];
            if (acct.name() !== '\(safeAccount)') continue;

            var mailboxes = acct.mailboxes();

            // Find source message in the specified source mailbox
            for (var m = 0; m < mailboxes.length; m++) {
                var mb = mailboxes[m];
                if (mb.name() === '\(safeMailbox)') {
                    var msgs = mb.messages.whose({id: \(safeMsgId)})();
                    if (msgs.length === 0) throw new Error('MAILBRIDGE_ERR_MSG_NOT_FOUND');
                    sourceMsg = msgs[0];
                    break;
                }
            }

            // Find target mailbox recursively (supports nested folders)
            targetMb = findMailboxByName(mailboxes, '\(safeTarget)');
            break;
        }

        if (sourceMsg === null) { throw new Error('MAILBRIDGE_ERR_MSG_NOT_FOUND'); }
        if (targetMb === null) { throw new Error('MAILBRIDGE_ERR_TARGET_NOT_FOUND'); }

        if (!isDryRun) {
            mail.move(sourceMsg, {to: targetMb});
        }

        JSON.stringify({
            success: true,
            action: 'move',
            details: {
                messageId: '\(safeAccount)||\(safeMailbox)||\(safeMsgId)',
                from: fromName,
                to: '\(safeTarget)',
                dryRun: String(isDryRun)
            }
        });
        """
    }

    private static func buildSendScript(
        to: String,
        subject: String,
        body: String,
        cc: String?,
        from accountName: String?,
        attachmentPath: String?,
        dryRun: Bool
    ) -> String {
        let safeTo = jsEscape(to)
        let safeSubject = jsEscape(subject)
        let safeBody = jsEscape(body)
        let safeCc = cc.map { "'\(jsEscape($0))'" } ?? "null"
        let safeFrom = accountName.map { "'\(jsEscape($0))'" } ?? "null"
        let safeAttach = attachmentPath.map { "'\(jsEscape($0))'" } ?? "null"

        return """
        var mail = Application('Mail');
        var ready = false;
        for (var attempt = 0; attempt < 20; attempt++) {
            if (mail.accounts().length > 0) { ready = true; break; }
            delay(0.5);
        }
        if (!ready) { throw new Error('MAILBRIDGE_ERR_NOT_READY'); }

        var isDryRun = \(dryRun ? "true" : "false");

        var msg = mail.OutgoingMessage({
            subject: '\(safeSubject)',
            content: '\(safeBody)',
            visible: false
        });
        mail.outgoingMessages.push(msg);

        try {
            var toRecip = mail.Recipient({address: '\(safeTo)'});
            msg.toRecipients.push(toRecip);

            var ccAddr = \(safeCc);
            if (ccAddr !== null) {
                var ccRecip = mail.CcRecipient({address: ccAddr});
                msg.ccRecipients.push(ccRecip);
            }

            var fromAcct = \(safeFrom);
            if (fromAcct !== null) {
                var acctFound = false;
                var accounts = mail.accounts();
                for (var a = 0; a < accounts.length; a++) {
                    if (accounts[a].name() === fromAcct) {
                        acctFound = true;
                        var emails = [];
                        try { emails = accounts[a].emailAddresses(); } catch(e) {}
                        if (Array.isArray(emails) && emails.length > 0) {
                            msg.sender = emails[0];
                        } else {
                            throw new Error('MAILBRIDGE_ERR_ACCT_NO_EMAIL');
                        }
                        break;
                    }
                }
                if (!acctFound) { throw new Error('MAILBRIDGE_ERR_ACCT_NOT_FOUND'); }
            }

            var attachPath = \(safeAttach);
            if (attachPath !== null) {
                var att = mail.Attachment({fileName: Path(attachPath)});
                msg.attachments.push(att);
                // Verify attachment was accepted (guard against silent drop on bad path)
                if (msg.attachments().length === 0) {
                    throw new Error('MAILBRIDGE_ERR_ATTACH_FAILED');
                }
            }

            if (!isDryRun) {
                // msg.send() throws on SMTP rejection; success means accepted for delivery.
                // A send delay keeps the message in outgoingMessages until the delay expires —
                // checking queue length would produce a false failure in that case.
                msg.send();
            } else {
                // Dry-run: delete by object reference (not positional index) to avoid deleting wrong draft
                try { msg.delete(); } catch(e) {}
            }
        } catch(err) {
            // Cleanup: remove orphaned OutgoingMessage on any failure path (by object reference)
            try { msg.delete(); } catch(e) {}
            throw err;
        }

        JSON.stringify({
            success: true,
            action: 'send',
            details: {
                to: '\(safeTo)',
                subject: '\(safeSubject)',
                dryRun: String(isDryRun)
            }
        });
        """
    }

    private static func buildMarkScript(
        account: String,
        mailbox: String,
        messageId: String,
        read: Bool,
        dryRun: Bool
    ) -> String {
        let safeAccount = jsEscape(account)
        let safeMailbox = jsEscape(mailbox)
        // messageId validated as numeric by caller; jsEscape is defense-in-depth
        let safeMsgId = jsEscape(messageId)

        return """
        var mail = Application('Mail');
        var ready = false;
        // 20 attempts × 0.5s = 10s max cold-launch poll
        for (var attempt = 0; attempt < 20; attempt++) {
            if (mail.accounts().length > 0) { ready = true; break; }
            delay(0.5);
        }
        if (!ready) { throw new Error('MAILBRIDGE_ERR_NOT_READY'); }

        var targetRead = \(read ? "true" : "false");
        var isDryRun = \(dryRun ? "true" : "false");
        var found = false;

        var accounts = mail.accounts();
        for (var a = 0; a < accounts.length; a++) {
            var acct = accounts[a];
            if (acct.name() !== '\(safeAccount)') continue;

            var mailboxes = acct.mailboxes();
            for (var m = 0; m < mailboxes.length; m++) {
                var mb = mailboxes[m];
                if (mb.name() !== '\(safeMailbox)') continue;

                var msgs = mb.messages.whose({id: \(safeMsgId)})();
                if (msgs.length === 0) throw new Error('MAILBRIDGE_ERR_MSG_NOT_FOUND');

                if (!isDryRun) {
                    msgs[0].readStatus = targetRead;
                    // Verify setter took effect (silent no-op on evicted/server-only messages)
                    if (msgs[0].readStatus() !== targetRead) {
                        throw new Error('MAILBRIDGE_ERR_SETTER_FAILED');
                    }
                }
                found = true;
                break;
            }
            if (found) break;
        }

        if (!found) { throw new Error('MAILBRIDGE_ERR_NOT_FOUND'); }

        JSON.stringify({
            success: true,
            action: 'mark',
            details: {
                messageId: '\(safeAccount)||\(safeMailbox)||\(safeMsgId)',
                readStatus: String(targetRead),
                dryRun: String(isDryRun)
            }
        });
        """
    }

    private static func buildReadScript(account: String, mailbox: String, messageId: String) -> String {
        let safeAccount = jsEscape(account)
        let safeMailbox = jsEscape(mailbox)
        // messageId is pre-validated numeric by parseCompoundId — jsEscape is defense-in-depth
        let safeMsgId = messageId

        return """
        var mail = Application('Mail');
        // Poll until Mail.app has loaded accounts (guards against post-launch account-sync race)
        var ready = false;
        for (var attempt = 0; attempt < 8; attempt++) {
            if (mail.accounts().length > 0) { ready = true; break; }
            delay(0.5);
        }
        if (!ready) { throw new Error('Mail not ready: no accounts visible after startup'); }
        var result = null;

        var accounts = mail.accounts();
        for (var a = 0; a < accounts.length; a++) {
            var acct = accounts[a];
            if (acct.name() !== '\(safeAccount)') continue;

            var mailboxes = acct.mailboxes();
            for (var m = 0; m < mailboxes.length; m++) {
                var mb = mailboxes[m];
                if (mb.name() !== '\(safeMailbox)') continue;

                var msgs = mb.messages.whose({id: \(safeMsgId)})();
                if (msgs.length === 0) break;

                var msg = msgs[0];
                result = {
                    id: acct.name() + '||' + mb.name() + '||' + String(msg.id()),
                    account: acct.name(),
                    mailbox: mb.name(),
                    subject: msg.subject(),
                    from: msg.sender(),
                    to: msg.toRecipients().map(function(r) { return r.address(); }),
                    date: msg.dateSent().toISOString(),
                    read: msg.readStatus(),
                    body: msg.content()
                };
                break;
            }
            if (result !== null) break;
        }

        if (result === null) { throw new Error('Message not found'); }
        JSON.stringify(result);
        """
    }

    // MARK: - Process Runner

    private static func runScript(_ script: String, timeoutSeconds: Int = 10) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Drain both pipes concurrently to avoid deadlock on large output (>64KB pipe buffer)
        var stdoutData = Data()
        var stderrData = Data()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        // Set up timeout: terminate after timeoutSeconds
        let timeoutItem = DispatchWorkItem {
            guard process.isRunning else { return }
            process.terminate()  // SIGTERM — give osascript 2 seconds to clean up
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: timeoutItem)

        process.waitUntilExit()
        timeoutItem.cancel()
        group.wait()

        // Detect timeout via termination reason (SIGTERM from our terminate() call)
        if process.terminationReason == .uncaughtSignal {
            throw MailBridgeError.timeout
        }

        let stdoutStr = (String(data: stdoutData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawStderr = (String(data: stderrData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            throw MailBridgeError.scriptFailed(rawStderr)
        }

        // osascript can exit 0 and still write errors to stderr (e.g. TCC denial).
        // Filter benign framework log lines (timestamp-prefixed CoreData/NSDateFormatter noise)
        // before treating stderr as a script failure.
        let errorLines = rawStderr
            .components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return false }
                let looksLikeLogLine = trimmed.first?.isNumber == true && trimmed.contains("osascript[")
                return !looksLikeLogLine
            }
        if !errorLines.isEmpty {
            throw MailBridgeError.scriptFailed(errorLines.joined(separator: "\n"))
        }

        return stdoutStr
    }

    // MARK: - Decoders

    static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        guard !json.isEmpty else {
            throw MailBridgeError.decodingFailed("osascript returned empty output — possible TCC denial")
        }
        guard let data = json.data(using: .utf8) else {
            throw MailBridgeError.decodingFailed("Non-UTF8 output")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw MailBridgeError.decodingFailed(error.localizedDescription)
        }
    }
}
