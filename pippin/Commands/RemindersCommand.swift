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

    public struct Lists: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "lists",
            abstract: "List all reminder lists."
        )

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let bridge = RemindersBridge()
            let lists = try await bridge.listReminderLists()
            return AgentResult(lists)
        }
    }

    // MARK: - List (reminders in a list)

    public struct List: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List reminders. Defaults to incomplete reminders."
        )

        @Option(name: .long, help: "Reminder list ID to filter (from `pippin reminders lists`); a unique list name also resolves.")
        public var list: String?

        @Flag(name: .long, help: "Show completed reminders instead of incomplete.")
        public var completed: Bool = false

        @Option(name: .long, help: "Only show reminders due before this date: YYYY-MM-DD or ISO 8601.")
        public var dueBefore: String?

        @Option(name: .long, help: "Only show reminders due after this date: YYYY-MM-DD or ISO 8601.")
        public var dueAfter: String?

        @Option(name: .long, help: "Only show reminders created on or after this date: YYYY-MM-DD or ISO 8601.")
        public var createdAfter: String?

        @Option(name: .long, help: "Only show reminders modified on or after this date: YYYY-MM-DD or ISO 8601.")
        public var modifiedAfter: String?

        @Option(name: .long, help: "Filter by priority: high, medium, low, none (or 1, 5, 9, 0).")
        public var priority: String?

        @Option(name: .long, help: "Maximum reminders to return (default: 50). Ignored when --cursor or --page-size is set.")
        public var limit: Int = 50

        @OptionGroup public var pagination: PaginationOptions

        @OptionGroup public var output: OutputOptions

        public init() {}

        /// Advisory surfaced when the EventKit fetch hits its 15s wall-clock cap
        /// (store hang / permission edge). `--list` scopes the underlying
        /// predicate, so it's the one flag that actually shrinks the fetch.
        static let timedOutHint = "reminders fetch did not complete within 15s — returning partial results; scope to a single list with --list for a complete, faster fetch"

        public mutating func validate() throws {
            if let dueBefore, parseCalendarDate(dueBefore) == nil {
                throw ValidationError("--due-before must be in YYYY-MM-DD or ISO 8601 format.")
            }
            if let dueAfter, parseCalendarDate(dueAfter) == nil {
                throw ValidationError("--due-after must be in YYYY-MM-DD or ISO 8601 format.")
            }
            if let createdAfter, parseCalendarDate(createdAfter) == nil {
                throw ValidationError("--created-after must be in YYYY-MM-DD or ISO 8601 format.")
            }
            if let modifiedAfter, parseCalendarDate(modifiedAfter) == nil {
                throw ValidationError("--modified-after must be in YYYY-MM-DD or ISO 8601 format.")
            }
            if let priority, parseReminderPriority(priority) == nil {
                throw ValidationError("--priority must be: high, medium, low, none (or 0, 1, 5, 9).")
            }
            guard limit > 0 else {
                throw ValidationError("--limit must be positive.")
            }
        }

        public mutating func execute() async throws -> AgentResult {
            let bridge = RemindersBridge()

            if pagination.isActive {
                let hash = Pagination.filterHash([
                    "list": list,
                    "completed": completed ? "1" : "0",
                    "dueBefore": dueBefore,
                    "dueAfter": dueAfter,
                    "createdAfter": createdAfter,
                    "modifiedAfter": modifiedAfter,
                    "priority": priority,
                ])
                let (offset, pageSize) = try Pagination.resolve(
                    pagination, defaultPageSize: limit, filterHash: hash
                )
                let fetched = try await bridge.listReminders(
                    listId: list,
                    completed: completed,
                    dueBefore: dueBefore.flatMap { parseCalendarDate($0) },
                    dueAfter: dueAfter.flatMap { parseCalendarDate($0) },
                    createdAfter: createdAfter.flatMap { parseCalendarDate($0) },
                    modifiedAfter: modifiedAfter.flatMap { parseCalendarDate($0) },
                    priority: priority.flatMap { parseReminderPriority($0) },
                    limit: offset + pageSize + 1
                )
                let page = try Pagination.paginate(
                    all: fetched.results, offset: offset, pageSize: pageSize, filterHash: hash
                )
                return .emitPage(page, timedOut: fetched.timedOut, timedOutHint: Self.timedOutHint, fields: FieldProjection.parse(output.fields))
            }

            let outcome = try await bridge.listReminders(
                listId: list,
                completed: completed,
                dueBefore: dueBefore.flatMap { parseCalendarDate($0) },
                dueAfter: dueAfter.flatMap { parseCalendarDate($0) },
                createdAfter: createdAfter.flatMap { parseCalendarDate($0) },
                modifiedAfter: modifiedAfter.flatMap { parseCalendarDate($0) },
                priority: priority.flatMap { parseReminderPriority($0) },
                limit: limit
            )
            return .emit(outcome.results, timedOut: outcome.timedOut, timedOutHint: Self.timedOutHint, fields: FieldProjection.parse(output.fields))
        }
    }

    // MARK: - Show

    public struct Show: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show full details for a single reminder by ID."
        )

        @Argument(help: "Reminder ID or prefix from `pippin reminders list` output.")
        public var id: String

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let bridge = RemindersBridge()
            let reminder = try await bridge.showReminder(id: id)
            return AgentResult(reminder)
        }
    }

    // MARK: - Create

    public struct Create: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create a new reminder."
        )

        @Argument(help: "Reminder title.")
        public var title: String

        @Option(name: .long, help: "Reminder list ID (default: default list); a unique list name also resolves.")
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

        public mutating func execute() async throws -> AgentResult {
            let bridge = RemindersBridge()
            let result = try await bridge.createReminder(
                title: title,
                listId: list,
                dueDate: due.flatMap { parseCalendarDate($0) },
                priority: priority.flatMap { parseReminderPriority($0) } ?? 0,
                notes: notes,
                url: url
            )
            return AgentResult(result)
        }
    }

    // MARK: - Edit

    public struct Edit: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "edit",
            abstract: "Edit an existing reminder."
        )

        @Argument(help: "Reminder ID, or a unique prefix of at least 8 characters, to edit.")
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

        @Option(name: .long, help: "Move to list ID; a unique list name also resolves.")
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

        public mutating func execute() async throws -> AgentResult {
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
            return AgentResult(result)
        }
    }

    // MARK: - Complete

    public struct Complete: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "complete",
            abstract: "Mark a reminder as completed."
        )

        @Argument(help: "Reminder ID, or a unique prefix of at least 8 characters, to complete.")
        public var id: String

        @Flag(name: .long, help: "Mark the reminder as not completed instead (what `pippin undo` runs).")
        public var incomplete: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let bridge = RemindersBridge()
            let result = try await bridge.completeReminder(id: id, completed: !incomplete)
            return AgentResult(result)
        }
    }

    // MARK: - Delete

    public struct Delete: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete a reminder."
        )

        @Argument(help: "Reminder ID, or a unique prefix of at least 8 characters, to delete.")
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

        public mutating func execute() async throws -> AgentResult {
            let bridge = RemindersBridge()
            let result = try await bridge.deleteReminder(id: id)
            return AgentResult(result)
        }
    }

    // MARK: - Search

    public struct Search: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "search",
            abstract: "Search reminders by text."
        )

        @Argument(help: "Search query (matches title and notes).")
        public var query: String

        @Option(name: .long, help: "Reminder list ID to search within; a unique list name also resolves.")
        public var list: String?

        @Option(name: .long, help: "Maximum results to return (default: 50).")
        public var limit: Int = 50

        @Flag(name: .long, help: "Search completed reminders instead of incomplete.")
        public var completed: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        /// See `List.timedOutHint` — same 15s EventKit fetch cap; `--list` is the
        /// only flag that narrows the underlying predicate.
        static let timedOutHint = List.timedOutHint

        public mutating func validate() throws {
            guard limit > 0 else {
                throw ValidationError("--limit must be positive.")
            }
        }

        public mutating func execute() async throws -> AgentResult {
            let bridge = RemindersBridge()
            let outcome = try await bridge.searchReminders(
                query: query,
                listId: list,
                completed: completed,
                limit: limit
            )
            return .emit(outcome.results, timedOut: outcome.timedOut, timedOutHint: Self.timedOutHint, fields: FieldProjection.parse(output.fields))
        }
    }

    // MARK: - SmartCreate

    public struct SmartCreate: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "smart-create",
            abstract: "Create a reminder from a natural language description using AI."
        )

        @Argument(help: "Natural language description, e.g. 'call dentist next Tuesday at 9am priority high'.")
        public var description: String

        @Option(name: .long, help: "AI provider: ollama, claude, or openai (default: ollama).")
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

        public mutating func execute() async throws -> AgentResult {
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

            let descriptionLocal = description
            // aiProvider.complete blocks via DispatchSemaphore — hop off the
            // cooperative pool so concurrent MCP smart-creates don't stall.
            let jsonStr = try await detachBlocking {
                try aiProvider.complete(
                    prompt: descriptionLocal, system: systemPrompt,
                    options: AICompletionOptions(jsonMode: true)
                )
            }

            guard
                let specData = extractJSON(from: jsonStr),
                let parsed = try? JSONDecoder().decode(SmartReminderSpec.self, from: specData)
            else {
                throw SmartReminderError("Failed to parse AI response as reminder spec. Raw: \(jsonStr)")
            }

            if dryRun {
                return AgentResult(parsed)
            }

            let bridge = RemindersBridge()

            // Resolve list name to ID (CLI flag takes precedence over AI-parsed
            // name); an unmatched name falls through to the default list.
            var resolvedListId: String? = nil
            if let name = list ?? parsed.listTitle {
                let lists = try await bridge.listReminderLists()
                resolvedListId = lists.first(where: { $0.title.lowercased() == name.lowercased() })?.id
            }

            let result = try await bridge.createReminder(
                title: parsed.title,
                listId: resolvedListId,
                dueDate: parsed.dueDate.flatMap { parseCalendarDate($0) },
                priority: parsed.priority ?? 0,
                notes: parsed.notes,
                url: nil
            )

            return AgentResult(result)
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

extension SmartReminderError: RemediableError {
    var agentCode: String { "smart_reminder_error" }
    var nextStep: NextStep { .none }
}
