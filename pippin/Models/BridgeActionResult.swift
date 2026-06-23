import Foundation

/// Uniform result of a bridge mutation (create / update / delete / complete / …).
/// Shared across the Mail / Notes / Reminders / Calendar / Contacts / Memos
/// bridges — they all emit the same `{success, action, details}` agent-JSON
/// shape, so one type replaces the six byte-identical per-bridge copies. (pippin-c7f)
public struct BridgeActionResult: Codable, Sendable {
    public let success: Bool
    public let action: String
    public let details: [String: String]

    public init(success: Bool, action: String, details: [String: String] = [:]) {
        self.success = success
        self.action = action
        self.details = details
    }
}
