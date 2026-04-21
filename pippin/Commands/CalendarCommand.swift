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

    // MARK: - List (calendars)

    public struct ListCalendars: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List calendars."
        )

        @OptionGroup public var output: OutputOptions

        @Option(name: .long, help: "Filter by calendar type: local, calDAV, exchange, subscription, birthday.")
        public var type: String?

        public init() {}

        public mutating func run() async throws {
            let bridge = CalendarBridge()
            var calendars = try await bridge.listCalendars()
            if let typeFilter = type {
                let allowedTypes = typeFilter.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                calendars = calendars.filter { allowedTypes.contains($0.type.lowercased()) }
            }
            if output.isJSON {
                try printJSON(calendars)
            } else if output.isAgent {
                try output.printAgent(calendars)
            } else {
                if calendars.isEmpty {
                    print("No calendars found.")
                    return
                }
                let rows = calendars.map { [$0.title, $0.type, $0.account, $0.color] }
                print(TextFormatter.table(
                    headers: ["NAME", "TYPE", "ACCOUNT", "COLOR"],
                    rows: rows,
                    columnWidths: [25, 12, 25, 8]
                ))
            }
        }
    }

    // MARK: - Events

    public struct Events: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "events",
            abstract: "List calendar events. Defaults to today."
        )

        @Option(name: .long, help: "Start date/time: YYYY-MM-DD or ISO 8601 (default: start of today).")
        public var from: String?

        @Option(name: .long, help: "End date/time: YYYY-MM-DD or ISO 8601 (default: end of today).")
        public var to: String?

        @Option(name: .long, help: "Calendar ID to filter events.")
        public var calendar: String?

        @Option(name: .long, help: "Calendar name to filter events (case-insensitive).")
        public var calendarName: String?

        @Option(name: .long, help: "Maximum events to return (default: 50).")
        public var limit: Int = 50

        @Option(name: .long, help: "Comma-separated JSON field names to include (e.g. title,startDate,endDate). JSON output only.")
        public var fields: String?

        @Option(name: .long, help: "Date range shorthand: today, today+N (e.g. today+3), week, or month. Overrides --from/--to.")
        public var range: String?

        @Option(name: .long, help: "Calendar types to include: local, calDAV, exchange, subscription, birthday.")
        public var type: String?

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

        public mutating func run() async throws {
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
            var events = try await bridge.listEvents(from: startDate, to: endDate, calendarId: calendarId)

            if let typeFilter = type {
                let allowedTypes = typeFilter.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                let allCalendars = try await bridge.listCalendars()
                let matchingIds = allCalendars
                    .filter { allowedTypes.contains($0.type.lowercased()) }
                    .map { $0.id }
                events = events.filter { matchingIds.contains($0.calendarId) }
            }

            if events.count > limit {
                events = Array(events.prefix(limit))
            }

            if output.isJSON {
                let fieldList = fields?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let data = try events.jsonData(fields: fieldList)
                print(String(data: data, encoding: .utf8)!)
            } else if output.isAgent {
                try output.printAgent(events)
            } else {
                printEventsTable(events)
            }
        }
    }

    // MARK: - Show

    public struct Show: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show full details for a single event by ID."
        )

        @Argument(help: "Event ID or prefix from `pippin calendar events` output.")
        public var id: String

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            let bridge = CalendarBridge()
            let event = try await bridge.getEvent(id: id)
            if output.isJSON {
                try printJSON(event)
            } else if output.isAgent {
                try output.printAgent(event)
            } else {
                printEventCard(event)
            }
        }
    }

    // MARK: - Create

    public struct Create: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create a new calendar event."
        )

        @Option(name: .long, help: "Event title (required).")
        public var title: String

        @Option(name: .long, help: "Start date/time: YYYY-MM-DD or ISO 8601 (required).")
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

        public mutating func run() async throws {
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

            if output.isJSON {
                try printJSON(result)
            } else if output.isAgent {
                try output.printAgent(result)
            } else {
                print(TextFormatter.actionResult(success: result.success, action: result.action, details: result.details))
            }
        }
    }

    // MARK: - Edit

    public struct Edit: AsyncParsableCommand {
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

        public mutating func run() async throws {
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
            if output.isJSON {
                try printJSON(result)
            } else if output.isAgent {
                try output.printAgent(result)
            } else {
                print(TextFormatter.actionResult(success: result.success, action: result.action, details: result.details))
            }
        }
    }

    // MARK: - Delete

    public struct Delete: AsyncParsableCommand {
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

        public mutating func run() async throws {
            let ekSpan = parseSpan(span) ?? .thisEvent
            let bridge = CalendarBridge()
            let result = try await bridge.deleteEvent(id: id, span: ekSpan)
            if output.isJSON {
                try printJSON(result)
            } else if output.isAgent {
                try output.printAgent(result)
            } else {
                print(TextFormatter.actionResult(success: result.success, action: result.action, details: result.details))
            }
        }
    }

    // MARK: - SmartCreate

    public struct SmartCreate: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "smart-create",
            abstract: "Create an event from a natural language description using AI."
        )

        @Argument(help: "Natural language description, e.g. 'coffee with Alice tomorrow at 3pm'.")
        public var description: String

        @Option(name: .long, help: "AI provider: ollama or claude (default: ollama).")
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

            let systemPrompt = BuiltInTemplates.smartCreateCalendar.content
                .replacingOccurrences(of: "{{CURRENT_DATE}}", with: today)
                .replacingOccurrences(of: "{{CURRENT_TIME}}", with: currentTime)

            let jsonStr = try aiProvider.complete(prompt: description, system: systemPrompt)

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
                existingConflicts = try await bridge.findConflicts(from: startDate, to: endDate)
            }

            if dryRun {
                let dryRunResult = SmartCreateDryRunResult(spec: parsed, conflicts: existingConflicts)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try print(String(data: encoder.encode(dryRunResult), encoding: .utf8)!)
                return
            }

            if !existingConflicts.isEmpty {
                if output.isAgent {
                    let titles = existingConflicts.map { $0.title }.joined(separator: ", ")
                    throw SmartCalendarError.calendarConflict(
                        "Event conflicts with \(existingConflicts.count) existing event(s): \(titles)"
                    )
                } else {
                    let titles = existingConflicts.map { $0.title }.joined(separator: ", ")
                    fputs("Warning: \(existingConflicts.count) conflict(s) with: \(titles)\n", stderr)
                }
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

            if output.isJSON {
                try printJSON(result)
            } else if output.isAgent {
                try output.printAgent(result)
            } else {
                print(TextFormatter.actionResult(success: result.success, action: result.action, details: result.details))
            }
        }
    }

    // MARK: - Agenda

    public struct Agenda: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "agenda",
            abstract: "AI-generated briefing of upcoming events."
        )

        @Option(name: .long, help: "Number of days to include, 1-7 (default: 1).")
        public var days: Int = 1

        @Option(name: .long, help: "AI provider: ollama or claude (default: ollama).")
        public var provider: String?

        @Option(name: .long, help: "Model name (provider-specific default).")
        public var model: String?

        @Option(name: .long, help: "API key for Claude provider.")
        public var apiKey: String?

        @Option(name: .long, help: "Comma-separated JSON field names to include (briefing, days, eventCount). JSON output only.")
        public var fields: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard days >= 1, days <= 7 else {
                throw ValidationError("--days must be between 1 and 7.")
            }
        }

        public mutating func run() async throws {
            let bridge = CalendarBridge()
            let start = Calendar.current.startOfDay(for: Date())
            let end = Calendar.current.date(byAdding: .day, value: days, to: start)!
            let events = try await bridge.listEvents(from: start, to: end)

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

            let briefing = try aiProvider.complete(
                prompt: userPrompt,
                system: BuiltInTemplates.calendarBriefing.content
            )

            var result: [String: String] = [
                "briefing": briefing,
                "days": "\(days)",
                "eventCount": "\(events.count)",
            ]
            if let fieldList = fields?.components(separatedBy: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                result = result.filter { fieldList.contains($0.key) }
            }
            if output.isJSON {
                try printJSON(result)
            } else if output.isAgent {
                try output.printAgent(result)
            } else {
                print(briefing)
            }
        }
    }

    // MARK: - Search

    public struct Search: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "search",
            abstract: "Search events by text across a date range."
        )

        @Option(name: .long, help: "Search query (required).")
        public var query: String

        @Option(name: .long, help: "Start date/time (default: 6 months ago).")
        public var from: String?

        @Option(name: .long, help: "End date/time (default: 6 months from now).")
        public var to: String?

        @Option(name: .long, help: "Calendar name to filter (case-insensitive).")
        public var calendarName: String?

        @Option(name: .long, help: "Maximum results to return (default: 50).")
        public var limit: Int = 50

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
        }

        public mutating func run() async throws {
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
            var events = try await bridge.listEvents(from: startDate, to: endDate, calendarId: calendarId)

            let q = query.lowercased()
            events = events.filter { event in
                event.title.lowercased().contains(q)
                    || (event.notes?.lowercased().contains(q) == true)
                    || (event.location?.lowercased().contains(q) == true)
            }
            if events.count > limit {
                events = Array(events.prefix(limit))
            }

            if output.isJSON {
                try printJSON(events)
            } else if output.isAgent {
                try output.printAgent(events)
            } else {
                printEventsTable(events)
            }
        }
    }

    // MARK: - Today

    public struct Today: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "today",
            abstract: "List events for today."
        )

        @OptionGroup public var output: OutputOptions

        @Option(name: .long, help: "Comma-separated JSON field names to include. JSON output only.")
        public var fields: String?

        public init() {}

        public mutating func run() async throws {
            let (start, end) = parseRange("today")!
            let bridge = CalendarBridge()
            let events = try await bridge.listEvents(from: start, to: end, calendarId: nil)
            let fieldList = fields?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if output.isJSON {
                let data = try events.jsonData(fields: fieldList)
                print(String(data: data, encoding: .utf8)!)
            } else if output.isAgent {
                try output.printAgent(events)
            } else {
                printEventsTable(events)
            }
        }
    }

    // MARK: - Remaining

    public struct Remaining: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "remaining",
            abstract: "List events from now until end of today."
        )

        @OptionGroup public var output: OutputOptions

        @Option(name: .long, help: "Comma-separated JSON field names to include. JSON output only.")
        public var fields: String?

        public init() {}

        public mutating func run() async throws {
            let now = Date()
            let endOfToday = parseRange("today")!.end
            let bridge = CalendarBridge()
            let events = try await bridge.listEvents(from: now, to: endOfToday, calendarId: nil)
            let fieldList = fields?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if output.isJSON {
                let data = try events.jsonData(fields: fieldList)
                print(String(data: data, encoding: .utf8)!)
            } else if output.isAgent {
                try output.printAgent(events)
            } else {
                printEventsTable(events)
            }
        }
    }

    // MARK: - Conflicts

    public struct Conflicts: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "conflicts",
            abstract: "Find overlapping calendar events in a time window."
        )

        @Option(name: .long, help: "Start date/time (default: start of today).")
        public var from: String?

        @Option(name: .long, help: "End date/time (default: end of today).")
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

        public mutating func run() async throws {
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
            let events = try await bridge.listEvents(from: startDate, to: endDate)

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

            if output.isJSON {
                try printJSON(conflicts)
            } else if output.isAgent {
                try output.printAgent(conflicts)
            } else {
                if conflicts.isEmpty {
                    print("No conflicts found.")
                } else {
                    print("Found \(conflicts.count) conflict\(conflicts.count == 1 ? "" : "s"):")
                    for conflict in conflicts {
                        let titles = conflict.events.map { $0.title }.joined(separator: " ↔ ")
                        print("  • \(titles) [\(conflict.overlapMinutes) min overlap]")
                    }
                }
            }
        }
    }

    // MARK: - Upcoming

    public struct Upcoming: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "upcoming",
            abstract: "List events for the next 7 days."
        )

        @OptionGroup public var output: OutputOptions

        @Option(name: .long, help: "Comma-separated JSON field names to include. JSON output only.")
        public var fields: String?

        public init() {}

        public mutating func run() async throws {
            let (start, end) = parseRange("today+6")! // today + 6 more days = 7 days total
            let bridge = CalendarBridge()
            let events = try await bridge.listEvents(from: start, to: end, calendarId: nil)
            let fieldList = fields?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if output.isJSON {
                let data = try events.jsonData(fields: fieldList)
                print(String(data: data, encoding: .utf8)!)
            } else if output.isAgent {
                try output.printAgent(events)
            } else {
                printEventsTable(events)
            }
        }
    }
}

