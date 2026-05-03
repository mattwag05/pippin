import Foundation

/// Regex-based pre-send screen for patterns that could be sensitive if
/// leaked in an autonomous message. The intent is not HIPAA compliance —
/// it's a last-line guard against "LLM accidentally echoes a credit card
/// from context into an outbound text". A flagged body aborts the send
/// and surfaces the categories to the audit log.
public enum PHIFilter {
    public struct Result: Sendable, Equatable {
        public let flagged: [String]
        public var isClean: Bool {
            flagged.isEmpty
        }
    }

    private struct CompiledPattern {
        let name: String
        let regex: NSRegularExpression
    }

    private static let patterns: [CompiledPattern] = [
        compile("ssn", #"\b\d{3}-\d{2}-\d{4}\b"#),
        compile("credit_card", #"\b\d(?:[ -]?\d){12,15}\b"#),
        compile("api_key", #"\b(?:sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{30,})\b"#),
        compile("private_key_block", #"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"#),
        compile("password_mention", #"\b(password|passwd|pwd)\s*[:=]\s*\S+"#, options: .caseInsensitive),
    ]

    private static func compile(
        _ name: String,
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) -> CompiledPattern {
        // Force-unwrap: patterns are literals we control; a bad regex here is a
        // programmer error that must surface in tests, not a runtime fallback.
        let regex = try! NSRegularExpression(pattern: pattern, options: options)
        return CompiledPattern(name: name, regex: regex)
    }

    public static func scan(_ body: String) -> Result {
        let range = NSRange(body.startIndex ..< body.endIndex, in: body)
        var flagged: [String] = []
        for pattern in patterns {
            if pattern.regex.firstMatch(in: body, options: [], range: range) != nil {
                flagged.append(pattern.name)
            }
        }
        return Result(flagged: flagged)
    }
}
