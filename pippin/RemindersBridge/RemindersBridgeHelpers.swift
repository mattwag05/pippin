import EventKit
import Foundation

// MARK: - Priority mapping

/// Parse a priority string or integer string to an EKReminder priority int.
/// "high"/"1" -> 1, "medium"/"5" -> 5, "low"/"9" -> 9, "none"/"0" -> 0
/// Returns nil for unrecognized values.
func parseReminderPriority(_ s: String) -> Int? {
    switch s.lowercased() {
    case "high": return 1
    case "medium": return 5
    case "low": return 9
    case "none": return 0
    default:
        guard let n = Int(s), [0, 1, 5, 9].contains(n) else { return nil }
        return n
    }
}

/// Format a priority int to a human-readable string.
func formatReminderPriority(_ priority: Int) -> String {
    switch priority {
    case 1: return "high"
    case 5: return "medium"
    case 9: return "low"
    default: return "none"
    }
}
