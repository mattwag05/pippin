import Foundation

enum MailBridgeError: LocalizedError {
    case scriptFailed(String)
    case timeout
    case decodingFailed(String)
    case invalidMessageId(String)

    var errorDescription: String? {
        switch self {
        case .scriptFailed: return "Mail automation script failed"
        case .timeout: return "Mail automation script timed out"
        case .decodingFailed: return "Failed to decode Mail response"
        case .invalidMessageId(let id): return "Invalid message id: \(id)"
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
        let script = buildListScript(account: account, mailbox: mailbox, unread: unread, limit: limit)
        let json = try runScript(script)
        return try decodeMessages(from: json)
    }

    static func readMessage(compoundId: String) throws -> MailMessage {
        let parts = compoundId.components(separatedBy: "||")
        guard parts.count == 3 else {
            throw MailBridgeError.invalidMessageId(compoundId)
        }
        let account = parts[0]
        let mailboxName = parts[1]
        let msgId = parts[2]
        let script = try buildReadScript(account: account, mailbox: mailboxName, messageId: msgId)
        let json = try runScript(script)
        return try decodeMessage(from: json)
    }

    // MARK: - Script Builders

    private static func jsEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
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

                var filter = unreadOnly ? {readStatus: false} : {};
                var msgs = mb.messages.whose(filter)();
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

    private static func buildReadScript(account: String, mailbox: String, messageId: String) throws -> String {
        let safeAccount = jsEscape(account)
        let safeMailbox = jsEscape(mailbox)
        // messageId must be an integer string — throw rather than substitute a fallback
        guard !messageId.isEmpty, messageId.allSatisfy({ $0.isNumber }) else {
            throw MailBridgeError.invalidMessageId(messageId)
        }
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

    private static func runScript(_ script: String) throws -> String {
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

        // Set up timeout: terminate after 10 seconds
        let timeoutItem = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(10), execute: timeoutItem)

        process.waitUntilExit()
        timeoutItem.cancel()
        group.wait()

        // Detect timeout via termination reason (SIGTERM from our terminate() call)
        if process.terminationReason == .uncaughtSignal {
            throw MailBridgeError.timeout
        }

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw MailBridgeError.scriptFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Decoders

    private static func decodeMessages(from json: String) throws -> [MailMessage] {
        guard let data = json.data(using: .utf8) else {
            throw MailBridgeError.decodingFailed("Non-UTF8 output")
        }
        do {
            return try JSONDecoder().decode([MailMessage].self, from: data)
        } catch {
            throw MailBridgeError.decodingFailed(error.localizedDescription)
        }
    }

    private static func decodeMessage(from json: String) throws -> MailMessage {
        guard let data = json.data(using: .utf8) else {
            throw MailBridgeError.decodingFailed("Non-UTF8 output")
        }
        do {
            return try JSONDecoder().decode(MailMessage.self, from: data)
        } catch {
            throw MailBridgeError.decodingFailed(error.localizedDescription)
        }
    }
}
