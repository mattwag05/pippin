import Foundation

public enum PromptInjectionScanner {
    // MARK: - Pass 1: Rule-based scan (always runs, no AI)

    public static func scan(text: String) -> ScanResult {
        var threats: [Threat] = []

        threats += ruleThreats(in: text)
        threats += encodingTricksThreats(in: text)

        let sanitized = sanitize(body: text, threats: threats)
        let riskLevel = deriveRiskLevel(from: threats)
        return ScanResult(originalBody: text, sanitizedBody: sanitized, threats: threats, riskLevel: riskLevel)
    }

    // MARK: - Pass 2: AI-assisted (merge with rule-based results)

    public static func scanWithAI(text: String, provider: any AIProvider) throws -> ScanResult {
        let ruleResult = scan(text: text)

        let rawResponse = try provider.complete(
            prompt: text,
            system: MailAIPrompts.injectionDetectionSystemPrompt,
            options: AICompletionOptions(jsonMode: true)
        )

        let stripped = stripAIResponseJSON(rawResponse)

        guard let data = stripped.data(using: .utf8) else {
            throw MailAIError.malformedAIResponse(rawResponse)
        }

        struct AIThreatsResponse: Decodable {
            let threats: [AIThreat]
        }
        struct AIThreat: Decodable {
            let category: String
            let confidence: Float
            let matchedText: String
            let explanation: String
        }

        let decoded: AIThreatsResponse
        do {
            decoded = try JSONDecoder().decode(AIThreatsResponse.self, from: data)
        } catch {
            throw MailAIError.malformedAIResponse(rawResponse)
        }

        let aiThreats: [Threat] = decoded.threats.compactMap { aiThreat in
            guard let category = ThreatCategory(rawValue: aiThreat.category) else { return nil }
            let truncated = String(aiThreat.matchedText.prefix(100))
            return Threat(
                category: category,
                confidence: aiThreat.confidence,
                matchedText: truncated,
                explanation: aiThreat.explanation
            )
        }

        // Merge: deduplicate by category + case-insensitive substring containment
        let ruleThreats = ruleResult.threats
        var merged = ruleThreats
        for aiThreat in aiThreats {
            let isDuplicate = ruleThreats.contains { existing in
                existing.category == aiThreat.category &&
                    (existing.matchedText.lowercased().contains(aiThreat.matchedText.lowercased()) ||
                        aiThreat.matchedText.lowercased().contains(existing.matchedText.lowercased()))
            }
            if !isDuplicate { merged.append(aiThreat) }
        }

        let sanitized = sanitize(body: text, threats: merged)
        let riskLevel = deriveRiskLevel(from: merged)
        return ScanResult(originalBody: text, sanitizedBody: sanitized, threats: merged, riskLevel: riskLevel)
    }

    // MARK: - Sanitize body: redact matched threat patterns

    public static func sanitize(body: String, threats: [Threat]) -> String {
        let nsBody = body as NSString
        var nsRanges: [NSRange] = []
        for threat in threats {
            var searchRange = NSRange(location: 0, length: nsBody.length)
            while searchRange.location < nsBody.length {
                let found = nsBody.range(of: threat.matchedText, options: .caseInsensitive, range: searchRange)
                guard found.location != NSNotFound else { break }
                nsRanges.append(found)
                let nextStart = found.location + found.length
                searchRange = NSRange(location: nextStart, length: nsBody.length - nextStart)
            }
        }
        // Sort descending so end-of-string replacements don't shift earlier offsets
        nsRanges.sort { $0.location > $1.location }
        // Remove ranges that overlap with the last accepted range.
        // Sorted descending, so "last accepted" has a higher location.
        // A range overlaps if its end (location + length) extends into the last accepted range.
        let uniqueRanges = nsRanges.reduce(into: [NSRange]()) { acc, range in
            if let last = acc.last, range.location + range.length > last.location {
                // Overlapping or contained — skip
                return
            }
            acc.append(range)
        }
        var result = body
        for nsRange in uniqueRanges {
            guard let range = Range(nsRange, in: result) else { continue }
            result.replaceSubrange(range, with: "[REDACTED]")
        }
        return result
    }

