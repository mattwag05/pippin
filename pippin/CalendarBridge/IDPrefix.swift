import Foundation

// Pure id-prefix resolution shared by Calendar and Reminders, unit-tested
// without an EKEventStore.

enum IDPrefix {
    /// Shortest prefix a mutating command (edit, delete, complete) accepts.
    /// EventKit ids are UUIDs, so 8 characters is their first group.
    static let minimumMutatingLength = 8

    enum Resolution: Equatable {
        case notFound
        case unique(String)
        /// Number of DISTINCT ids the prefix matches.
        case ambiguous(Int)
        case tooShort
    }

    /// Resolve `prefix` against candidate ids. A recurring event contributes
    /// one id per occurrence, so matches are counted by distinct id. An exact
    /// id always resolves, whatever its length.
    static func resolve(_ prefix: String, among ids: [String], minimumLength: Int) -> Resolution {
        if ids.contains(prefix) { return .unique(prefix) }
        guard prefix.count >= minimumLength else { return .tooShort }
        let matches = Set(ids.filter { $0.hasPrefix(prefix) })
        switch matches.count {
        case 0: return .notFound
        case 1: return .unique(matches.first!)
        default: return .ambiguous(matches.count)
        }
    }
}
