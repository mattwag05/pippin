import Foundation

enum MailBridgeError: LocalizedError {
    case scriptFailed(String)
    case timeout
    case decodingFailed(String)
    case invalidMessageId(String)

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let msg): return "osascript error: \(msg)"
        case .timeout: return "osascript timed out (>10s)"
        case .decodingFailed(let msg): return "JSON decode failed: \(msg)"
        case .invalidMessageId(let id): return "Invalid message id format: \(id)"
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
        let script = buildReadScript(account: account, mailbox: mailboxName, messageId: msgId)
        let json = try runScript(script)
        return try decodeMessage(from: json)
    }

    // MARK: - Script Builders

    private static func jsEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "'", with: "\\'")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
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

    private static func buildReadScript(account: String, mailbox: String, messageId: String) -> String {
        let safeAccount = jsEscape(account)
        let safeMailbox = jsEscape(mailbox)
        // messageId should be an integer string — validate before embedding
        let safeMsgId = messageId.allSatisfy({ $0.isNumber }) ? messageId : "0"

        return """
        var mail = Application('Mail');
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
                    id: '\(safeAccount)||\(safeMailbox)||\(safeMsgId)',
                    account: '\(safeAccount)',
                    mailbox: '\(safeMailbox)',
                    subject: msg.subject(),
                    from: msg.sender(),
                    to: [],
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

        var timedOut = false
        let deadline = DispatchTime.now() + .seconds(10)
        DispatchQueue.global().asyncAfter(deadline: deadline) {
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
        }
        process.waitUntilExit()

        if timedOut { throw MailBridgeError.timeout }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

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
