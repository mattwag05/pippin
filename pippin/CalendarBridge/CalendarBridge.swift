import EventKit
import Foundation

public enum CalendarBridgeError: LocalizedError, Sendable {
    case accessDenied
    case eventNotFound(String)
    case calendarNotFound(String)
    case saveFailed(String)
    case ambiguousId(String)
    case dateParseError(String)
    case aiParseError(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            return """
            Calendar access denied.
            → Open System Settings > Privacy & Security > Calendars and enable the
              app that launches pippin (your terminal, or the MCP/agent client).
              The grant attaches to the launching app, not the pippin binary; a
              background agent that can't show the prompt needs `pippin calendar
              list` run once in a terminal first. Then retry.
            """
        case let .eventNotFound(id):
            return "Event not found: \(id)"
        case let .calendarNotFound(id):
            return "Calendar not found: \(id)"
        case let .saveFailed(msg):
            return "Failed to save event: \(msg)"
        case let .ambiguousId(id):
            return "Ambiguous ID prefix '\(id)' — matches multiple events. Use more characters."
        case let .dateParseError(value):
            return "Could not parse date from AI response: \(value)"
        case let .aiParseError(detail):
            return "AI response could not be parsed as event JSON: \(detail)"
        }
    }
}

extension CalendarBridgeError: RemediableError {
    public var remediation: Remediation? {
        switch self {
        case .accessDenied:
            return .privacyAccess(
                permission: "Calendar",
                listCommand: "pippin calendar list",
                doctorCheck: "Calendar access"
            )
        default:
            return nil
        }
    }
}

public final class CalendarBridge: @unchecked Sendable {
    private let store: EKEventStore

    public init() {
        store = EKEventStore()
    }

    // MARK: - Soft timeout

    /// Outcome of an event query whose underlying `store.events(matching:)` walk
    /// is bounded by `fetchEventsSync`'s 15s wall-clock cap. `timedOut` is
    /// surfaced as a "partial results" advisory, mirroring
    /// `RemindersBridge.Outcome` / `ContactsBridge.Outcome`. Events are mapped to
    /// DTOs directly in Swift, so the shared type's conditional `Decodable`
    /// conformance is never exercised here. (pippin-mgg)
    public typealias Outcome<T> = BridgeOutcome<T>

    /// Bound the *synchronous* `store.events(matching:)` walk with a 15s
    /// wall-clock cap, mirroring `RemindersBridge.fetchRemindersSync`. Unlike
    /// `fetchReminders` (callback-based), `events(matching:)` blocks the calling
    /// thread, so the work runs on a background queue and we wait on a semaphore.
    /// On timeout we return an empty set — never reading the still-mutating
    /// `result` from the abandoned worker — plus `timedOut: true` so callers can
    /// surface a partial-results advisory. A healthy fetch is near-instant; the
    /// cap only bites a wedged EventKit store.
    private func fetchEventsSync(predicate: NSPredicate) -> (events: [EKEvent], timedOut: Bool) {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: [EKEvent] = []
        // `self` (an @unchecked Sendable class) and `result` cross the @Sendable
        // boundary fine; `predicate` (NSPredicate) is non-Sendable, so hand it
        // over via a nonisolated(unsafe) local — it's only read on the worker.
        nonisolated(unsafe) let pred = predicate
        DispatchQueue.global().async {
            result = self.store.events(matching: pred)
            semaphore.signal()
        }
        let timedOut = semaphore.wait(timeout: .now() + .seconds(15)) == .timedOut
        return (timedOut ? [] : result, timedOut)
    }

