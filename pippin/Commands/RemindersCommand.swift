import ArgumentParser
import Foundation

public struct RemindersCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "reminders",
        abstract: "Interact with Apple Reminders.",
        subcommands: [
            Lists.self, List.self, Show.self,
            Create.self, Edit.self, Complete.self,
            Delete.self, Search.self, SmartCreate.self,
        ]
    )

    public init() {}

    // MARK: - Lists (all reminder lists)

    public struct Lists: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "lists",
            abstract: "List all reminder lists."
        )

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            let bridge = RemindersBridge()
            let lists = try await bridge.listReminderLists()
            if output.isJSON {
                try printJSON(lists)
            } else if output.isAgent {
                try printAgentJSON(lists)
            } else {
                if lists.isEmpty {
                    print("No reminder lists found.")
                    return
                }
                let rows = lists.map { [$0.title, $0.account, $0.isDefault ? "yes" : "no"] }
                print(TextFormatter.table(
                    headers: ["NAME", "ACCOUNT", "DEFAULT"],
                    rows: rows,
                    columnWidths: [30, 30, 8]
                ))
            }
        }
    }

    // MARK: - List (reminders in a list)

    public struct List: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List reminders. Defaults to incomplete reminders."
        )

        @Option(name: .long, help: "Reminder list ID to filter (from `pippin reminders lists`).")
        public var list: String?

        @Flag(name: .long, help: "Include completed reminders.")
        public var completed: Bool = false

        @Option(name: .long, help: "Only show reminders due before this date: YYYY-MM-DD or ISO 8601.")
        public var dueBefore: String?

        @Option(name: .long, help: "Only show reminders due after this date: YYYY-MM-DD or ISO 8601.")
        public var dueAfter: String?

        @Option(name: .long, help: "Filter by priority: high, medium, low, none (or 1, 5, 9, 0).")
        public var priority: String?

        @Option(name: .long, help: "Maximum reminders to return (default: 50).")
        public var limit: Int = 50

        @Option(name: .long, help: "Comma-separated JSON field names to include (e.g. id,title,dueDate). JSON output only.")
        public var fields: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            if let dueBefore, parseCalendarDate(dueBefore) == nil {
                throw ValidationError("--due-before must be in YYYY-MM-DD or ISO 8601 format.")
            }
            if let dueAfter, parseCalendarDate(dueAfter) == nil {
                throw ValidationError("--due-after must be in YYYY-MM-DD or ISO 8601 format.")
            }
            if let priority, parseReminderPriority(priority) == nil {
                throw ValidationError("--priority must be: high, medium, low, none (or 0, 1, 5, 9).")
            }
            guard limit > 0 else {
                throw ValidationError("--limit must be positive.")
            }
        }

        public mutating func run() async throws {
            let bridge = RemindersBridge()
            let reminders = try await bridge.listReminders(
                listId: list,
                completed: completed,
                dueBefore: dueBefore.flatMap { parseCalendarDate($0) },
                dueAfter: dueAfter.flatMap { parseCalendarDate($0) },
                priority: priority.flatMap { parseReminderPriority($0) },
                limit: limit
            )
            if output.isJSON {
                let fieldList = fields?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let data = try reminders.jsonData(fields: fieldList)
                print(String(data: data, encoding: .utf8)!)
            } else if output.isAgent {
                try printAgentJSON(reminders)
            } else {
                printRemindersTable(reminders)
            }
        }
    }

    // MARK: - Show

    public struct Show: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show full details for a single reminder by ID."
        )

        @Argument(help: "Reminder ID or prefix from `pippin reminders list` output.")
        public var id: String

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            let bridge = RemindersBridge()
            let reminder = try await bridge.showReminder(id: id)
            if output.isJSON {
                try printJSON(reminder)
            } else if output.isAgent {
                try printAgentJSON(reminder)
            } else {
                printReminderCard(reminder)
            }
        }
    }

    // MARK: - Create

    public struct Create: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create a new reminder."
        )

        @Argument(help: "Reminder title.")
        public var title: String

        @Option(name: .long, help: "Reminder list ID (default: default list).")
        public var list: String?

        @Option(name: .long, help: "Due date: YYYY-MM-DD or ISO 8601.")
        public var due: String?

        @Option(name: .long, help: "Priority: high, medium, low, none (default: none).")
        public var priority: String?

        @Option(name: .long, help: "Reminder notes.")
        public var notes: String?

        @Option(name: .long, help: "Reminder URL.")
        public var url: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            if let due, parseCalendarDate(due) == nil {
                throw ValidationError("--due must be in YYYY-MM-DD or ISO 8601 format.")
            }
            if let priority, parseReminderPriority(priority) == nil {
                throw ValidationError("--priority must be: high, medium, low, none (or 0, 1, 5, 9).")
            }
        }

        public mutating func run() async throws {
            let bridge = RemindersBridge()
            let result = try await bridge.createReminder(
                title: title,
                listId: list,
                dueDate: due.flatMap { parseCalendarDate($0) },
                priority: priority.flatMap { parseReminderPriority($0) } ?? 0,
                notes: notes,
                url: url
            )
            if output.isJSON {
                try printJSON(result)
            } else if output.isAgent {
                try printAgentJSON(result)
            } else {
                print(TextFormatter.actionResult(success: result.success, action: result.action, details: result.details))
            }
        }
    }

    // MARK: - Edit

    public struct Edit: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "edit",
            abstract: "Edit an existing reminder."
        )

        @Argument(help: "Reminder ID or prefix to edit.")
        public var id: String

        @Option(name: .long, help: "New title.")
        public var title: String?

        @Option(name: .long, help: "New due date: YYYY-MM-DD or ISO 8601.")
        public var due: String?

        @Option(name: .long, help: "New priority: high, medium, low, none.")
        public var priority: String?

        @Option(name: .long, help: "New notes.")
        public var notes: String?

        @Option(name: .long, help: "New URL.")
        public var url: String?

        @Option(name: .long, help: "Move to list ID.")
        public var list: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            if let due, parseCalendarDate(due) == nil {
                throw ValidationError("--due must be in YYYY-MM-DD or ISO 8601 format.")
            }
            if let priority, parseReminderPriority(priority) == nil {
                throw ValidationError("--priority must be: high, medium, low, none (or 0, 1, 5, 9).")
            }
        }

        public mutating func run() async throws {
            let bridge = RemindersBridge()
            let result = try await bridge.updateReminder(
                id: id,
                title: title,
                dueDate: due.flatMap { parseCalendarDate($0) },
                priority: priority.flatMap { parseReminderPriority($0) },
                notes: notes,
                listId: list,
                url: url
            )
            if output.isJSON {
                try printJSON(result)
            } else if output.isAgent {
                try printAgentJSON(result)
            } else {
                print(TextFormatter.actionResult(success: result.success, action: result.action, details: result.details))
            }
        }
    }

    // MARK: - Complete

    public struct Complete: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "complete",
            abstract: "Mark a reminder as completed."
        )

        @Argument(help: "Reminder ID or prefix to complete.")
        public var id: String

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            let bridge = RemindersBridge()
            let result = try await bridge.completeReminder(id: id)
            if output.isJSON {
                try printJSON(result)
            } else if output.isAgent {
                try printAgentJSON(result)
            } else {
                print(TextFormatter.actionResult(success: result.success, action: result.action, details: result.details))
            }
        }
    }

    // MARK: - Delete

    public struct Delete: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete a reminder."
        )

        @Argument(help: "Reminder ID or prefix to delete.")
        public var id: String

        @Flag(name: .long, help: "Required: confirm deletion without a prompt.")
        public var force: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard force else {
                throw ValidationError("--force is required. This operation cannot be undone.")
            }
        }

        public mutating func run() async throws {
            let bridge = RemindersBridge()
            let result = try await bridge.deleteReminder(id: id)
            if output.isJSON {
                try printJSON(result)
            } else if output.isAgent {
                try printAgentJSON(result)
            } else {
                print(TextFormatter.actionResult(success: result.success, action: result.action, details: result.details))
            }
        }
    }

    // MARK: - Search

    public struct Search: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "search",
            abstract: "Search reminders by text."
        )

        @Argument(help: "Search query (matches title and notes).")
        public var query: String

        @Option(name: .long, help: "Reminder list ID to search within.")
        public var list: String?

        @Option(name: .long, help: "Maximum results to return (default: 50).")
        public var limit: Int = 50

        @Flag(name: .long, help: "Search completed reminders instead of incomplete.")
        public var completed: Bool = false

        @Option(name: .long, help: "Comma-separated JSON field names to include (e.g. id,title,dueDate). JSON output only.")
        public var fields: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard limit > 0 else {
                throw ValidationError("--limit must be positive.")
            }
        }

        public mutating func run() async throws {
            let bridge = RemindersBridge()
            let reminders = try await bridge.searchReminders(
                query: query,
                listId: list,
                completed: completed,
                limit: limit
            )
            if output.isJSON {
                let fieldList = fields?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let data = try reminders.jsonData(fields: fieldList)
                print(String(data: data, encoding: .utf8)!)
            } else if output.isAgent {
                try printAgentJSON(reminders)
            } else {
                printRemindersTable(reminders)
            }
        }
    }

    // MARK: - SmartCreate

    public struct SmartCreate: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "smart-create",
            abstract: "Create a reminder from a natural language description using AI."
        )

        @Argument(help: "Natural language description, e.g. 'call dentist next Tuesday at 9am priority high'.")
        public var description: String

        @Option(name: .long, help: "AI provider: ollama or claude (default: ollama).")
        public var provider: String?

        @Option(name: .long, help: "Model name (provider-specific default).")
        public var model: String?

        @Option(name: .long, help: "API key for Claude provider.")
        public var apiKey: String?

        @Option(name: .long, help: "Reminder list name to create in (overrides AI-parsed list).")
        public var list: String?

        @Flag(name: .long, help: "Print parsed reminder JSON without creating it.")
        public var dryRun: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            let aiProvider = try AIProviderFactory.make(
                providerFlag: provider,
                modelFlag: model,
                apiKeyFlag: apiKey
            )

            let now = Date()
            let dateFormatter = DateFormatter()
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateFormatter.dateFormat = "yyyy-MM-dd"
            let today = dateFormatter.string(from: now)

            let timeFormatter = DateFormatter()
            timeFormatter.locale = Locale(identifier: "en_US_POSIX")
            timeFormatter.dateFormat = "HH:mm"
            let currentTime = timeFormatter.string(from: now)

            let systemPrompt = BuiltInTemplates.smartCreateReminders.content
                .replacingOccurrences(of: "{{CURRENT_DATE}}", with: today)
                .replacingOccurrences(of: "{{CURRENT_TIME}}", with: currentTime)

            let jsonStr = try aiProvider.complete(prompt: description, system: systemPrompt)

            guard
                let specData = extractJSON(from: jsonStr),
                let parsed = try? JSONDecoder().decode(SmartReminderSpec.self, from: specData)
            else {
                throw SmartReminderError("Failed to parse AI response as reminder spec. Raw: \(jsonStr)")
            }

            if dryRun {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? encoder.encode(parsed) {
                    print(String(data: data, encoding: .utf8)!)
                }
                return
            }

            let bridge = RemindersBridge()

            // Resolve list name to ID (CLI flag takes precedence over AI-parsed name)
            var resolvedListId: String? = nil
            if let name = list ?? parsed.listTitle {
                let lists = try await bridge.listReminderLists()
                if let match = lists.first(where: { $0.title.lowercased() == name.lowercased() }) {
                    resolvedListId = match.id
                } else if !output.isAgent {
                    fputs("Warning: list '\(name)' not found — using default list.\n", stderr)
                }
            }

            let result = try await bridge.createReminder(
                title: parsed.title,
                listId: resolvedListId,
                dueDate: parsed.dueDate.flatMap { parseCalendarDate($0) },
                priority: parsed.priority ?? 0,
                notes: parsed.notes,
                url: nil
            )

            if output.isJSON {
                try printJSON(result)
            } else if output.isAgent {
                try printAgentJSON(result)
            } else {
                print(TextFormatter.actionResult(success: result.success, action: result.action, details: result.details))
            }
        }
    }
}

