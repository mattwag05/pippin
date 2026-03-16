import Foundation

public enum RemindersBridgeError: LocalizedError, Sendable {
    case accessDenied
    case reminderNotFound(String)
    case listNotFound(String)
    case saveFailed(String)
    case ambiguousId(String)
    case noDefaultCalendar

    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            return """
            Reminders access denied.
            → Open System Settings > Privacy & Security > Reminders
              Grant access to Terminal.app (or the pippin binary), then retry.
            """
        case let .reminderNotFound(id):
            return "Reminder not found: \(id)"
        case let .listNotFound(id):
            return "Reminder list not found: \(id)"
        case let .saveFailed(msg):
            return "Failed to save reminder: \(msg)"
        case let .ambiguousId(id):
            return "Ambiguous ID prefix '\(id)' — matches multiple reminders. Use more characters."
        case .noDefaultCalendar:
            return "No default Reminders list is set. Open Reminders and set a default list, then retry."
        }
    }
}

public struct ReminderList: Codable, Sendable {
    public let id: String
    public let title: String
    public let color: String
    public let account: String
    public let isDefault: Bool

    public init(id: String, title: String, color: String, account: String, isDefault: Bool) {
        self.id = id
        self.title = title
        self.color = color
        self.account = account
        self.isDefault = isDefault
    }
}

public struct ReminderItem: Codable, Sendable {
    public let id: String
    public let listId: String
    public let listTitle: String
    public let title: String
    public let notes: String?
    public let url: String?
    public let isCompleted: Bool
    public let completionDate: String?
    public let dueDate: String?
    public let priority: Int
    public let creationDate: String?
    public let lastModifiedDate: String?

    public init(
        id: String,
        listId: String,
        listTitle: String,
        title: String,
        notes: String? = nil,
        url: String? = nil,
        isCompleted: Bool = false,
        completionDate: String? = nil,
        dueDate: String? = nil,
        priority: Int = 0,
        creationDate: String? = nil,
        lastModifiedDate: String? = nil
    ) {
        self.id = id
        self.listId = listId
        self.listTitle = listTitle
        self.title = title
        self.notes = notes
        self.url = url
        self.isCompleted = isCompleted
        self.completionDate = completionDate
        self.dueDate = dueDate
        self.priority = priority
        self.creationDate = creationDate
        self.lastModifiedDate = lastModifiedDate
    }
}

public struct ReminderActionResult: Codable, Sendable {
    public let success: Bool
    public let action: String
    public let details: [String: String]

    public init(success: Bool, action: String, details: [String: String]) {
        self.success = success
        self.action = action
        self.details = details
    }
}

// MARK: - Field filtering

public extension ReminderItem {
    /// Encode only the specified fields to JSON. Pass nil to get all fields (standard encoding).
    func jsonData(fields: [String]?) throws -> Data {
        let encoder = JSONEncoder()
        guard let fields else {
            return try encoder.encode(self)
        }
        let reminderData = try encoder.encode(self)
        guard let all = try JSONSerialization.jsonObject(with: reminderData) as? [String: Any] else {
            throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "Expected JSON object"))
        }
        var dict: [String: Any] = [:]
        for field in fields {
            if let val = all[field] {
                dict[field] = val
            }
        }
        return try JSONSerialization.data(withJSONObject: dict, options: .sortedKeys)
    }
}

public extension Array where Element == ReminderItem {
    /// Encode each reminder with only the specified fields. Pass nil to get all fields.
    func jsonData(fields: [String]?) throws -> Data {
        let encoder = JSONEncoder()
        guard let fields else {
            return try encoder.encode(self)
        }
        let allDicts = try map { reminder -> [String: Any] in
            let reminderData = try encoder.encode(reminder)
            guard let dict = try JSONSerialization.jsonObject(with: reminderData) as? [String: Any] else {
                throw EncodingError.invalidValue(reminder, .init(codingPath: [], debugDescription: "Expected JSON object"))
            }
            return fields.reduce(into: [:]) { result, field in
                if let val = dict[field] { result[field] = val }
            }
        }
        return try JSONSerialization.data(withJSONObject: allDicts, options: .sortedKeys)
    }
}