    /// `EKEventStore.predicateForEvents(withStart:end:calendars:)` silently
    /// returns incomplete results for windows wider than a few years — non-
    /// recurring and weekly/daily-recurring events drop out first, well before
    /// any timeout fires (pippin-5nj). Apple documents no hard cap, but
    /// `findEventByPrefix`'s existing ±1yr window has always been reliable, so
    /// split any requested range into ≤366-day chunks, fetch each, and merge —
    /// deduping recurring occurrences (same identifier can appear in adjacent
    /// chunks at a boundary) by (identifier, startDate).
    private func fetchEventsChunked(from start: Date, to end: Date, calendars: [EKCalendar]?) -> (events: [EKEvent], timedOut: Bool) {
        var events: [EKEvent] = []
        var seen = Set<String>()
        var timedOut = false
        for (chunkStart, chunkEnd) in Self.chunkRanges(from: start, to: end) {
            let predicate = store.predicateForEvents(withStart: chunkStart, end: chunkEnd, calendars: calendars)
            let (chunkEvents, chunkTimedOut) = fetchEventsSync(predicate: predicate)
            timedOut = timedOut || chunkTimedOut
            for event in chunkEvents {
                let key = "\(event.calendarItemIdentifier)|\(event.startDate.timeIntervalSince1970)"
                if seen.insert(key).inserted {
                    events.append(event)
                }
            }
        }
        return (events, timedOut)
    }

    /// Split `[start, end)` into contiguous ≤`maxDays`-wide sub-ranges. Pure
    /// and EventKit-free so it's unit-testable without a live `EKEventStore`.
    static func chunkRanges(from start: Date, to end: Date, maxDays: Int = 366) -> [(start: Date, end: Date)] {
        guard start < end else { return [] }
        let calendar = Calendar(identifier: .gregorian)
        var ranges: [(Date, Date)] = []
        var chunkStart = start
        while chunkStart < end {
            let chunkEnd = min(calendar.date(byAdding: .day, value: maxDays, to: chunkStart) ?? end, end)
            ranges.append((chunkStart, chunkEnd))
            chunkStart = chunkEnd
        }
        return ranges
    }

    // MARK: - Access

