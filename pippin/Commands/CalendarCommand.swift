import ArgumentParser
import Foundation

public struct CalendarCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "calendar",
        abstract: "Interact with Apple Calendar.",
        subcommands: [
            ListCalendars.self, Events.self, Show.self,
            Create.self, Edit.self, Delete.self,
            SmartCreate.self, Conflicts.self, Agenda.self, Search.self,
            Today.self, Remaining.self, Upcoming.self,
        ]
    )

    public init() {}

    /// Advisory surfaced when a Calendar event fetch hits the 15s wall-clock cap
    /// in `CalendarBridge.fetchEventsSync` and returns partial results. Shared by
    /// every event-listing subcommand so the wording stays consistent. (pippin-mgg)
    static let timedOutHint = "calendar fetch did not complete within 15s — returning partial results; narrow the window with --from/--to (or --range) for a complete, faster fetch"

    /// The `warnings` array to thread into an `AgentResult` when a fetch
    /// returned partial results; `nil` (omitted) otherwise. The envelope is the
    /// only place the advisory goes: a stderr line would be double-noise for MCP
    /// clients, which capture child stderr.
    static func timedOutWarnings(_ timedOut: Bool) -> [String]? {
        timedOut ? [timedOutHint] : nil
    }

    // MARK: - List (calendars)

    public struct ListCalendars: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List calendars."
        )

        @OptionGroup public var output: OutputOptions

        @Option(name: .long, help: "Filter by calendar type: local, calDAV, exchange, subscription, birthday.")
        public var type: String?

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let bridge = CalendarBridge()
            var calendars = try await bridge.listCalendars()
            if let typeFilter = type {
                let allowedTypes = typeFilter.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                calendars = calendars.filter { allowedTypes.contains($0.type.lowercased()) }
            }
            return AgentResult(calendars)
        }
    }

    // MARK: - Events

    public struct Events: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "events",
            abstract: "List calendar events. Defaults to today."
        )

        @Option(name: [.customLong("from"), .customLong("after")], help: "Start date/time: YYYY-MM-DD, 'YYYY-MM-DD HH:MM', or ISO 8601 (default: start of today). --after is the canonical cross-module name.")
        public var from: String?

        @Option(name: [.customLong("to"), .customLong("before")], help: "End date/time: YYYY-MM-DD, 'YYYY-MM-DD HH:MM', or ISO 8601 (default: end of today). --before is the canonical cross-module name.")
        public var to: String?

        @Option(name: .long, help: "Calendar ID to filter events (from `pippin calendar list`).")
        public var calendar: String?

        @Option(name: .long, help: "Calendar name to filter events (case-insensitive; an exact match wins, otherwise substring fallback).")
        public var calendarName: String?

        @Option(name: .long, help: "Maximum events to return (default: 50). Ignored when --cursor or --page-size is set.")
        public var limit: Int = 50

        @Option(name: .long, help: "Date range shorthand: today, today+N (e.g. today+3), week, or month. Overrides --from/--to.")
        public var range: String?

        @Option(name: .long, help: "Calendar types to include: local, calDAV, exchange, subscription, birthday.")
        public var type: String?

        @OptionGroup public var pagination: PaginationOptions

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            if let from, parseCalendarDate(from) == nil {
                throw ValidationError("--from must be in YYYY-MM-DD or ISO 8601 format.")
            }
            if let to, parseCalendarDate(to) == nil {
                throw ValidationError("--to must be in YYYY-MM-DD or ISO 8601 format.")
            }
            guard limit > 0 else {
                throw ValidationError("--limit must be positive.")
            }
            if calendar != nil, calendarName != nil {
                throw ValidationError("--calendar and --calendar-name cannot both be set.")
            }
            if let range, parseRange(range) == nil {
                throw ValidationError("--range must be: today, today+N (e.g. today+3), week, or month.")
            }
        }

        public mutating func execute() async throws -> AgentResult {
            let startDate: Date
            let endDate: Date
            if let range, let (rangeStart, rangeEnd) = parseRange(range) {
                startDate = rangeStart
                endDate = rangeEnd
            } else {
                startDate = from.flatMap { parseCalendarDate($0) }
                    ?? Calendar.current.startOfDay(for: Date())
                if let to, let parsed = parseCalendarDate(to) {
                    endDate = parsed
                } else {
                    // End of today (midnight of tomorrow)
                    endDate = Calendar.current.date(
                        byAdding: .day, value: 1,
                        to: Calendar.current.startOfDay(for: Date())
                    )!
                }
            }

            let bridge = CalendarBridge()
            var calendarId = calendar
            if let name = calendarName {
                calendarId = try await resolveCalendarName(name, bridge: bridge)
            }
            let listOutcome = try await bridge.listEvents(from: startDate, to: endDate, calendarId: calendarId)
            var events = listOutcome.results

            if let typeFilter = type {
                let allowedTypes = typeFilter.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                let allCalendars = try await bridge.listCalendars()
                let matchingIds = allCalendars
                    .filter { allowedTypes.contains($0.type.lowercased()) }
                    .map { $0.id }
                events = events.filter { matchingIds.contains($0.calendarId) }
            }

            if pagination.isActive {
                let hash = Pagination.filterHash([
                    "from": from,
                    "to": to,
                    "calendar": calendar,
                    "calendarName": calendarName,
                    "range": range,
                    "type": type,
                ])
                let (offset, pageSize) = try Pagination.resolve(
                    pagination, defaultPageSize: limit, filterHash: hash
                )
                let page = try Pagination.paginate(
                    all: events, offset: offset, pageSize: pageSize, filterHash: hash
                )
                return .page(page, warnings: CalendarCommand.timedOutWarnings(listOutcome.timedOut), fields: FieldProjection.parse(output.fields))
            }

            if events.count > limit {
                events = Array(events.prefix(limit))
            }

            return AgentResult(events, warnings: CalendarCommand.timedOutWarnings(listOutcome.timedOut), fields: FieldProjection.parse(output.fields))
        }
    }

    // MARK: - Show

    public struct Show: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show full details for a single event by ID."
        )

        @Argument(help: "Event ID or prefix from `pippin calendar events` output.")
        public var id: String

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let bridge = CalendarBridge()
            let event = try await bridge.getEvent(id: id)
            return AgentResult(event)
        }
    }

    // MARK: - Create

    public struct Create: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create a new calendar event."
        )

        @Option(name: .long, help: "Event title (required).")
        public var title: String

        @Option(name: .long, help: "Start date/time: YYYY-MM-DD, 'YYYY-MM-DD HH:MM', or ISO 8601 (required).")
        public var start: String

        @Option(name: .long, help: "End date/time (default: start + 1 hour).")
        public var end: String?

        @Option(name: .long, help: "Calendar ID (default: default calendar).")
        public var calendar: String?

        @Option(name: .long, help: "Event location.")
        public var location: String?

        @Option(name: .long, help: "Event notes.")
        public var notes: String?

        @Flag(name: .long, help: "Create as an all-day event.")
        public var allDay: Bool = false

        @Option(name: .long, help: "Event URL.")
        public var url: String?

        @Option(name: .long, help: "Alert before event, e.g. '15m', '1h', '2d'.")
        public var alert: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard parseCalendarDate(start) != nil else {
                throw ValidationError("--start must be in YYYY-MM-DD or ISO 8601 format.")
            }
            if let end, parseCalendarDate(end) == nil {
                throw ValidationError("--end must be in YYYY-MM-DD or ISO 8601 format.")
            }
            if let alert, parseAlertDuration(alert) == nil {
                throw ValidationError("--alert must be in format like '15m', '1h', '2d'.")
            }
        }

        public mutating func execute() async throws -> AgentResult {
            guard let startDate = parseCalendarDate(start) else {
                throw ValidationError("Invalid --start date.")
            }
            let endDate: Date
            if let end, let parsed = parseCalendarDate(end) {
                endDate = parsed
            } else {
                endDate = startDate.addingTimeInterval(3600) // default: +1 hour
            }

            let bridge = CalendarBridge()
            let result = try await bridge.createEvent(
                title: title,
                start: startDate,
                end: endDate,
                calendarId: calendar,
                location: location,
                notes: notes,
                url: url,
                isAllDay: allDay,
                alertOffset: alert.flatMap { parseAlertDuration($0) }
            )

            return AgentResult(result)
        }
    }

    // MARK: - Edit

    public struct Edit: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "edit",
            abstract: "Edit an existing calendar event."
        )

        @Argument(help: "Event ID or prefix to edit.")
        public var id: String

        @Option(name: .long, help: "New title.")
        public var title: String?

        @Option(name: .long, help: "New start date/time.")
        public var start: String?

        @Option(name: .long, help: "New end date/time.")
        public var end: String?

        @Option(name: .long, help: "Move to calendar ID.")
        public var calendar: String?

        @Option(name: .long, help: "New location.")
        public var location: String?

        @Option(name: .long, help: "New notes.")
        public var notes: String?

        @Option(name: .long, help: "New URL.")
        public var url: String?

        @Option(name: .long, help: "Alert before event, e.g. '15m', '1h', '2d'.")
        public var alert: String?

        @Option(name: .long, help: "Span for recurring events: 'this' or 'future' (default: this).")
        public var span: String = "this"

        @Flag(name: .long, help: "Set event as all-day.")
        public var allDay: Bool = false

        @Flag(name: .long, help: "Remove all-day flag from event.")
        public var noAllDay: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            if let start, parseCalendarDate(start) == nil {
                throw ValidationError("--start must be in YYYY-MM-DD or ISO 8601 format.")
            }
            if let end, parseCalendarDate(end) == nil {
                throw ValidationError("--end must be in YYYY-MM-DD or ISO 8601 format.")
            }
            if parseSpan(span) == nil {
                throw ValidationError("--span must be 'this' or 'future'.")
            }
            if let alert, parseAlertDuration(alert) == nil {
                throw ValidationError("--alert must be in format like '15m', '1h', '2d'.")
            }
            if allDay, noAllDay {
                throw ValidationError("--all-day and --no-all-day cannot both be set.")
            }
        }

        public mutating func execute() async throws -> AgentResult {
            let ekSpan = parseSpan(span) ?? .thisEvent
            let isAllDay: Bool? = allDay ? true : (noAllDay ? false : nil)
            let bridge = CalendarBridge()
            let result = try await bridge.updateEvent(
                id: id,
                title: title,
                start: start.flatMap { parseCalendarDate($0) },
                end: end.flatMap { parseCalendarDate($0) },
                calendarId: calendar,
                location: location,
                notes: notes,
                url: url,
                isAllDay: isAllDay,
                alertOffset: alert.flatMap { parseAlertDuration($0) },
                span: ekSpan
            )
            return AgentResult(result)
        }
    }

    // MARK: - Delete

    public struct Delete: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete a calendar event."
        )

        @Argument(help: "Event ID or prefix to delete.")
        public var id: String

        @Flag(name: .long, help: "Required: confirm deletion without a prompt.")
        public var force: Bool = false

        @Option(name: .long, help: "Span for recurring events: 'this' or 'future' (default: this).")
        public var span: String = "this"

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard force else {
                throw ValidationError("--force is required. This operation cannot be undone.")
            }
            if parseSpan(span) == nil {
                throw ValidationError("--span must be 'this' or 'future'.")
            }
        }

        public mutating func execute() async throws -> AgentResult {
            let ekSpan = parseSpan(span) ?? .thisEvent
            let bridge = CalendarBridge()
            let result = try await bridge.deleteEvent(id: id, span: ekSpan)
            return AgentResult(result)
        }
    }

    // MARK: - SmartCreate

    public struct SmartCreate: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "smart-create",
            abstract: "Create an event from a natural language description using AI."
        )

        @Argument(help: "Natural language description, e.g. 'coffee with Alice tomorrow at 3pm'.")
        public var description: String

        @Option(name: .long, help: "AI provider: ollama, claude, or openai (default: ollama).")
        public var provider: String?

        @Option(name: .long, help: "Model name (provider-specific default).")
        public var model: String?

        @Option(name: .long, help: "API key for Claude provider.")
        public var apiKey: String?

        @Option(name: .long, help: "Calendar ID to create event in.")
        public var calendar: String?

        @Flag(name: .long, help: "Print parsed event JSON without creating it.")
        public var dryRun: Bool = false

        @Flag(name: .long, help: "Create even if conflicting events exist.")
        public var allowConflicts: Bool = false

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

            let systemPrompt = BuiltInTemplates.smartCreateCalendar.content
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
                let eventData = extractJSON(from: jsonStr),
                let parsed = try? JSONDecoder().decode(SmartEventSpec.self, from: eventData)
            else {
                throw CalendarBridgeError.aiParseError(jsonStr)
            }

            guard let startDate = parseCalendarDate(parsed.start) else {
                throw CalendarBridgeError.dateParseError(parsed.start)
            }
            let endDate: Date
            if let endStr = parsed.end, let parsedEnd = parseCalendarDate(endStr) {
                endDate = parsedEnd
            } else {
                endDate = startDate.addingTimeInterval(3600)
            }

            let bridge = CalendarBridge()

            // Check for conflicts (skipped when --allow-conflicts is set)
            var existingConflicts: [CalendarEvent] = []
            if !allowConflicts {
                let conflictOutcome = try await bridge.findConflicts(from: startDate, to: endDate)
                existingConflicts = conflictOutcome.results
                if conflictOutcome.timedOut {
                    fputs("Warning: conflict check did not complete within 15s — a conflicting event may have been missed.\n", stderr)
                }
            }

            if dryRun {
                return AgentResult(SmartCreateDryRunResult(spec: parsed, conflicts: existingConflicts))
            }

            if !existingConflicts.isEmpty {
                let titles = existingConflicts.map { $0.title }.joined(separator: ", ")
                throw SmartCalendarError.calendarConflict(
                    "Event conflicts with \(existingConflicts.count) existing event(s): \(titles)"
                )
            }

            let result = try await bridge.createEvent(
                title: parsed.title,
                start: startDate,
                end: endDate,
                calendarId: calendar,
                location: parsed.location,
                notes: parsed.notes,
                isAllDay: parsed.isAllDay ?? false
            )

            return AgentResult(result)
        }
    }

    // MARK: - Agenda

    public struct Agenda: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "agenda",
            abstract: "AI-generated briefing of upcoming events."
        )

        @Option(name: .long, help: "Number of days to include, 1-7 (default: 1).")
        public var days: Int = 1

        @Option(name: .long, help: "AI provider: ollama, claude, or openai (default: ollama).")
        public var provider: String?

        @Option(name: .long, help: "Model name (provider-specific default).")
        public var model: String?

        @Option(name: .long, help: "API key for Claude provider.")
        public var apiKey: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard days >= 1, days <= 7 else {
                throw ValidationError("--days must be between 1 and 7.")
            }
        }

        public mutating func execute() async throws -> AgentResult {
            let bridge = CalendarBridge()
            let start = Calendar.current.startOfDay(for: Date())
            let end = Calendar.current.date(byAdding: .day, value: days, to: start)!
            let agendaOutcome = try await bridge.listEvents(from: start, to: end)
            let events = agendaOutcome.results

            let aiProvider = try AIProviderFactory.make(
                providerFlag: provider,
                modelFlag: model,
                apiKeyFlag: apiKey
            )

            let dateFormatter = DateFormatter()
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateFormatter.dateFormat = "yyyy-MM-dd"
            let today = dateFormatter.string(from: Date())

            let eventSummary: String
            if events.isEmpty {
                eventSummary = "No events scheduled."
            } else {
                eventSummary = events.map { event in
                    let time = event.isAllDay
                        ? "all day"
                        : "\(event.startDate) – \(event.endDate)"
                    var parts = ["• \(event.title) [\(event.calendarTitle)] \(time)"]
                    if let loc = event.location { parts.append("  Location: \(loc)") }
                    if let n = event.notes { parts.append("  Notes: \(n.prefix(120))") }
                    return parts.joined(separator: "\n")
                }.joined(separator: "\n")
            }

            let userPrompt = """
            Today: \(today)
            Period: \(days == 1 ? "today" : "next \(days) days")
            Events:
            \(eventSummary)
            """

            // aiProvider.complete blocks via DispatchSemaphore — hop off the
            // cooperative pool.
            let briefing = try await detachBlocking {
                try aiProvider.complete(
                    prompt: userPrompt,
                    system: BuiltInTemplates.calendarBriefing.content
                )
            }

            var result: [String: String] = [
                "briefing": briefing,
                "days": "\(days)",
                "eventCount": "\(events.count)",
            ]
            // Flat [String:String] payload (not a model array), so this filters
            // by key directly; reuse FieldProjection.parse for the comma-split so
            // it matches everywhere.
            if let fieldList = FieldProjection.parse(output.fields) {
                result = result.filter { fieldList.contains($0.key) }
            }
            return AgentResult(result, warnings: CalendarCommand.timedOutWarnings(agendaOutcome.timedOut))
        }
    }

    // MARK: - Search

    public struct Search: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "search",
            abstract: "Search events by text across a date range."
        )

        @Argument(help: ArgumentHelp("Search query (matches title, notes, location).", valueName: "query"))
        public var positionalQuery: String?

        @Option(name: .long, help: "Search query (alternative to the positional argument).")
        public var query: String?

        @Option(name: [.customLong("from"), .customLong("after")], help: "Start date/time (default: 6 months ago). --after is the canonical cross-module name.")
        public var from: String?

        @Option(name: [.customLong("to"), .customLong("before")], help: "End date/time (default: 6 months from now). --before is the canonical cross-module name.")
        public var to: String?

        @Option(name: .long, help: "Calendar name to filter (case-insensitive; an exact match wins, otherwise substring fallback).")
        public var calendarName: String?

        @Option(name: .long, help: "Maximum results to return (default: 50).")
        public var limit: Int = 50

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            switch (positionalQuery, query) {
            case (.none, .none):
                throw ValidationError("A search query is required — pass it positionally or via --query.")
            case (.some, .some):
                throw ValidationError("Pass the search query either positionally or via --query, not both.")
            default:
                break
            }
            if let from, parseCalendarDate(from) == nil {
                throw ValidationError("--from must be in YYYY-MM-DD or ISO 8601 format.")
            }
            if let to, parseCalendarDate(to) == nil {
                throw ValidationError("--to must be in YYYY-MM-DD or ISO 8601 format.")
            }
            guard limit > 0 else {
                throw ValidationError("--limit must be positive.")
            }
        }

        public mutating func execute() async throws -> AgentResult {
            let now = Date()
            let cal = Calendar.current
            let startDate = from.flatMap { parseCalendarDate($0) }
                ?? cal.date(byAdding: .month, value: -6, to: now)!
            let endDate = to.flatMap { parseCalendarDate($0) }
                ?? cal.date(byAdding: .month, value: 6, to: now)!

            let bridge = CalendarBridge()
            var calendarId: String?
            if let name = calendarName {
                calendarId = try await resolveCalendarName(name, bridge: bridge)
            }
            let searchOutcome = try await bridge.listEvents(from: startDate, to: endDate, calendarId: calendarId)
            var events = searchOutcome.results

            let q = (positionalQuery ?? query ?? "").lowercased()
            events = events.filter { event in
                event.title.lowercased().contains(q)
                    || (event.notes?.lowercased().contains(q) == true)
                    || (event.location?.lowercased().contains(q) == true)
            }
            if events.count > limit {
                events = Array(events.prefix(limit))
            }

            return AgentResult(events, warnings: CalendarCommand.timedOutWarnings(searchOutcome.timedOut), fields: FieldProjection.parse(output.fields))
        }
    }

    // MARK: - Today

    public struct Today: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "today",
            abstract: "List events for today."
        )

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let (start, end) = parseRange("today")!
            let bridge = CalendarBridge()
            let outcome = try await bridge.listEvents(from: start, to: end, calendarId: nil)
            return AgentResult(outcome.results, warnings: CalendarCommand.timedOutWarnings(outcome.timedOut), fields: FieldProjection.parse(output.fields))
        }
    }

    // MARK: - Remaining

    public struct Remaining: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "remaining",
            abstract: "List events from now until end of today."
        )

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let now = Date()
            let endOfToday = parseRange("today")!.end
            let bridge = CalendarBridge()
            let outcome = try await bridge.listEvents(from: now, to: endOfToday, calendarId: nil)
            return AgentResult(outcome.results, warnings: CalendarCommand.timedOutWarnings(outcome.timedOut), fields: FieldProjection.parse(output.fields))
        }
    }

    // MARK: - Conflicts

    public struct Conflicts: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "conflicts",
            abstract: "Find overlapping calendar events in a time window."
        )

        @Option(name: [.customLong("from"), .customLong("after")], help: "Start date/time (default: start of today). --after is the canonical cross-module name.")
        public var from: String?

        @Option(name: [.customLong("to"), .customLong("before")], help: "End date/time (default: end of today). --before is the canonical cross-module name.")
        public var to: String?

        @Option(name: .long, help: "Date range shorthand: today, today+N, week, month. Overrides --from/--to.")
        public var range: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            if let from, parseCalendarDate(from) == nil {
                throw ValidationError("--from must be in YYYY-MM-DD or ISO 8601 format.")
            }
            if let to, parseCalendarDate(to) == nil {
                throw ValidationError("--to must be in YYYY-MM-DD or ISO 8601 format.")
            }
            if let range, parseRange(range) == nil {
                throw ValidationError("--range must be: today, today+N, week, or month.")
            }
        }

        public mutating func execute() async throws -> AgentResult {
            let startDate: Date
            let endDate: Date
            if let range, let (rangeStart, rangeEnd) = parseRange(range) {
                startDate = rangeStart
                endDate = rangeEnd
            } else {
                let cal = Calendar.current
                startDate = from.flatMap { parseCalendarDate($0) }
                    ?? cal.startOfDay(for: Date())
                endDate = to.flatMap { parseCalendarDate($0) }
                    ?? cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
            }

            let bridge = CalendarBridge()
            let outcome = try await bridge.listEvents(from: startDate, to: endDate)
            let events = outcome.results

            // Pre-parse dates once; events with unparseable dates are skipped
            let parsedEvents = events.compactMap { event -> (event: CalendarEvent, start: Date, end: Date)? in
                guard
                    let start = parseCalendarDate(event.startDate),
                    let end = parseCalendarDate(event.endDate)
                else { return nil }
                return (event, start, end)
            }

            // Find all pairwise overlapping events
            // Two ranges overlap iff a starts before b ends and b starts before a ends
            var conflicts: [CalendarConflict] = []
            for i in 0 ..< parsedEvents.count {
                for j in (i + 1) ..< parsedEvents.count {
                    let a = parsedEvents[i]
                    let b = parsedEvents[j]
                    guard a.start < b.end, b.start < a.end else { continue }
                    let overlapStart = max(a.start, b.start)
                    let overlapEnd = min(a.end, b.end)
                    let overlapMinutes = max(0, Int(overlapEnd.timeIntervalSince(overlapStart) / 60))
                    conflicts.append(CalendarConflict(
                        events: [a.event, b.event],
                        overlapStart: formatEventDate(overlapStart),
                        overlapEnd: formatEventDate(overlapEnd),
                        overlapMinutes: overlapMinutes
                    ))
                }
            }

            return AgentResult(conflicts, warnings: CalendarCommand.timedOutWarnings(outcome.timedOut))
        }
    }

    // MARK: - Upcoming

    public struct Upcoming: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "upcoming",
            abstract: "List events for the next 7 days."
        )

        @OptionGroup public var output: OutputOptions

        @Option(name: .long, help: "Default page size when --page-size is omitted (default: 50).")
        public var limit: Int = 50

        @OptionGroup public var pagination: PaginationOptions

        public init() {}

        public mutating func validate() throws {
            guard limit > 0 else {
                throw ValidationError("--limit must be positive.")
            }
        }

        public mutating func execute() async throws -> AgentResult {
            let (start, end) = parseRange("today+6")! // today + 6 more days = 7 days total
            let bridge = CalendarBridge()
            let outcome = try await bridge.listEvents(from: start, to: end, calendarId: nil)
            let events = outcome.results
            let fieldList = FieldProjection.parse(output.fields)

            if pagination.isActive {
                let hash = Pagination.filterHash([:])
                let (offset, pageSize) = try Pagination.resolve(
                    pagination, defaultPageSize: limit, filterHash: hash
                )
                let page = try Pagination.paginate(
                    all: events, offset: offset, pageSize: pageSize, filterHash: hash
                )
                return .page(page, warnings: CalendarCommand.timedOutWarnings(outcome.timedOut), fields: fieldList)
            }

            return AgentResult(events, warnings: CalendarCommand.timedOutWarnings(outcome.timedOut), fields: fieldList)
        }
    }
}

