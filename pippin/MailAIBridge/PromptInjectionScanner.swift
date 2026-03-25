import Foundation

public enum PromptInjectionScanner {

    // MARK: - Pass 1: Rule-based scan (always runs, no AI)

    public static func scan(text: String) -> ScanResult {
        var threats: [Threat] = []

        threats += boundaryManipulationThreats(in: text)
        threats += systemPromptOverrideThreats(in: text)
        threats += dataExfiltrationThreats(in: text)
        threats += roleHijackingThreats(in: text)
        threats += toolInvocationThreats(in: text)
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
            system: MailAIPrompts.injectionDetectionSystemPrompt
        )

        var stripped = rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.hasPrefix("```") {
            let lines = stripped.components(separatedBy: "\n")
            stripped = lines.dropFirst().dropLast().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Fallback: extract outermost { ... } if response doesn't start with a brace
        if !stripped.hasPrefix("{") {
            if let firstBrace = stripped.firstIndex(of: "{"),
               let lastBrace = stripped.lastIndex(of: "}") {
                stripped = String(stripped[firstBrace...lastBrace])
            }
        }

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
        // Remove duplicates at the same location
        let uniqueRanges = nsRanges.reduce(into: [NSRange]()) { acc, range in
            if acc.last?.location != range.location { acc.append(range) }
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
        case 0.1..<0.4: return .low
        case 0.4..<0.7: return .medium
        case 0.7..<0.9: return .high
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

    private static func substringMatches(patterns: [String], in text: String) -> [String] {
        var found: [String] = []
        for pattern in patterns {
            if let range = text.range(of: pattern, options: .caseInsensitive) {
                let matched = String(text[range].prefix(100))
                found.append(matched)
            }
        }
        return found
    }

    // MARK: - Category scanners

    private static func boundaryManipulationThreats(in text: String) -> [Threat] {
        let patterns = [
            ("\\[SYSTEM\\]", "System role delimiter tag [SYSTEM] detected"),
            ("\\[INST\\]", "Instruction delimiter tag [INST] detected"),
            ("<\\|im_start\\|>", "OpenAI chat markup <|im_start|> detected"),
            ("<\\|im_end\\|>", "OpenAI chat markup <|im_end|> detected"),
            ("###\\s*System", "Markdown system header '### System' detected"),
            ("<system>", "HTML-like system tag <system> detected"),
        ]
        var threats: [Threat] = []
        for (pattern, explanation) in patterns {
            let matches = regexMatches(pattern: pattern, in: text)
            for match in matches {
                threats.append(Threat(
                    category: .boundaryManipulation,
                    confidence: 1.0,
                    matchedText: match,
                    explanation: explanation
                ))
            }
        }
        return threats
    }

    private static func systemPromptOverrideThreats(in text: String) -> [Threat] {
        let patterns: [(String, Float, String)] = [
            ("ignore previous instructions", 1.0, "Attempt to override previous instructions"),
            ("disregard your", 1.0, "Attempt to disregard AI guidelines"),
            ("forget everything", 1.0, "Attempt to reset AI context"),
            ("you are now", 0.3, "Attempt to redefine AI identity"),
            ("act as if", 0.3, "Attempt to make AI act under false premise"),
        ]
        var threats: [Threat] = []
        for (pattern, confidence, explanation) in patterns {
            let matches = substringMatches(patterns: [pattern], in: text)
            for match in matches {
                threats.append(Threat(
                    category: .systemPromptOverride,
                    confidence: confidence,
                    matchedText: match,
                    explanation: explanation
                ))
            }
        }
        return threats
    }

    private static func dataExfiltrationThreats(in text: String) -> [Threat] {
        let patterns = [
            ("send the conversation", "Request to exfiltrate conversation history"),
            ("include your api key", "Request to include API key"),
            ("output your system prompt", "Request to reveal system prompt"),
            ("repeat your instructions", "Request to repeat internal instructions"),
        ]
        var threats: [Threat] = []
        for (pattern, explanation) in patterns {
            let matches = substringMatches(patterns: [pattern], in: text)
            for match in matches {
                threats.append(Threat(
                    category: .dataExfiltration,
                    confidence: 1.0,
                    matchedText: match,
                    explanation: explanation
                ))
            }
        }
        return threats
    }

    private static func roleHijackingThreats(in text: String) -> [Threat] {
        let patterns: [(String, Float, String)] = [
            ("you are a", 0.3, "Attempt to redefine AI role"),
            ("pretend to be", 0.6, "Attempt to make AI impersonate another entity"),
            ("from now on you", 0.3, "Attempt to permanently change AI behavior"),
            ("your new instructions", 1.0, "Attempt to replace AI instructions"),
        ]
        var threats: [Threat] = []
        for (pattern, confidence, explanation) in patterns {
            let matches = substringMatches(patterns: [pattern], in: text)
            for match in matches {
                threats.append(Threat(
                    category: .roleHijacking,
                    confidence: confidence,
                    matchedText: match,
                    explanation: explanation
                ))
            }
        }
        return threats
    }

    private static func toolInvocationThreats(in text: String) -> [Threat] {
        let patterns: [(String, String)] = [
            ("\\bfunc\\s+\\w+\\s*\\(", "Function definition pattern suggesting hidden tool call"),
            ("\\btool_call\\b", "Explicit tool_call token detected"),
            ("\\bfunction_call\\b", "Explicit function_call token detected"),
            ("<tool_use>", "Tool use tag detected"),
            ("\\binvoke\\s+\\w+", "Invoke command pattern detected"),
        ]
        var threats: [Threat] = []
        for (pattern, explanation) in patterns {
            let matches = regexMatches(pattern: pattern, in: text)
            for match in matches {
                threats.append(Threat(
                    category: .toolInvocation,
                    confidence: 1.0,
                    matchedText: match,
                    explanation: explanation
                ))
            }
        }
        return threats
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
               let decodedStr = String(data: decoded, encoding: .utf8)
            {
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
