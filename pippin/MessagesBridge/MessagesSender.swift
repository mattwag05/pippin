import Foundation

public enum MessagesSendError: LocalizedError, Sendable {
    case timeout
    case scriptFailed(String)
    case phiFiltered([String])
    case recipientNotAllowed(String)
    case autonomousNotAuthorized
    case accessDenied
    /// The attempt line could not be written, so the send was not started.
    case auditLogUnavailable(path: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .timeout:
            return "The send timed out and may or may not have been delivered. Check the conversation before sending again."
        case let .scriptFailed(msg):
            return "Messages send failed: \(msg)"
        case let .phiFiltered(cats):
            return "Refusing to send — body matched guardrails: \(cats.joined(separator: ", "))"
        case let .recipientNotAllowed(who):
            return "Recipient not in autonomous allowlist: \(who)"
        case .autonomousNotAuthorized:
            return "Autonomous send requires PIPPIN_AUTONOMOUS_MESSAGES=1 and --autonomous flag."
        case .accessDenied:
            return "Messages automation is not authorized. Grant Automation control of Messages and retry."
        case let .auditLogUnavailable(path, detail):
            return "Nothing was sent: the Messages audit log at \(path) could not be written (\(detail))."
        }
    }
}

extension MessagesSendError: RemediableError {
    public var agentCode: String {
        switch self {
        // Not `timeout`: that code is retryable, and a retry here could deliver twice.
        case .timeout: return "send_outcome_unknown"
        case .scriptFailed: return "script_failed"
        case .phiFiltered: return "phi_filtered"
        case .recipientNotAllowed: return "recipient_not_allowed"
        case .autonomousNotAuthorized: return "autonomous_not_authorized"
        case .accessDenied: return "access_denied"
        case .auditLogUnavailable: return "audit_log_unavailable"
        }
    }

    public var nextStep: NextStep {
        switch self {
        case .timeout: return .call(tool: "messages_list", argv: ["messages", "list"])
        case .scriptFailed: return .call(tool: "doctor", argv: ["doctor"])
        case .phiFiltered: return .none
        case .recipientNotAllowed:
            return .human("Add this recipient to messages.autonomousAllowlist in pippin's config if autonomous sends to it are intended.")
        case .autonomousNotAuthorized:
            return .human("Set PIPPIN_AUTONOMOUS_MESSAGES=1 in the environment that runs pippin if autonomous sending is intended.")
        case .accessDenied:
            return .human("Enable Automation control of Messages for pippin in System Settings > Privacy & Security > Automation, or approve the prompt during an autonomous send from an interactive terminal.")
        case let .auditLogUnavailable(path, _):
            return .human("Make \(path) and its folder writable by the user running pippin, then send again. pippin does not send a message it cannot log.")
        }
    }

    public var remediation: Remediation? {
        switch self {
        case .accessDenied: return .automationAccess(app: "Messages", trigger: "pippin messages send")
        default: return nil
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
            // No appName: the relaunch-and-retry would re-run a send that may
            // already have gone out.
            try ScriptRunner.run(
                script,
                timeoutSeconds: timeout,
                automationBundleID: "com.apple.MobileSMS"
            )
        }
    ) throws -> SendResult {
        let script = buildScript(recipient: buddyOrChatId, body: body)
        do {
            let out = try runner(script, timeoutSeconds)
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return SendResult(delivered: true, detail: trimmed.isEmpty ? "sent" : trimmed)
        } catch ScriptRunnerError.automationDenied {
            throw MessagesSendError.accessDenied
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
}