// MARK: - Shared helpers

/// Ambiguous `--calendar-name` is a usage-class error: the derived agent code
/// `invalid_calendar_name` routes to exit 2 via `PippinExitCode.classify`'s
/// `invalid_` prefix rule (a no-match miss throws
/// `CalendarBridgeError.calendarNotFound` → `calendar_not_found` → exit 3
/// instead — the old shared `calendar_name_error` fell to the generic exit 5).
enum CalendarNameResolutionError: LocalizedError {
    case invalidCalendarName(String)

    var errorDescription: String? {
        if case let .invalidCalendarName(msg) = self { return msg }
        return nil
    }
}

/// Match calendars by name. A unique exact (case-insensitive) match wins, so a
/// calendar literally named "Family" stays reachable when "Family Calendar"
/// also exists; only when nothing matches exactly does it fall back to
/// substring matching. Pure so it's unit-testable without an EKEventStore.
func matchCalendars(named name: String, in calendars: [CalendarInfo]) -> [CalendarInfo] {
    let exact = calendars.filter { $0.title.caseInsensitiveCompare(name) == .orderedSame }
    if !exact.isEmpty { return exact }
    return calendars.filter { $0.title.localizedCaseInsensitiveContains(name) }
}

/// `pippin/MCP/InProcessTools.swift` has its own `resolveCalendarName` with the
/// same body, but both now share the module-internal `matchCalendars(named:in:)`
/// + `CalendarNameResolutionError`, so the two paths emit identical envelopes.
private func resolveCalendarName(_ name: String, bridge: CalendarBridge) async throws -> String {
    let matches = try await matchCalendars(named: name, in: bridge.listCalendars())
    guard !matches.isEmpty else {
        throw CalendarBridgeError.calendarNotFound(name)
    }
    guard matches.count == 1 else {
        let names = matches.map { $0.title }.joined(separator: ", ")
        throw CalendarNameResolutionError.invalidCalendarName(
            "'\(name)' matches multiple calendars: \(names). Use a more specific name."
        )
    }
    return matches[0].id
}

// MARK: - SmartCreate helpers

private struct SmartEventSpec: Codable {
    let title: String
    let start: String
    let end: String?
    let location: String?
    let isAllDay: Bool?
    let notes: String?
}

/// Extract the first complete JSON object from a text response.
func extractJSON(from text: String) -> Data? {
    guard
        let startIdx = text.firstIndex(of: "{"),
        let endIdx = text.lastIndex(of: "}"),
        startIdx <= endIdx
    else { return nil }
    return String(text[startIdx ... endIdx]).data(using: .utf8)
}

/// Dry-run output for `calendar smart-create`: parsed spec + any detected conflicts.
private struct SmartCreateDryRunResult: Encodable {
    let spec: SmartEventSpec
    let conflicts: [CalendarEvent]
}

/// Error thrown by `calendar smart-create` when conflicts are detected and
/// `--allow-conflicts` was not passed.
private enum SmartCalendarError: LocalizedError {
    case calendarConflict(String)

    var errorDescription: String? {
        if case let .calendarConflict(msg) = self { return msg }
        return nil
    }
}
