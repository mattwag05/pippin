import ArgumentParser
import Foundation

public struct ActionsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "actions",
        abstract: "Surface unfulfilled commitments from your recent mail and notes.",
        subcommands: [Extract.self]
    )

    public init() {}

    // MARK: - Extract

    public struct Extract: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "extract",
            abstract: "Scan recent Sent mail and recently-modified Notes for commitments you made and emit draft reminders."
        )

        @Option(name: .long, help: "Number of days back to scan (1-90). Default: 7.")
        public var days: Int = 7

        @Flag(name: .long, inversion: .prefixedNo, help: "Include Sent mail as a source.")
        public var mail: Bool = true

        @Flag(name: .long, inversion: .prefixedNo, help: "Include recently-modified Notes as a source.")
        public var notes: Bool = true

        @Option(name: .long, help: "Mail account to scan (default: all accounts).")
        public var account: String?

        @Option(name: .long, help: "Max items to scan per source. Default: 50.")
        public var limit: Int = 50

        @Option(name: .long, help: "Minimum confidence (0.0-1.0) to include an extracted action. Default: 0.5.")
        public var minConfidence: Float = 0.5

        @Option(name: .long, help: "AI provider: ollama or claude (default: ollama).")
        public var provider: String?

        @Option(name: .long, help: "Model name (provider-specific default).")
        public var model: String?

        @Option(name: .long, help: "API key for Claude provider.")
        public var apiKey: String?

        @Option(name: .long, help: "Reminder list name to create into (when --create is set).")
        public var list: String?

        @Flag(name: .long, help: "Create reminders from the extracted actions after extraction.")
        public var create: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        public func validate() throws {
            if days < 1 || days > 90 {
                throw ValidationError("--days must be between 1 and 90.")
            }
            if limit < 1 || limit > 500 {
                throw ValidationError("--limit must be between 1 and 500.")
            }
            if minConfidence < 0.0 || minConfidence > 1.0 {
                throw ValidationError("--min-confidence must be between 0.0 and 1.0.")
            }
            if !mail, !notes {
                throw ValidationError("Enable at least one of --mail or --notes.")
            }
        }

        public mutating func run() async throws {
            let aiProvider = try AIProviderFactory.make(
                providerFlag: provider,
                modelFlag: model,
                apiKeyFlag: apiKey
            )

            let sinceDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())
            var items: [ActionExtractor.Item] = []

            if mail {
                try items.append(contentsOf: collectMailItems(since: sinceDate))
            }
            if notes {
                try items.append(contentsOf: collectNoteItems(since: sinceDate))
            }

            let actions = try ActionExtractor.extract(
                items: items,
                provider: aiProvider,
                minConfidence: minConfidence
            )

            if create {
                let results = try await createReminders(from: actions)
                try emitResults(results)
                return
            }

            try emitActions(actions)
        }

        // MARK: - Source collection

        private func collectMailItems(since: Date?) throws -> [ActionExtractor.Item] {
            let messages = try MailBridge.listActivity(
                account: account,
                mailboxes: ["Sent"],
                since: since,
                limit: limit,
                preview: 400
            )
            return messages.compactMap { msg in
                let text = msg.bodyPreview ?? msg.body
                guard let body = text, !body.isEmpty else { return nil }
                return ActionExtractor.Item(
                    source: .mail,
                    sourceId: msg.id,
                    sourceTitle: msg.subject,
                    text: body
                )
            }
        }

        private func collectNoteItems(since: Date?) throws -> [ActionExtractor.Item] {
            let all = try NotesBridge.listNotes(folder: nil, limit: limit)
            let filtered: [NoteInfo]
            if let since {
                let isoFrac = ISO8601DateFormatter()
                isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime]
                filtered = all.filter { note in
                    guard let modDate = isoFrac.date(from: note.modificationDate)
                        ?? iso.date(from: note.modificationDate) else { return true }
                    return modDate >= since
                }
            } else {
                filtered = all
            }
            return filtered.map { note in
                ActionExtractor.Item(
                    source: .note,
                    sourceId: note.id,
                    sourceTitle: note.title,
                    text: String(note.plainText.prefix(1200))
                )
            }
        }

        // MARK: - Reminder creation

        private func createReminders(from actions: [ExtractedAction]) async throws -> [ReminderActionResult] {
            let bridge = RemindersBridge()
            var resolvedListId: String?
            if let name = list {
                let lists = try await bridge.listReminderLists()
                if let match = lists.first(where: { $0.title.lowercased() == name.lowercased() }) {
                    resolvedListId = match.id
                } else if !output.isAgent {
                    fputs("Warning: list '\(name)' not found — using default list.\n", stderr)
                }
            }
            var results: [ReminderActionResult] = []
            for action in actions {
                let dueDate = action.proposedDueDate.flatMap { parseCalendarDate($0) }
                let notes = "Extracted from \(action.source.rawValue) \"\(action.sourceTitle ?? action.sourceId)\":\n\n\(action.snippet)"
                let result = try await bridge.createReminder(
                    title: action.proposedTitle,
                    listId: resolvedListId,
                    dueDate: dueDate,
                    priority: action.proposedPriority ?? 0,
                    notes: notes,
                    url: nil
                )
                results.append(result)
            }
            return results
        }

        // MARK: - Output

        private func emitActions(_ actions: [ExtractedAction]) throws {
            if output.isJSON {
                try printJSON(actions)
                return
            }
            if output.isAgent {
                try output.printAgent(actions)
                return
            }
            if actions.isEmpty {
                print("No commitments found in the last \(days) day(s).")
                return
            }
            let headers = ["Source", "Title", "Due", "Conf"]
            let widths = [6, 42, 18, 5]
            let rows = actions.map { action -> [String] in
                let due = action.proposedDueDate.map { TextFormatter.compactDate($0) } ?? "-"
                let conf = String(format: "%.2f", action.confidence)
                return [
                    action.source.rawValue,
                    TextFormatter.truncate(action.proposedTitle, to: widths[1]),
                    due,
                    conf,
                ]
            }
            print(TextFormatter.table(headers: headers, rows: rows, columnWidths: widths))
        }

        private func emitResults(_ results: [ReminderActionResult]) throws {
            if output.isJSON {
                try printJSON(results)
                return
            }
            if output.isAgent {
                try output.printAgent(results)
                return
            }
            if results.isEmpty {
                print("No commitments found — nothing created.")
                return
            }
            for result in results {
                print(TextFormatter.actionResult(success: result.success, action: result.action, details: result.details))
            }
        }
    }
}