    // MARK: - Private helpers

    private static func deriveRiskLevel(from threats: [Threat]) -> RiskLevel {
        guard !threats.isEmpty else { return .none }
        let maxConfidence = threats.map { $0.confidence }.max() ?? 0
        switch maxConfidence {
        case ..<0.1: return .none
        case 0.1 ..< 0.4: return .low
        case 0.4 ..< 0.7: return .medium
        case 0.7 ..< 0.9: return .high
        default: return .critical
        }
    }

    private static func regexMatches(pattern: String, in text: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, options: [], range: range)
        return matches.map { match in
            let matchRange = match.range
            let matched = nsText.substring(with: matchRange)
            return String(matched.prefix(100))
        }
    }

    /// Convert a literal phrase ("ignore previous instructions") into a regex
    /// that tolerates any run of whitespace between words, so an attacker padding
    /// or line-breaking between words ("ignore  previous\ninstructions") can't
    /// slip past the always-on rule pass. Each word is regex-escaped; inter-word
    /// whitespace becomes `\s+` (one-or-more, so the normal single-space form
    /// still matches and existing detections don't regress). Internal for tests.
    static func whitespaceTolerantPattern(_ phrase: String) -> String {
        phrase
            .split(whereSeparator: { $0.isWhitespace })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\\s+")
    }

    /// First occurrence of each literal phrase, tolerating whitespace variation
    /// between words. Returns the actual matched text (so `sanitize` redaction —
    /// which already redacts every occurrence — maps back to original ranges).
    /// One match per phrase preserves the prior threat-count semantics.
    private static func phraseMatches(_ phrases: [String], in text: String) -> [String] {
        phrases.compactMap { regexMatches(pattern: whitespaceTolerantPattern($0), in: text).first }
    }

    // MARK: - Category scanners

    /// How a rule-table pattern matches: a raw regex, or a literal phrase made
    /// whitespace-tolerant via `whitespaceTolerantPattern` (first match only).
    private enum PatternKind { case regex, phrase }

    /// The always-on rule table: (category, pattern, kind, confidence, explanation).
    private static let rulePatterns: [(ThreatCategory, String, PatternKind, Float, String)] = [
        (.boundaryManipulation, "\\[SYSTEM\\]", .regex, 1.0, "System role delimiter tag [SYSTEM] detected"),
        (.boundaryManipulation, "\\[INST\\]", .regex, 1.0, "Instruction delimiter tag [INST] detected"),
        (.boundaryManipulation, "<\\|im_start\\|>", .regex, 1.0, "OpenAI chat markup <|im_start|> detected"),
        (.boundaryManipulation, "<\\|im_end\\|>", .regex, 1.0, "OpenAI chat markup <|im_end|> detected"),
        (.boundaryManipulation, "###\\s*System", .regex, 1.0, "Markdown system header '### System' detected"),
        (.boundaryManipulation, "<system>", .regex, 1.0, "HTML-like system tag <system> detected"),
        (.systemPromptOverride, "ignore previous instructions", .phrase, 1.0, "Attempt to override previous instructions"),
        (.systemPromptOverride, "disregard your", .phrase, 1.0, "Attempt to disregard AI guidelines"),
        (.systemPromptOverride, "forget everything", .phrase, 1.0, "Attempt to reset AI context"),
        (.systemPromptOverride, "you are now", .phrase, 0.3, "Attempt to redefine AI identity"),
        (.systemPromptOverride, "act as if", .phrase, 0.3, "Attempt to make AI act under false premise"),
        (.dataExfiltration, "send the conversation", .phrase, 1.0, "Request to exfiltrate conversation history"),
        (.dataExfiltration, "include your api key", .phrase, 1.0, "Request to include API key"),
        (.dataExfiltration, "output your system prompt", .phrase, 1.0, "Request to reveal system prompt"),
        (.dataExfiltration, "repeat your instructions", .phrase, 1.0, "Request to repeat internal instructions"),
        (.roleHijacking, "you are a", .phrase, 0.3, "Attempt to redefine AI role"),
        (.roleHijacking, "pretend to be", .phrase, 0.6, "Attempt to make AI impersonate another entity"),
        (.roleHijacking, "from now on you", .phrase, 0.3, "Attempt to permanently change AI behavior"),
        (.roleHijacking, "your new instructions", .phrase, 1.0, "Attempt to replace AI instructions"),
        (.toolInvocation, "\\bfunc\\s+\\w+\\s*\\(", .regex, 1.0, "Function definition pattern suggesting hidden tool call"),
        (.toolInvocation, "\\btool_call\\b", .regex, 1.0, "Explicit tool_call token detected"),
        (.toolInvocation, "\\bfunction_call\\b", .regex, 1.0, "Explicit function_call token detected"),
        (.toolInvocation, "<tool_use>", .regex, 1.0, "Tool use tag detected"),
        (.toolInvocation, "\\binvoke\\s+\\w+", .regex, 1.0, "Invoke command pattern detected"),
    ]

    private static func ruleThreats(in text: String) -> [Threat] {
        rulePatterns.flatMap { category, pattern, kind, confidence, explanation -> [Threat] in
            let matches: [String] = switch kind {
            case .regex: regexMatches(pattern: pattern, in: text)
            case .phrase: phraseMatches([pattern], in: text)
            }
            return matches.map {
                Threat(category: category, confidence: confidence, matchedText: $0, explanation: explanation)
            }
        }
    }

    private static func encodingTricksThreats(in text: String) -> [Threat] {
        var threats: [Threat] = []

        // Zero-width characters (ICU regex uses \uXXXX notation — 4 hex digits, no braces)
        let zeroWidthMatches = regexMatches(pattern: "[\\u200B\\u200C\\u200D\\uFEFF]", in: text, options: [])
        for match in zeroWidthMatches {
            threats.append(Threat(
                category: .encodingTricks,
                confidence: 1.0,
                matchedText: match,
                explanation: "Zero-width Unicode character detected — may be hiding injected text"
            ))
        }

        // Data URIs
        let dataURIMatches = regexMatches(pattern: "data:[^,]{0,50},", in: text, options: [.caseInsensitive])
        for match in dataURIMatches {
            threats.append(Threat(
                category: .encodingTricks,
                confidence: 1.0,
                matchedText: match,
                explanation: "Data URI pattern detected — may encode injected content"
            ))
        }

        // Base64-ish strings: only flag if decoded text contains injection keywords
        let base64Matches = regexMatches(pattern: "[A-Za-z0-9+/]{50,}={0,2}", in: text, options: [])
        let injectionKeywords = [
            "ignore", "disregard", "forget", "you are", "pretend", "act as",
            "system", "instructions", "invoke", "tool_call", "function_call",
        ]
        for match in base64Matches {
            // Pad to multiple of 4 for valid base64
            var padded = match
            let remainder = padded.count % 4
            if remainder != 0 {
                padded += String(repeating: "=", count: 4 - remainder)
            }
            if let decoded = Data(base64Encoded: padded),
               let decodedStr = String(data: decoded, encoding: .utf8) {
                let lower = decodedStr.lowercased()
                if injectionKeywords.contains(where: { lower.contains($0) }) {
                    threats.append(Threat(
                        category: .encodingTricks,
                        confidence: 1.0,
                        matchedText: match,
                        explanation: "Base64 encoded content containing injection keywords detected"
                    ))
                }
            }
        }

        return threats
    }
}
