import Foundation

public enum MessagesSendError: LocalizedError, Sendable {
    case timeout
    case scriptFailed(String)
    case phiFiltered([String])
    case recipientNotAllowed(String)
    case autonomousNotAuthorized

    public var errorDescription: String? {
        switch self {
        case .timeout:
            return "Messages send timed out."
        case let .scriptFailed(msg):
            return "Messages send failed: \(msg)"
        case let .phiFiltered(cats):
            return "Refusing to send — body matched guardrails: \(cats.joined(separator: ", "))"
        case let .recipientNotAllowed(who):
            return "Recipient not in autonomous allowlist: \(who)"
        case .autonomousNotAuthorized:
            return "Autonomous send requires PIPPIN_AUTONOMOUS_MESSAGES=1 and --autonomous flag."
        }
    }
}

/// Sends via Messages.app JXA. The only non-test caller is
/// MessagesCommand.Send; everything else routes through draft mode. The
/// triple gate (env + allowlist + flag) is enforced at the command layer
/// before this function is called — this layer only runs the PHI scan
/// and the script.
public enum MessagesSender {
    public struct SendResult: Sendable, Equatable {
        public let delivered: Bool
        public let detail: String
    }

    /// Drives `send.messages`. `buddyOrChatId` accepts either a handle
    /// (e.g. `+15551234567`) for DMs or a chat GUID for group threads.
    ///
    /// The caller (``MessagesCommand.Send``) is responsible for PHI filtering
    /// before calling this function. The triple-gate (env + allowlist + flag)
    /// is also enforced at the command layer.
    public static func send(
        to buddyOrChatId: String,
        body: String,
        timeoutSeconds: Int = 15,
        runner: @Sendable (String, Int) throws -> String = { script, timeout in
            try ScriptRunner.run(script, timeoutSeconds: timeout, appName: "Messages")
        }
    ) throws -> SendResult {
        let script = buildScript(recipient: buddyOrChatId, body: body)
        do {
            let out = try runner(script, timeoutSeconds)
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return SendResult(delivered: true, detail: trimmed.isEmpty ? "sent" : trimmed)
        } catch ScriptRunnerError.timeout {
            throw MessagesSendError.timeout
        } catch let ScriptRunnerError.nonZeroExit(msg) {
            throw MessagesSendError.scriptFailed(msg)
        } catch let ScriptRunnerError.stderrOnSuccess(msg) {
            throw MessagesSendError.scriptFailed(msg)
        } catch let ScriptRunnerError.launchFailed(msg) {
            throw MessagesSendError.scriptFailed("osascript launch failed: \(msg)")
        }
    }

    static func buildScript(recipient: String, body: String) -> String {
        let escapedRecipient = jsEscape(recipient)
        let escapedBody = jsEscape(body)
        return """
        const app = Application('Messages');
        app.includeStandardAdditions = true;
        const target = '\(escapedRecipient)';
        const body = '\(escapedBody)';
        let buddy;
        try {
            buddy = app.buddies.byId(target);
            buddy.id();
        } catch (_) {
            try {
                buddy = app.chats.byId(target);
                buddy.id();
            } catch (e2) {
                buddy = app.textChats.whose({id: target})[0];
            }
        }
        app.send(body, {to: buddy});
        'ok';
        """
    }

    private static func jsEscape(_ s: String) -> String {
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
}
