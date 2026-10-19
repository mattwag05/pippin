import Foundation

// MARK: - ToolDataAccess

/// Which kinds of personal app data each MCP tool can read or change. The
/// planner prompt lists these so a model can honor intents such as "do not
/// touch my mail"; tool descriptions alone do not say that `status` and
/// `doctor` open Mail, Notes, and the rest.
///
/// This is advisory metadata for the model, not an access boundary.
enum PersonalDataKind: String, CaseIterable, Comparable, Sendable {
    case mail
    case messages
    case notes
    case contacts
    case calendar
    case reminders
    case memos

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum ToolDataAccess {
    /// Tools whose name prefix does not describe what they touch.
    /// Job and batch tools run, or report the output of, arbitrary pippin
    /// commands, so they are classified as touching everything.
    private static let explicit: [String: Set<PersonalDataKind>] = [
        "digest": [.mail, .calendar, .reminders, .notes],
        "actions_extract": [.mail, .notes, .reminders],
        "status": [.mail, .calendar, .reminders, .notes, .contacts],
        "doctor": Set(PersonalDataKind.allCases),
        "memos_capture_to_reminders": [.memos, .reminders],
        "batch": Set(PersonalDataKind.allCases),
        "job_run": Set(PersonalDataKind.allCases),
        "job_show": Set(PersonalDataKind.allCases),
        "job_list": Set(PersonalDataKind.allCases),
        "job_wait": Set(PersonalDataKind.allCases),
    ]

    /// Data kinds for `toolName`, or nil when the tool is unclassified.
    /// `ToolDataAccessTests` requires every registered tool to resolve.
    static func kinds(for toolName: String) -> Set<PersonalDataKind>? {
        if let kinds = explicit[toolName] { return kinds }
        guard let prefix = toolName.split(separator: "_").first,
              let kind = PersonalDataKind(rawValue: String(prefix))
        else {
            return nil
        }
        // Mail and Messages results resolve sender handles to Contacts names.
        switch kind {
        case .mail, .messages: return [kind, .contacts]
        default: return [kind]
        }
    }

    /// Tools that touch none of `excluded`. Unclassified tools are dropped
    /// whenever anything is excluded, so a new tool fails closed.
    static func allowedTools(_ tools: [MCPTool], excluding excluded: Set<PersonalDataKind>) -> [MCPTool] {
        guard !excluded.isEmpty else { return tools }
        return tools.filter { tool in
            guard let kinds = kinds(for: tool.name) else { return false }
            return kinds.isDisjoint(with: excluded)
        }
    }
}
