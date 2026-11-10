import EventKit
import Foundation

public enum CalendarBridgeError: LocalizedError, Sendable {
    case accessDenied
    case eventNotFound(String)
    case calendarNotFound(String)
    case saveFailed(String)
    case ambiguousId(String, count: Int)
    case idPrefixTooShort(String)
    case dateParseError(String)
    case aiParseError(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            return """
            Calendar access denied.
            → Run `pippin permissions` once in a terminal, or enable pippin under
              System Settings > Privacy & Security > Calendars. The grant belongs
              to pippin itself at its installed path (e.g. ~/.local/bin/pippin),
              not to the launching app, because pippin relaunches as its own
              responsible process; a background agent that can't show the prompt
              needs `pippin calendar list` run once in a terminal first. With
              PIPPIN_NO_DISCLAIM=1, or when that relaunch is unavailable, the
              grant attaches to the launching app (your terminal, or the MCP/agent
              client) instead. Then retry.
            """
        case let .eventNotFound(id):
            return "Event not found: \(id)"
        case let .calendarNotFound(id):
            return "Calendar not found: \(id)"
        case let .saveFailed(msg):
            return "Failed to save event: \(msg)"
        case let .ambiguousId(id, count):
            return "Ambiguous ID prefix '\(id)': matches \(count) events. Use more characters or the full ID."
        case let .idPrefixTooShort(id):
            return "ID prefix '\(id)' is too short to edit or delete an event. "
                + "Use the full ID or at least \(IDPrefix.minimumMutatingLength) characters of it."
        case let .dateParseError(value):
            return "Could not parse date from AI response: \(value)"
        case let .aiParseError(detail):
            return "AI response could not be parsed as event JSON: \(detail)"
        }
    }
}

extension CalendarBridgeError: RemediableError {
    public var agentCode: String {
        switch self {
        case .accessDenied: return "access_denied"
        case .eventNotFound: return "event_not_found"
        case .calendarNotFound: return "calendar_not_found"
        case .saveFailed: return "save_failed"
        case .ambiguousId: return "ambiguous_id"
        case .idPrefixTooShort: return "invalid_id_prefix"
        case .dateParseError: return "date_parse_error"
        case .aiParseError: return "ai_parse_error"
        }
    }

    public var nextStep: NextStep {
        switch self {
        case .accessDenied:
            return .human("Run `pippin permissions` in a terminal and approve Calendar access.")
        case .eventNotFound, .ambiguousId, .idPrefixTooShort:
            return .call(tool: "calendar_events", argv: ["calendar", "events"])
        case .calendarNotFound:
            return .call(tool: "calendar_list", argv: ["calendar", "list"])
        case .saveFailed, .dateParseError, .aiParseError: return .none
        }
    }

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
            filterCalendars = try [resolveEventCalendar(calendarId)]
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
        return try mapEvent(findEvent(id: id, minimumPrefixLength: 0))
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
            event.calendar = try resolveEventCalendar(calendarId)
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
        let event = try findEvent(id: id, minimumPrefixLength: IDPrefix.minimumMutatingLength)
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
            event.calendar = try resolveEventCalendar(calendarId)
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
        let event = try findEvent(id: id, minimumPrefixLength: IDPrefix.minimumMutatingLength)
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

    /// Resolve a `--calendar` argument (an EventKit calendar ID) to an
    /// `EKCalendar`. When the ID lookup misses but a calendar with that NAME
    /// exists, the not-found error says so and carries the real ID, since the
    /// most common miss is passing a name where an ID is expected.
    private func resolveEventCalendar(_ calendarId: String) throws -> EKCalendar {
        if let cal = store.calendar(withIdentifier: calendarId) { return cal }
        let named = store.calendars(for: .event)
            .filter { $0.title.caseInsensitiveCompare(calendarId) == .orderedSame }
        throw CalendarBridgeError.calendarNotFound(
            Self.calendarIdMissDetail(calendarId, matchingIds: named.map(\.calendarIdentifier))
        )
    }

    /// Detail string for a `--calendar` ID miss: plain argument when nothing
    /// matches, or a "did you mean" hint carrying the ID(s) of same-named
    /// calendars. Pure so it's unit-testable without an EKEventStore.
    static func calendarIdMissDetail(_ argument: String, matchingIds: [String]) -> String {
        guard !matchingIds.isEmpty else { return argument }
        let existence = matchingIds.count == 1
            ? "a calendar NAMED '\(argument)' exists"
            : "\(matchingIds.count) calendars NAMED '\(argument)' exist"
        return "\(argument) — \(existence) (id: \(matchingIds.joined(separator: ", "))). "
            + "--calendar takes IDs from 'pippin calendar list'; pass that ID (or use --calendar-name where available)."
    }

    /// The event an id or id prefix names. A prefix that matches more than one
    /// distinct event is `ambiguous_id`, never a guess and never "not found";
    /// mutating callers also pass a minimum prefix length (RC-16).
    private func findEvent(id: String, minimumPrefixLength: Int) throws -> EKEvent {
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
        let candidates = fetchEventsSync(predicate: predicate).events
        let fullId = try Self.resolveEventId(
            id, among: candidates.map(\.calendarItemIdentifier), minimumPrefixLength: minimumPrefixLength
        )
        // A recurring event surfaces one EKEvent per occurrence, all sharing
        // the same calendarItemIdentifier; any of them stands for the event.
        guard let event = candidates.first(where: { $0.calendarItemIdentifier == fullId }) else {
            throw CalendarBridgeError.eventNotFound(id)
        }
        return event
    }

    /// Map a prefix lookup onto the typed errors. Pure so the ambiguous and
    /// too-short cases are unit-testable without an EKEventStore.
    static func resolveEventId(_ id: String, among identifiers: [String], minimumPrefixLength: Int) throws -> String {
        switch IDPrefix.resolve(id, among: identifiers, minimumLength: minimumPrefixLength) {
        case let .unique(fullId): return fullId
        case .notFound: throw CalendarBridgeError.eventNotFound(id)
        case let .ambiguous(count): throw CalendarBridgeError.ambiguousId(id, count: count)
        case .tooShort: throw CalendarBridgeError.idPrefixTooShort(id)
        }
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
            // All-day events are calendar DAYS, not instants — serialize them
            // date-only (local day) so positive-UTC-offset consumers don't see
            // the wrong day (e.g. "2026-07-23T04:00:00Z" reading as Jul 24).
            startDate: event.isAllDay ? formatEventDay(event.startDate) : formatEventDate(event.startDate),
            endDate: event.isAllDay ? formatEventDay(event.endDate) : formatEventDate(event.endDate),
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