    public func ensureAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess:
            return
        case .authorized: // deprecated but handle defensively
            return
        case .notDetermined:
            // Only block on the prompt when a user can actually answer it;
            // otherwise fail fast (requestFullAccess* hangs on an un-showable
            // dialog in non-interactive/background contexts). See pippin-0vr.
            guard PermissionPriming.canRequestAccess() else {
                throw CalendarBridgeError.accessDenied
            }
            let granted = try await store.requestFullAccessToEvents()
            guard granted else { throw CalendarBridgeError.accessDenied }
        default:
            throw CalendarBridgeError.accessDenied
        }
    }

    // MARK: - Calendars

    public func listCalendars() async throws -> [CalendarInfo] {
        try await ensureAccess()
        return store.calendars(for: .event)
            .map { cal in
                CalendarInfo(
                    id: cal.calendarIdentifier,
                    title: cal.title,
                    type: mapCalendarType(cal.type),
                    color: colorHex(cal.cgColor),
                    account: cal.source?.title ?? ""
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: - Events

    public func listEvents(from start: Date, to end: Date, calendarId: String? = nil) async throws -> Outcome<[CalendarEvent]> {
        try await ensureAccess()
        var filterCalendars: [EKCalendar]?
        if let calendarId {
            guard let cal = store.calendar(withIdentifier: calendarId) else {
                throw CalendarBridgeError.calendarNotFound(calendarId)
            }
            filterCalendars = [cal]
        }
        let (events, timedOut) = fetchEventsChunked(from: start, to: end, calendars: filterCalendars)
        let mapped = events
            .sorted { $0.startDate < $1.startDate }
            .map { mapEvent($0) }
        return Outcome(results: mapped, timedOut: timedOut)
    }

    /// Returns existing events that overlap with [from, to), excluding an optional event ID.
    /// Cancelled events are excluded. Uses the same predicate-based lookup as `listEvents`.
    public func findConflicts(from: Date, to: Date, excludingEventId: String? = nil) async throws -> Outcome<[CalendarEvent]> {
        try await ensureAccess()
        let (events, timedOut) = fetchEventsChunked(from: from, to: to, calendars: nil)
        let mapped = events
            .filter { event in
                event.status != .canceled
                    && event.startDate < to
                    && from < event.endDate
                    && (excludingEventId == nil || event.calendarItemIdentifier != excludingEventId)
            }
            .sorted { $0.startDate < $1.startDate }
            .map { mapEvent($0) }
        return Outcome(results: mapped, timedOut: timedOut)
    }

    public func getEvent(id: String) async throws -> CalendarEvent {
        try await ensureAccess()
        guard let event = findEventByPrefix(id: id) else {
            throw CalendarBridgeError.eventNotFound(id)
        }
        return mapEvent(event)
    }

    // MARK: - CRUD

    public func createEvent(
        title: String,
        start: Date,
        end: Date,
        calendarId: String? = nil,
        location: String? = nil,
        notes: String? = nil,
        url: String? = nil,
        isAllDay: Bool = false,
        alertOffset: TimeInterval? = nil
    ) async throws -> BridgeActionResult {
        try await ensureAccess()
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = isAllDay
        event.location = location
        event.notes = notes
        if let urlStr = url, let parsed = URL(string: urlStr) {
            event.url = parsed
        }
        if let calendarId {
            guard let cal = store.calendar(withIdentifier: calendarId) else {
                throw CalendarBridgeError.calendarNotFound(calendarId)
            }
            event.calendar = cal
        } else {
            event.calendar = store.defaultCalendarForNewEvents
        }
        if let alertOffset {
            event.addAlarm(EKAlarm(relativeOffset: -alertOffset))
        }
        do {
            try store.save(event, span: .thisEvent)
        } catch {
            throw CalendarBridgeError.saveFailed(error.localizedDescription)
        }
        return BridgeActionResult(
            success: true,
            action: "create",
            details: ["id": event.calendarItemIdentifier, "title": title]
        )
    }

    public func updateEvent(
        id: String,
        title: String? = nil,
        start: Date? = nil,
        end: Date? = nil,
        calendarId: String? = nil,
        location: String? = nil,
        notes: String? = nil,
        url: String? = nil,
        isAllDay: Bool? = nil,
        alertOffset: TimeInterval? = nil,
        span: EKSpan = .thisEvent
    ) async throws -> BridgeActionResult {
        try await ensureAccess()
        guard let event = findEventByPrefix(id: id) else {
            throw CalendarBridgeError.eventNotFound(id)
        }
        if let title { event.title = title }
        if let start { event.startDate = start }
        if let end { event.endDate = end }
        if let location { event.location = location }
        if let notes { event.notes = notes }
        if let isAllDay { event.isAllDay = isAllDay }
        if let urlStr = url, let parsed = URL(string: urlStr) {
            event.url = parsed
        }
        if let calendarId {
            guard let cal = store.calendar(withIdentifier: calendarId) else {
                throw CalendarBridgeError.calendarNotFound(calendarId)
            }
            event.calendar = cal
        }
        if let alertOffset {
            event.alarms?.forEach { event.removeAlarm($0) }
            event.addAlarm(EKAlarm(relativeOffset: -alertOffset))
        }
        do {
            try store.save(event, span: span)
        } catch {
            throw CalendarBridgeError.saveFailed(error.localizedDescription)
        }
        return BridgeActionResult(
            success: true,
            action: "update",
            details: ["id": event.calendarItemIdentifier, "title": event.title ?? ""]
        )
    }

    public func deleteEvent(id: String, span: EKSpan = .thisEvent) async throws -> BridgeActionResult {
        try await ensureAccess()
        guard let event = findEventByPrefix(id: id) else {
            throw CalendarBridgeError.eventNotFound(id)
        }
        let savedTitle = event.title ?? ""
        let savedId = event.calendarItemIdentifier
        do {
            try store.remove(event, span: span)
        } catch {
            throw CalendarBridgeError.saveFailed(error.localizedDescription)
        }
        return BridgeActionResult(
            success: true,
            action: "delete",
            details: ["id": savedId, "title": savedTitle]
        )
    }

    // MARK: - Private

    private func findEventByPrefix(id: String) -> EKEvent? {
        // Direct lookup first (exact identifier)
        if let event = store.calendarItem(withIdentifier: id) as? EKEvent {
            return event
        }
        // Prefix search over a ±1 year window
        let now = Date()
        let cal = Calendar.current
        let start = cal.date(byAdding: .year, value: -1, to: now)!
        let end = cal.date(byAdding: .year, value: 1, to: now)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        // Bounded fetch: a 15s cap here just yields a partial set to match
        // against (→ not-found), so the flag isn't surfaced — same rationale as
        // RemindersBridge.findReminderByPrefix.
        let matches = fetchEventsSync(predicate: predicate).events
            .filter { $0.calendarItemIdentifier.hasPrefix(id) }
        // A recurring event surfaces one EKEvent per occurrence, all sharing the
        // same calendarItemIdentifier — so count alone would treat a single
        // repeating event as ambiguous and return nil. Accept when exactly one
        // DISTINCT event matches the prefix (return its first occurrence); only
        // genuinely different identifiers are ambiguous.
        guard Self.isUnambiguousPrefixMatch(matches.map(\.calendarItemIdentifier)) else {
            return nil
        }
        return matches.first
    }

    /// A prefix resolves to a single event iff the matching occurrences all
    /// share one distinct `calendarItemIdentifier`. Recurring events produce
    /// many occurrences with the same identifier (one event); two different
    /// identifiers mean the prefix is genuinely ambiguous. Pure helper so the
    /// recurring-vs-ambiguous logic is unit-testable without an EKEventStore.
    static func isUnambiguousPrefixMatch(_ identifiers: [String]) -> Bool {
        !identifiers.isEmpty && Set(identifiers).count == 1
    }

    private func mapEvent(_ event: EKEvent) -> CalendarEvent {
        let attendees = event.attendees?.map { p in
            Attendee(
                name: p.name,
                email: p.url.absoluteString.replacingOccurrences(of: "mailto:", with: ""),
                status: mapParticipantStatus(p.participantStatus)
            )
        }

        let recurrenceDesc = event.recurrenceRules?.first.map { describeRecurrenceRule($0) }

        let statusStr: String
        switch event.status {
        case .confirmed: statusStr = "confirmed"
        case .tentative: statusStr = "tentative"
        case .canceled: statusStr = "cancelled"
        default: statusStr = "none"
        }

        let alerts: [String]? = {
            guard let alarms = event.alarms, !alarms.isEmpty else { return nil }
            let relative = alarms
                .filter { $0.relativeOffset < 0 }
                .map { formatAlertOffset(-$0.relativeOffset) }
            return relative.isEmpty ? nil : relative
        }()

        return CalendarEvent(
            id: event.calendarItemIdentifier,
            calendarId: event.calendar?.calendarIdentifier ?? "",
            calendarTitle: event.calendar?.title ?? "",
            title: event.title ?? "(no title)",
            startDate: formatEventDate(event.startDate),
            endDate: formatEventDate(event.endDate),
            isAllDay: event.isAllDay,
            location: event.location,
            notes: event.notes,
            url: event.url?.absoluteString,
            attendees: attendees?.isEmpty == false ? attendees : nil,
            recurrence: recurrenceDesc,
            status: statusStr,
            alerts: alerts
        )
    }

    private func mapParticipantStatus(_ status: EKParticipantStatus) -> String {
        switch status {
        case .accepted: return "accepted"
        case .declined: return "declined"
        case .tentative: return "tentative"
        default: return "pending"
        }
    }

    private func describeRecurrenceRule(_ rule: EKRecurrenceRule) -> String {
        switch rule.frequency {
        case .daily: return "daily"
        case .weekly: return "weekly"
        case .monthly: return "monthly"
        case .yearly: return "yearly"
        @unknown default: return "recurring"
        }
    }
}
