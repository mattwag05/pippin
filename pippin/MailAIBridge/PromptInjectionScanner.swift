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
            stripped = stripped.components(separatedBy: "\n").dropFirst().dropLast().joined(separator: "\n")
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

        // Merge: deduplicate by category + matchedText exact string match
        var merged = ruleResult.threats
        for aiThreat in aiThreats {
            let isDuplicate = merged.contains { existing in
                existing.category == aiThreat.category && existing.matchedText == aiThreat.matchedText
            }
            if !isDuplicate {
                merged.append(aiThreat)
            }
        }

        let sanitized = sanitize(body: text, threats: merged)
        let riskLevel = deriveRiskLevel(from: merged)
        return ScanResult(originalBody: text, sanitizedBody: sanitized, threats: merged, riskLevel: riskLevel)
    }

    // MARK: - Sanitize body: redact matched threat patterns

    public static func sanitize(body: String, threats: [Threat]) -> String {
        var result = body
        for threat in threats {
            result = result.replacingOccurrences(of: threat.matchedText, with: "[REDACTED]")
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
        let lowered = text.lowercased()
        var found: [String] = []
        for pattern in patterns {
            if lowered.contains(pattern.lowercased()) {
                // Find the actual substring in the original text for display
                if let range = text.range(of: pattern, options: .caseInsensitive) {
                    let matched = String(text[range].prefix(100))
                    found.append(matched)
                }
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
        let patterns = [
            ("ignore previous instructions", "Attempt to override previous instructions"),
            ("disregard your", "Attempt to disregard AI guidelines"),
            ("forget everything", "Attempt to reset AI context"),
            ("you are now", "Attempt to redefine AI identity"),
            ("act as if", "Attempt to make AI act under false premise"),
        ]
        var threats: [Threat] = []
        for (pattern, explanation) in patterns {
            let matches = substringMatches(patterns: [pattern], in: text)
            for match in matches {
                threats.append(Threat(
                    category: .systemPromptOverride,
                    confidence: 1.0,
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
        let patterns = [
            ("you are a", "Attempt to redefine AI role"),
            ("pretend to be", "Attempt to make AI impersonate another entity"),
            ("from now on you", "Attempt to permanently change AI behavior"),
            ("your new instructions", "Attempt to replace AI instructions"),
        ]
        var threats: [Threat] = []
        for (pattern, explanation) in patterns {
            let matches = substringMatches(patterns: [pattern], in: text)
            for match in matches {
                threats.append(Threat(
                    category: .roleHijacking,
                    confidence: 1.0,
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