// MARK: - SmartCreate helpers

private struct SmartReminderSpec: Codable {
    let title: String
    let notes: String?
    let dueDate: String?
    let priority: Int?
    let listTitle: String?
}

private struct SmartReminderError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) {
        errorDescription = message
    }
}

// MARK: - Text output helpers

private func printRemindersTable(_ reminders: [ReminderItem]) {
    if reminders.isEmpty {
        print("No reminders found.")
        return
    }
    let rows = reminders.map { reminder -> [String] in
        let shortId = String(reminder.id.prefix(8))
        let due = reminder.dueDate.map { TextFormatter.compactDate($0) } ?? "-"
        let priorityStr = reminder.priority == 0 ? "-" : formatReminderPriority(reminder.priority)
        return [shortId, due, priorityStr, TextFormatter.truncate(reminder.title, to: 35)]
    }
    print(TextFormatter.table(
        headers: ["ID", "DUE", "PRIORITY", "TITLE"],
        rows: rows,
        columnWidths: [10, 18, 10, 37]
    ))
}

private func printReminderCard(_ reminder: ReminderItem) {
    var fields: [(String, String)] = [
        ("ID", reminder.id),
        ("Title", reminder.title),
        ("List", reminder.listTitle),
        ("Completed", reminder.isCompleted ? "yes" : "no"),
        ("Priority", formatReminderPriority(reminder.priority)),
    ]
    if let due = reminder.dueDate { fields.append(("Due", due)) }
    if let comp = reminder.completionDate { fields.append(("Completed On", comp)) }
    if let url = reminder.url { fields.append(("URL", url)) }
    if let notes = reminder.notes { fields.append(("Notes", notes)) }
    if let created = reminder.creationDate { fields.append(("Created", created)) }
    if let modified = reminder.lastModifiedDate { fields.append(("Modified", modified)) }
    print(TextFormatter.card(fields: fields))
}
