import Foundation

public enum RemindersBridgeError: LocalizedError, Sendable {
    case accessDenied
    case reminderNotFound(String)
    case listNotFound(String)
    case saveFailed(String)
    case ambiguousId(String, count: Int)
    case idPrefixTooShort(String)
    case noDefaultCalendar

    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            return """
            Reminders access denied.
            → Run `pippin permissions` once in a terminal, or enable pippin under
              System Settings > Privacy & Security > Reminders. The grant belongs
              to pippin itself at its installed path (e.g. ~/.local/bin/pippin),
              not to the launching app, because pippin relaunches as its own
              responsible process; a background agent that can't show the prompt
              needs `pippin reminders list` run once in a terminal first. With
              PIPPIN_NO_DISCLAIM=1, or when that relaunch is unavailable, the
              grant attaches to the launching app (your terminal, or the MCP/agent
              client) instead. Then retry.
            """
        case let .reminderNotFound(id):
            return "Reminder not found: \(id)"
        case let .listNotFound(id):
            return "Reminder list not found: \(id)"
        case let .saveFailed(msg):
            return "Failed to save reminder: \(msg)"
        case let .ambiguousId(id, count):
            return "Ambiguous ID prefix '\(id)': matches \(count) reminders. Use more characters or the full ID."
        case let .idPrefixTooShort(id):
            return "ID prefix '\(id)' is too short to edit, complete or delete a reminder. "
                + "Use the full ID or at least \(IDPrefix.minimumMutatingLength) characters of it."
        case .noDefaultCalendar:
            return "No default Reminders list is set. Open Reminders and set a default list, then retry."
        }
    }
}

extension RemindersBridgeError: RemediableError {
    public var agentCode: String {
        switch self {
        case .accessDenied: return "access_denied"
        case .reminderNotFound: return "reminder_not_found"
        case .listNotFound: return "list_not_found"
        case .saveFailed: return "save_failed"
        case .ambiguousId: return "ambiguous_id"
        case .idPrefixTooShort: return "invalid_id_prefix"
        case .noDefaultCalendar: return "no_default_calendar"
        }
    }

    public var nextStep: NextStep {
        switch self {
        case .accessDenied:
            return .human("Run `pippin permissions` in a terminal and approve Reminders access.")
        case .reminderNotFound, .ambiguousId, .idPrefixTooShort:
            return .call(tool: "reminders_list", argv: ["reminders", "list"])
        case .listNotFound, .noDefaultCalendar:
            return .call(tool: "reminders_lists", argv: ["reminders", "lists"])
        case .saveFailed: return .none
        }
    }

    public var remediation: Remediation? {
        switch self {
        case .accessDenied:
            return .privacyAccess(
                permission: "Reminders",
                listCommand: "pippin reminders list",
                doctorCheck: "Reminders access"
            )
        default:
            return nil
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

extension ReminderItem: EssentialRow {
    public static let essentialFields = ["id", "title", "dueDate", "isCompleted", "priority", "listTitle"]
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
