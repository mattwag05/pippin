import Foundation

extension MailBridge {
    // MARK: - Process Runner

    static func runScript(_ script: String, timeoutSeconds: Int = 10) throws -> String {
        do {
            return try ScriptRunner.run(script, timeoutSeconds: timeoutSeconds, appName: "Mail")
        } catch ScriptRunnerError.timeout {
            throw MailBridgeError.timeout
        } catch let ScriptRunnerError.nonZeroExit(msg) {
            throw MailBridgeError.scriptFailed(msg)
        } catch let ScriptRunnerError.stderrOnSuccess(msg) {
            throw MailBridgeError.scriptFailed(msg)
        } catch let ScriptRunnerError.launchFailed(msg) {
            throw MailBridgeError.scriptFailed("osascript launch failed: \(msg)")
        }
    }

    // MARK: - Decoder

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
