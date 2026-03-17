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
            → Open System Settings > Privacy & Security > Calendars
              Grant access to Terminal.app (or the pippin binary), then retry.
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

public final class CalendarBridge: @unchecked Sendable {
    private let store: EKEventStore

    public init() {
        store = EKEventStore()
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

    public func listEvents(from start: Date, to end: Date, calendarId: String? = nil) async throws -> [CalendarEvent] {
        try await ensureAccess()
        var filterCalendars: [EKCalendar]?
        if let calendarId {
            guard let cal = store.calendar(withIdentifier: calendarId) else {
                throw CalendarBridgeError.calendarNotFound(calendarId)
            }
            filterCalendars = [cal]
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: filterCalendars)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { mapEvent($0) }
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
    ) async throws -> CalendarActionResult {
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
        return CalendarActionResult(
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
    ) async throws -> CalendarActionResult {
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
        return CalendarActionResult(
            success: true,
            action: "update",
            details: ["id": event.calendarItemIdentifier, "title": event.title ?? ""]
        )
    }

    public func deleteEvent(id: String, span: EKSpan = .thisEvent) async throws -> CalendarActionResult {
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
        return CalendarActionResult(
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
        let matches = store.events(matching: predicate)
            .filter { $0.calendarItemIdentifier.hasPrefix(id) }
        return matches.count == 1 ? matches[0] : nil
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
