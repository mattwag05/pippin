import Foundation

/// Fixed-width text formatting for CLI output.
/// Uses 80-column layout — no terminal width detection (reliable under launchd/cron).
public enum TextFormatter {
    /// Print a column-aligned table with headers.
    /// `columnWidths` specifies the width for each column; the last column expands to fill.
    public static func table(headers: [String], rows: [[String]], columnWidths: [Int]) -> String {
        guard !headers.isEmpty else { return "" }
        var lines: [String] = []

        let headerLine = formatRow(headers, widths: columnWidths)
        lines.append(headerLine)
        lines.append(String(repeating: "─", count: 80))

        for row in rows {
            lines.append(formatRow(row, widths: columnWidths))
        }

        return lines.joined(separator: "\n")
    }

    /// Format a key-value card for detail views (show/info).
    public static func card(fields: [(String, String)]) -> String {
        guard !fields.isEmpty else { return "" }
        let maxKeyLen = fields.map(\.0.count).max() ?? 0
        var lines: [String] = []
        for (key, value) in fields {
            let padded = key.padding(toLength: maxKeyLen, withPad: " ", startingAt: 0)
            // Handle multiline values (e.g. email body)
            let valueLines = value.components(separatedBy: .newlines)
            lines.append("\(padded)  \(valueLines[0])")
            for additional in valueLines.dropFirst() {
                lines.append(String(repeating: " ", count: maxKeyLen + 2) + additional)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Truncate a string to `maxLength` characters, adding ellipsis if needed.
    public static func truncate(_ s: String, to maxLength: Int) -> String {
        guard s.count > maxLength, maxLength > 1 else { return s }
        return String(s.prefix(maxLength - 1)) + "…"
    }

    /// Format seconds as human-readable duration: "2m 15s", "1h 5m", "45s".
    public static func duration(_ seconds: Double) -> String {
        let total = Int(seconds)
        if total < 60 {
            return "\(total)s"
        } else if total < 3600 {
            let m = total / 60
            let s = total % 60
            return s > 0 ? "\(m)m \(s)s" : "\(m)m"
        } else {
            let h = total / 3600
            let m = (total % 3600) / 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
    }

    /// Format an ISO 8601 date string to compact "YYYY-MM-DD HH:MM" format.
    public static func compactDate(_ iso8601: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso8601) {
            return formatDate(date)
        }
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: iso8601) {
            return formatDate(date)
        }
        return iso8601
    }

    /// Format a `Date` to compact "YYYY-MM-DD HH:MM" in local timezone.
    public static func compactDate(_ date: Date) -> String {
        formatDate(date)
    }

    /// Single success/failure line for action results.
    public static func actionResult(success: Bool, action: String, details: String) -> String {
        let icon = success ? "ok" : "FAIL"
        return "[\(icon)] \(action): \(details)"
    }

    // MARK: - Private

    private static func formatRow(_ cells: [String], widths: [Int]) -> String {
        var parts: [String] = []
        for (i, cell) in cells.enumerated() {
            if i < widths.count - 1 {
                // Fixed-width column: pad or truncate
                let w = widths[i]
                let truncated = truncate(cell, to: w)
                parts.append(truncated.padding(toLength: w, withPad: " ", startingAt: 0))
            } else {
                // Last column: no padding, just truncate to remaining space
                let used = widths.dropLast().reduce(0) { $0 + $1 + 2 } // +2 for "  " separator
                let remaining = max(10, 80 - used)
                parts.append(truncate(cell, to: remaining))
            }
        }
        return parts.joined(separator: "  ")
    }

    private static func formatDate(_ date: Date) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d",
            comps.year ?? 0, comps.month ?? 0, comps.day ?? 0,
            comps.hour ?? 0, comps.minute ?? 0
        )
    }
}
