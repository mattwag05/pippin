import Foundation

/// Escape a Swift string for safe interpolation into a JXA (JavaScript)
/// source literal built for `osascript`. Shared by the Mail / Notes / Messages
/// bridges (free functions, so their existing unqualified `jsEscape(…)` calls
/// resolve here with no call-site changes). (pippin-c7f)
func jsEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\0", with: "\\0")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "'", with: "\\'")
        .replacingOccurrences(of: "`", with: "\\`")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
}

/// `'escaped'` for a non-nil string, `null` otherwise — for an optional JXA arg.
func jsEscapeOptional(_ s: String?) -> String {
    s.map { "'\(jsEscape($0))'" } ?? "null"
}
