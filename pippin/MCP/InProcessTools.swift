import Foundation

/// In-process handlers for the safe (non-JXA) read-only MCP tools: EventKit
/// (Calendar/Reminders) and CNContactStore (Contacts) reads. Each handler
/// calls the same PippinLib bridge the CLI command uses and returns the exact
/// envelope-v1 JSON string a `pippin <cmd> --format agent` child would print,
/// so MCP clients can't tell the paths apart. Everything else (JXA bridges,
/// AI tools, and all writes) stays on the child path this round.
///
/// Handlers throw on failure; the dispatcher wraps thrown errors via
/// `errorEnvelope` into the same error envelope `printAgentError` emits.
enum MCPInProcessTools {
    // MARK: - Envelope encoding

    /// String-returning twin of `printAgentJSON` — same `AgentOkEnvelope`
    /// encoder, so key order and shape match the child's stdout byte-for-byte.
    static func okEnvelope(
        _ data: some Encodable,
        startedAt: Date,
        warnings: [String]? = nil
    ) throws -> String {
        let envelope = AgentOkEnvelope(
            v: AGENT_SCHEMA_VERSION,
            status: "ok",
            durationMs: elapsedMs(since: startedAt),
            data: data,
            warnings: warnings
        )
        let bytes = try JSONEncoder().encode(envelope)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// String-returning twin of `printAgentProjectedJSON` for tools that accept
    /// a `fields` projection (contacts_search). The hand-built frame must stay
    /// in lockstep with `AgentOkEnvelope` (v/status/duration_ms/warnings).
    static func projectedEnvelope(
        _ data: some Encodable,
        fields: [String],
        startedAt: Date,
        warnings: [String]? = nil
    ) throws -> String {
        let projected = try FieldProjection.projectedObject(data, fields: fields)
        var envelope: [String: Any] = [
            "v": AGENT_SCHEMA_VERSION,
            "status": "ok",
            "duration_ms": elapsedMs(since: startedAt),
            "data": projected,
        ]
        if let warnings, !warnings.isEmpty {
            envelope["warnings"] = warnings
        }
        let bytes = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        return String(decoding: bytes, as: UTF8.self)
    }

    /// String-returning twin of `printAgentError` — same `AgentError.from`
    /// code/message/remediation derivation the child's error path uses.
    static func errorEnvelope(_ error: Error, startedAt: Date) -> String {
        let envelope = AgentErrorEnvelope(
            v: AGENT_SCHEMA_VERSION,
            status: "error",
            durationMs: elapsedMs(since: startedAt),
            error: AgentError.from(error).error
        )
        guard let bytes = try? JSONEncoder().encode(envelope) else {
            // AgentErrorEnvelope is a fixed struct of strings/ints — encoding
            // can't realistically fail; keep the tool result non-empty if it does.
            return #"{"v":1,"status":"error","duration_ms":0,"error":{"code":"unknown_error","message":"failed to encode error envelope"}}"#
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func elapsedMs(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }

    // MARK: - Argument helpers

    /// Parse an optional date argument, throwing (like the CLI's `validate()`)
    /// when the value is present but unparseable, instead of silently ignoring it.
    private static func dateArg(_ args: JSONValue?, _ key: String) throws -> Date? {
        guard let raw = ArgHelpers.string(args, key) else { return nil }
        guard let date = parseCalendarDate(raw) else {
            throw MCPToolArgError.wrongType(field: key, expected: "a date in YYYY-MM-DD or ISO 8601 format")
        }
        return date
    }

    private static func limitArg(_ args: JSONValue?, default defaultValue: Int) throws -> Int {
        guard let raw = ArgHelpers.int(args, "limit") else { return defaultValue }
        guard raw > 0 else {
            throw MCPToolArgError.wrongType(field: "limit", expected: "a positive integer")
        }
        return Int(clamping: raw)
    }

    // MARK: - Calendar (EventKit reads)

    static func calendarList(_ args: JSONValue?) async throws -> String {
        let startedAt = Date()
        var calendars = try await CalendarBridge().listCalendars()
        if let typeFilter = ArgHelpers.string(args, "type") {
            let allowedTypes = typeFilter.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            calendars = calendars.filter { allowedTypes.contains($0.type.lowercased()) }
        }
        return try okEnvelope(calendars, startedAt: startedAt)
    }

    static func calendarEvents(_ args: JSONValue?) async throws -> String {
        let startedAt = Date()
        let limit = try limitArg(args, default: 50)
        let calendarArg = ArgHelpers.string(args, "calendar")
        let calendarName = ArgHelpers.string(args, "calendarName")
        if calendarArg != nil, calendarName != nil {
            throw MCPToolArgError.wrongType(
                field: "calendar",
                expected: "omitted when calendarName is set (they are mutually exclusive)"
            )
        }
        let startDate: Date
        let endDate: Date
        if let range = ArgHelpers.string(args, "range") {
            guard let (rangeStart, rangeEnd) = parseRange(range) else {
                throw MCPToolArgError.wrongType(field: "range", expected: "today, today+N (e.g. today+3), week, or month")
            }
            startDate = rangeStart
            endDate = rangeEnd
        } else {
            startDate = try dateArg(args, "from") ?? Calendar.current.startOfDay(for: Date())
            endDate = try dateArg(args, "to") ?? Calendar.current.date(
                byAdding: .day, value: 1,
                to: Calendar.current.startOfDay(for: Date())
            )!
        }
        let bridge = CalendarBridge()
        var calendarId = calendarArg
        if let name = calendarName {
            calendarId = try await resolveCalendarName(name, bridge: bridge)
        }
        let outcome = try await bridge.listEvents(from: startDate, to: endDate, calendarId: calendarId)
        var events = outcome.results
        if events.count > limit {
            events = Array(events.prefix(limit))
        }
        return try okEnvelope(
            events,
            startedAt: startedAt,
            warnings: CalendarCommand.timedOutWarnings(outcome.timedOut)
        )
    }

    static func calendarToday(_: JSONValue?) async throws -> String {
        let (start, end) = parseRange("today")!
        return try await eventsEnvelope(from: start, to: end)
    }

    static func calendarRemaining(_: JSONValue?) async throws -> String {
        let endOfToday = parseRange("today")!.end
        return try await eventsEnvelope(from: Date(), to: endOfToday)
    }

    static func calendarUpcoming(_: JSONValue?) async throws -> String {
        let (start, end) = parseRange("today+6")! // today + 6 more days = 7 days total
        return try await eventsEnvelope(from: start, to: end)
    }

    static func calendarSearch(_ args: JSONValue?) async throws -> String {
        let startedAt = Date()
        let query = try ArgHelpers.requiredString(args, "query")
        let limit = try limitArg(args, default: 50)
        let now = Date()
        let cal = Calendar.current
        let startDate = try dateArg(args, "from") ?? cal.date(byAdding: .month, value: -6, to: now)!
        let endDate = try dateArg(args, "to") ?? cal.date(byAdding: .month, value: 6, to: now)!
        let bridge = CalendarBridge()
        var calendarId: String?
        if let name = ArgHelpers.string(args, "calendarName") {
            calendarId = try await resolveCalendarName(name, bridge: bridge)
        }
        let outcome = try await bridge.listEvents(from: startDate, to: endDate, calendarId: calendarId)
        let q = query.lowercased()
        var events = outcome.results.filter { event in
            event.title.lowercased().contains(q)
                || (event.notes?.lowercased().contains(q) == true)
                || (event.location?.lowercased().contains(q) == true)
        }
        if events.count > limit {
            events = Array(events.prefix(limit))
        }
        return try okEnvelope(
            events,
            startedAt: startedAt,
            warnings: CalendarCommand.timedOutWarnings(outcome.timedOut)
        )
    }

    /// Shared body for the fixed-window event tools (today/remaining/upcoming).
    private static func eventsEnvelope(from start: Date, to end: Date) async throws -> String {
        let startedAt = Date()
        let outcome = try await CalendarBridge().listEvents(from: start, to: end, calendarId: nil)
        return try okEnvelope(
            outcome.results,
            startedAt: startedAt,
            warnings: CalendarCommand.timedOutWarnings(outcome.timedOut)
        )
    }

    // MARK: - Reminders (EventKit reads)

    static func remindersLists(_: JSONValue?) async throws -> String {
        let startedAt = Date()
        let lists = try await RemindersBridge().listReminderLists()
        return try okEnvelope(lists, startedAt: startedAt)
    }

    static func remindersList(_ args: JSONValue?) async throws -> String {
        let startedAt = Date()
        let limit = try limitArg(args, default: 50)
        var priority: Int?
        if let raw = ArgHelpers.string(args, "priority") {
            guard let parsed = parseReminderPriority(raw) else {
                throw MCPToolArgError.wrongType(field: "priority", expected: "high, medium, low, or none (or 0, 1, 5, 9)")
            }
            priority = parsed
        }
        let outcome = try await RemindersBridge().listReminders(
            listId: ArgHelpers.string(args, "list"),
            completed: ArgHelpers.bool(args, "completed") == true,
            dueBefore: dateArg(args, "dueBefore"),
            dueAfter: dateArg(args, "dueAfter"),
            createdAfter: dateArg(args, "createdAfter"),
            modifiedAfter: dateArg(args, "modifiedAfter"),
            priority: priority,
            limit: limit
        )
        return try okEnvelope(
            outcome.results,
            startedAt: startedAt,
            warnings: outcome.timedOut ? [RemindersCommand.List.timedOutHint] : nil
        )
    }

    static func remindersShow(_ args: JSONValue?) async throws -> String {
        let startedAt = Date()
        let id = try ArgHelpers.requiredString(args, "id")
        let reminder = try await RemindersBridge().showReminder(id: id)
        return try okEnvelope(reminder, startedAt: startedAt)
    }

    static func remindersSearch(_ args: JSONValue?) async throws -> String {
        let startedAt = Date()
        let query = try ArgHelpers.requiredString(args, "query")
        let limit = try limitArg(args, default: 50)
        let outcome = try await RemindersBridge().searchReminders(
            query: query,
            listId: ArgHelpers.string(args, "list"),
            completed: ArgHelpers.bool(args, "completed") == true,
            limit: limit
        )
        return try okEnvelope(
            outcome.results,
            startedAt: startedAt,
            warnings: outcome.timedOut ? [RemindersCommand.Search.timedOutHint] : nil
        )
    }

    // MARK: - Contacts (CNContactStore reads)

    static func contactsSearch(_ args: JSONValue?) async throws -> String {
        let startedAt = Date()
        let query = try ArgHelpers.requiredString(args, "query")
        let fieldList = FieldProjection.parse(ArgHelpers.string(args, "fields"))
        let contacts: [ContactInfo]
        let timedOut: Bool
        if ArgHelpers.bool(args, "email") == true {
            // searchByEmail enumerates the full contact store (sync); hop off the pool.
            let outcome = try await detachBlocking { try ContactsBridge.searchByEmail(query, fields: fieldList) }
            contacts = outcome.results
            timedOut = outcome.timedOut
        } else {
            // Name search is framework-bounded; still hop (sync store fetch).
            contacts = try await detachBlocking { try ContactsBridge.searchByName(query, fields: fieldList) }
            timedOut = false
        }
        // Mirrors the CLI's default `--limit 50`; the MCP schema exposes no limit.
        let limited = Array(contacts.prefix(50))
        let warnings = timedOut ? [ContactsCommand.timedOutHint] : nil
        if let fieldList, !fieldList.isEmpty {
            return try projectedEnvelope(limited, fields: fieldList, startedAt: startedAt, warnings: warnings)
        }
        return try okEnvelope(limited, startedAt: startedAt, warnings: warnings)
    }

    static func contactsShow(_ args: JSONValue?) async throws -> String {
        let startedAt = Date()
        let identifier = try ArgHelpers.requiredString(args, "identifier")
        // Keyed CNContactStore fetch is sync; hop off the pool for MCP fanout.
        let contact = try await detachBlocking { try ContactsBridge.getContact(identifier) }
        return try okEnvelope(contact, startedAt: startedAt)
    }
}

// MARK: - Calendar name resolution

/// Duplicated from `CalendarCommand.resolveCalendarName` (file-private there,
/// and Commands/ is off-limits to the MCP layer). The type name and messages
/// are kept identical so the agent error envelope (`code:
/// "calendar_name_error"`) matches the child path exactly.
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
