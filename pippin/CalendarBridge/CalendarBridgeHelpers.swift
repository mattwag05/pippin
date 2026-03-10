import CoreGraphics
import EventKit
import Foundation

// MARK: - Calendar type mapping

func mapCalendarType(_ type: EKCalendarType) -> String {
    switch type {
    case .local: return "local"
    case .calDAV: return "calDAV"
    case .exchange: return "exchange"
    case .subscription: return "subscription"
    case .birthday: return "birthday"
    @unknown default: return "unknown"
    }
}

// MARK: - Color

/// Convert a CGColor to a "#RRGGBB" hex string.
func colorHex(_ cgColor: CGColor) -> String {
    guard
        let converted = cgColor.converted(
            to: CGColorSpaceCreateDeviceRGB(),
            intent: .defaultIntent,
            options: nil
        ),
        let components = converted.components,
        components.count >= 3
    else {
        return "#000000"
    }
    let r = Int((components[0] * 255).rounded().clamped(to: 0 ... 255))
    let g = Int((components[1] * 255).rounded().clamped(to: 0 ... 255))
    let b = Int((components[2] * 255).rounded().clamped(to: 0 ... 255))
    return String(format: "#%02X%02X%02X", r, g, b)
}

// MARK: - Date parsing

/// Parse an ISO 8601 datetime (with or without timezone) or YYYY-MM-DD into a Date.
///
/// Accepted formats:
/// - `2026-03-07T10:00:00Z`           — ISO 8601 with UTC
/// - `2026-03-07T10:00:00+05:00`      — ISO 8601 with offset
/// - `2026-03-07T10:00:00`            — ISO 8601, no timezone (treated as local)
/// - `2026-03-07`                     — date only, midnight in local timezone
func parseCalendarDate(_ s: String) -> Date? {
    // ISO 8601 with timezone
    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime]
    if let date = isoFormatter.date(from: s) { return date }

    // ISO 8601 without timezone — treat as local time
    let localFormatter = DateFormatter()
    localFormatter.locale = Locale(identifier: "en_US_POSIX")
    localFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    if let date = localFormatter.date(from: s) { return date }

    // YYYY-MM-DD — midnight in local timezone
    localFormatter.dateFormat = "yyyy-MM-dd"
    return localFormatter.date(from: s)
}

/// Format a Date as ISO 8601 with timezone (e.g. "2026-03-07T10:00:00Z").
func formatEventDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

// MARK: - Span parsing

/// Parse a span string into an EKSpan. Returns nil for unrecognized values.
func parseSpan(_ value: String) -> EKSpan? {
    switch value.lowercased() {
    case "this": return .thisEvent
    case "future": return .futureEvents
    default: return nil
    }
}

// MARK: - Alert duration

/// Parse an alert duration string like "15m", "2h", "1d" into a TimeInterval (seconds).
/// Returns nil for unrecognized formats.
func parseAlertDuration(_ s: String) -> TimeInterval? {
    let pattern = /(\d+)(m|h|d)/
    guard let match = s.lowercased().wholeMatch(of: pattern) else { return nil }
    guard let value = Double(match.output.1) else { return nil }
    switch match.output.2 {
    case "m": return value * 60
    case "h": return value * 3600
    case "d": return value * 86400
    default: return nil
    }
}

/// Format an alert offset (positive seconds before event) as a human-readable string.
func formatAlertOffset(_ seconds: TimeInterval) -> String {
    if seconds < 3600 {
        let mins = Int(seconds / 60)
        return "\(mins) minute\(mins == 1 ? "" : "s") before"
    } else if seconds < 86400 {
        let hours = Int(seconds / 3600)
        return "\(hours) hour\(hours == 1 ? "" : "s") before"
    } else {
        let days = Int(seconds / 86400)
        return "\(days) day\(days == 1 ? "" : "s") before"
    }
}

// MARK: - Date range shorthands

/// Parse a date range shorthand into (start: Date, end: Date).
/// Supported formats:
///   "today"      — start of today to end of today (midnight of tomorrow)
///   "today+N"    — start of today to end of day N days from today (e.g. "today+3")
///   "week"       — start of current week (Sunday/Monday) to end of week
///   "month"      — start of current month to end of current month
/// Returns nil for unrecognized formats.
func parseRange(_ s: String) -> (start: Date, end: Date)? {
    let cal = Calendar.current
    let now = Date()
    let today = cal.startOfDay(for: now)
    let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!

    switch s.lowercased() {
    case "today":
        return (today, tomorrow)
    case "week":
        let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
        let weekEnd = cal.date(byAdding: .weekOfYear, value: 1, to: weekStart)!
        return (weekStart, weekEnd)
    case "month":
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart)!
        return (monthStart, monthEnd)
    default:
        // "today+N"
        if s.lowercased().hasPrefix("today+"), let n = Int(s.dropFirst(6)), n > 0 {
            let rangeEnd = cal.date(byAdding: .day, value: n + 1, to: today)!
            return (today, rangeEnd)
        }
        return nil
    }
}

// MARK: - Comparable clamping helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