// MARK: - Shared helpers

private struct CalendarNameError: LocalizedError {
    let errorDescription: String?
}

private func resolveCalendarName(_ name: String, bridge: CalendarBridge) async throws -> String {
    let calendars = try await bridge.listCalendars()
    let matches = calendars.filter { $0.title.localizedCaseInsensitiveContains(name) }
    guard !matches.isEmpty else {
        throw CalendarNameError(errorDescription: "No calendar found matching '\(name)'.")
    }
    guard matches.count == 1 else {
        let names = matches.map { $0.title }.joined(separator: ", ")
        throw CalendarNameError(errorDescription: "'\(name)' matches multiple calendars: \(names). Use a more specific name.")
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

/// Error thrown by `calendar smart-create` in agent mode when conflicts are detected.
private enum SmartCalendarError: LocalizedError {
    case calendarConflict(String)

    var errorDescription: String? {
        if case let .calendarConflict(msg) = self { return msg }
        return nil
    }
}

// MARK: - Text output helpers

private func printEventsTable(_ events: [CalendarEvent]) {
    if events.isEmpty {
        print("No events found.")
        return
    }
    let rows = events.map { event -> [String] in
        let shortId = String(event.id.prefix(8))
        let time = event.isAllDay
            ? "all-day"
            : TextFormatter.compactDate(event.startDate)
        return [
            shortId,
            time,
            TextFormatter.truncate(event.calendarTitle, to: 15),
            TextFormatter.truncate(event.title, to: 30),
        ]
    }
    print(TextFormatter.table(
        headers: ["ID", "START", "CALENDAR", "TITLE"],
        rows: rows,
        columnWidths: [10, 18, 17, 32]
    ))
}

private func printEventCard(_ event: CalendarEvent) {
    var fields: [(String, String)] = [
        ("ID", event.id),
        ("Title", event.title),
        ("Calendar", event.calendarTitle),
        ("Start", event.startDate),
        ("End", event.endDate),
        ("All Day", event.isAllDay ? "yes" : "no"),
    ]
    if let loc = event.location { fields.append(("Location", loc)) }
    if let url = event.url { fields.append(("URL", url)) }
    if let rec = event.recurrence { fields.append(("Recurrence", rec)) }
    if event.status != "none" { fields.append(("Status", event.status)) }
    if let attendees = event.attendees, !attendees.isEmpty {
        let attStr: String = attendees.map { a -> String in
            let name = a.name ?? "Unknown"
            let emailStr = a.email.map { " <\($0)>" } ?? ""
            return "\(name)\(emailStr) [\(a.status)]"
        }.joined(separator: "\n")
        fields.append(("Attendees", attStr))
    }
    if let notes = event.notes { fields.append(("Notes", notes)) }
    if let alerts = event.alerts, !alerts.isEmpty {
        fields.append(("Alerts", alerts.joined(separator: "\n")))
    }
    print(TextFormatter.card(fields: fields))
}
