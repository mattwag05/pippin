import EventKit
import Foundation

// Pure, EventKit-free decisions about WHICH occurrence of a recurring event an
// id names. Everything here is unit-tested without an EKEventStore.

/// How far a recurring edit or delete reaches. `all` is the explicit
/// whole-series choice; EventKit has no span for it, so it is the series'
/// first occurrence saved with `.futureEvents`.
public enum EventSpan: String, Equatable, Sendable {
    case this, future, all

    init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }

    var ekSpan: EKSpan {
        self == .this ? .thisEvent : .futureEvents
    }
}

/// One occurrence of a recurring event, named by its start: a full timestamp
/// (the `occurrenceDate` a list row carries) or a bare `YYYY-MM-DD` local day.
public struct OccurrenceSpec: Equatable, Sendable {
    let date: Date
    let dayOnly: Bool

    init(date: Date, dayOnly: Bool) {
        self.date = date
        self.dayOnly = dayOnly
    }

    init?(argument: String) {
        guard let date = parseCalendarDate(argument) else { return nil }
        self.init(date: date, dayOnly: argument.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil)
    }

    /// The range to query EventKit with. A timestamp gets a minute of slack on
    /// each side; `matches` still demands the exact start.
    func window(calendar: Calendar = .current) -> (start: Date, end: Date) {
        if dayOnly {
            let start = calendar.startOfDay(for: date)
            return (start, calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400))
        }
        return (date.addingTimeInterval(-60), date.addingTimeInterval(60))
    }

    func matches(start: Date, calendar: Calendar = .current) -> Bool {
        if dayOnly {
            let range = window(calendar: calendar)
            return start >= range.start && start < range.end
        }
        // ISO 8601 output is second-precision.
        return abs(start.timeIntervalSince(date)) < 1
    }

    /// Index of the single occurrence in `starts` this spec names.
    func pick(from starts: [Date], id: String, calendar: Calendar = .current) throws -> Int {
        let hits = starts.indices.filter { matches(start: starts[$0], calendar: calendar) }
        guard hits.count == 1 else {
            let stamp = dayOnly ? formatEventDay(date) : formatEventDate(date)
            throw CalendarBridgeError.occurrenceNotFound(hits.isEmpty
                ? "\(id) has no occurrence starting at \(stamp)"
                : "\(id) has \(hits.count) occurrences on \(stamp); pass the full occurrenceDate timestamp")
        }
        return hits[0]
    }
}

enum OccurrenceTarget: Equatable {
    /// Act on the event the id lookup returned: a non-recurring event, the
    /// whole series, or a read of a series with no occurrence named.
    case item
    case occurrence(OccurrenceSpec)
}

/// Every occurrence of a recurring event shares one id, so an id alone names
/// the series, not the occurrence the caller listed (RC-17). A mutation of a
/// recurring event therefore needs an occurrence or the explicit whole-series
/// span, and refuses otherwise. Non-recurring events ignore both.
func occurrenceTarget(
    id: String,
    isRecurring: Bool,
    occurrence: OccurrenceSpec?,
    span: EventSpan,
    mutating: Bool
) throws -> OccurrenceTarget {
    guard isRecurring, span != .all else { return .item }
    if let occurrence { return .occurrence(occurrence) }
    if mutating { throw CalendarBridgeError.occurrenceRequired(id) }
    return .item
}
