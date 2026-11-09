import Foundation

extension MailBridge {
    // MARK: - Process Runner

    /// `sending` marks a script that delivers mail. A timeout there cannot say
    /// whether delivery happened, so the runner must not re-run it (a nil
    /// `appName` disables its relaunch-and-retry) and the failure is not retryable.
    static func runScript(_ script: String, timeoutSeconds: Int = 10, sending: Bool = false) throws -> String {
        do {
            return try ScriptRunner.run(
                script,
                timeoutSeconds: timeoutSeconds,
                appName: sending ? nil : "Mail",
                automationBundleID: "com.apple.mail"
            )
        } catch ScriptRunnerError.automationDenied {
            throw MailBridgeError.accessDenied
        } catch ScriptRunnerError.timeout {
            throw sending ? MailBridgeError.sendOutcomeUnknown : MailBridgeError.timeout
        } catch let ScriptRunnerError.nonZeroExit(msg) {
            throw mapScriptFailure(msg)
        } catch let ScriptRunnerError.stderrOnSuccess(msg) {
            throw MailBridgeError.scriptFailed(msg)
        } catch let ScriptRunnerError.launchFailed(msg) {
            throw MailBridgeError.scriptFailed("osascript launch failed: \(msg)")
        }
    }

    /// Map a JXA script failure to a typed error. The scripts signal
    /// message-not-found as `MAILBRIDGE_ERR_MSG_NOT_FOUND` (move/attachments/
    /// mark's per-mailbox guard), `MAILBRIDGE_ERR_NOT_FOUND` (mark's outer
    /// guard), or `Message not found` (read script); osascript wraps them as
    /// `execution error: Error: Error: <msg> (-2700)`. Detecting the signature
    /// here gives every call site `message_not_found` (exit 3) instead of the
    /// generic `script_failed` (exit 5) with a raw JXA dump.
    /// `MAILBRIDGE_ERR_TARGET_NOT_FOUND` / `_ACCT_NOT_FOUND` are different
    /// resources and deliberately stay `scriptFailed`.
    static func mapScriptFailure(_ msg: String) -> MailBridgeError {
        let notFoundSignatures = ["MAILBRIDGE_ERR_MSG_NOT_FOUND", "MAILBRIDGE_ERR_NOT_FOUND", "Message not found"]
        if notFoundSignatures.contains(where: msg.contains) {
            return .messageNotFound(msg)
        }
        return .scriptFailed(msg)
    }

    // MARK: - Decoder

    static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try decodeScriptJSON(type, from: json, makeError: MailBridgeError.decodingFailed)
    }
}
