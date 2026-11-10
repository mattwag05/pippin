import Foundation

/// Escape a Swift string for safe interpolation into a JXA (JavaScript)
/// source literal built for `osascript`. Shared by the Mail / Notes / Messages
/// bridges (free functions, so their existing unqualified `jsEscape(…)` calls
/// resolve here with no call-site changes). (pippin-c7f)
func jsEscape(_ s: String) -> String {
    // Per Unicode scalar, not per Character: a quote followed by a combining
    // mark is one Character, and matching by Character would leave it raw.
    var out = String.UnicodeScalarView()
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\\": out.append(contentsOf: "\\\\".unicodeScalars)
        // \x00, not \0: "\0" followed by a digit is a legacy octal escape.
        case "\0": out.append(contentsOf: "\\x00".unicodeScalars)
        case "\"": out.append(contentsOf: "\\\"".unicodeScalars)
        case "'": out.append(contentsOf: "\\'".unicodeScalars)
        case "`": out.append(contentsOf: "\\`".unicodeScalars)
        case "\n": out.append(contentsOf: "\\n".unicodeScalars)
        case "\r": out.append(contentsOf: "\\r".unicodeScalars)
        case "\u{2028}": out.append(contentsOf: "\\u2028".unicodeScalars)
        case "\u{2029}": out.append(contentsOf: "\\u2029".unicodeScalars)
        default: out.append(scalar)
        }
    }
    return String(out)
}

/// `'escaped'` for a non-nil string, `null` otherwise — for an optional JXA arg.
func jsEscapeOptional(_ s: String?) -> String {
    s.map { "'\(jsEscape($0))'" } ?? "null"
}
