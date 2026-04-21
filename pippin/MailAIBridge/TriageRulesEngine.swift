import Foundation

public enum TriageRulesEngine {
    public static func defaultRulesPath() -> String {
        "\(NSHomeDirectory())/.config/pippin/triage-rules.json"
    }

    /// Load rules from disk. Returns empty array if file absent or unparseable.
    public static func loadRules(path: String? = nil) -> [TriageRule] {
        let filePath = path ?? defaultRulesPath()
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
            let rules = try? JSONDecoder().decode([TriageRule].self, from: data)
        else { return [] }
        return rules.filter(\.enabled)
    }

    /// Apply rules to messages. Returns (remaining, ruleTriaged) where:
    /// - remaining: messages that didn't match any rule (need AI pass)
    /// - ruleTriaged: messages already classified by rules (no AI needed)
    /// Messages whose matched rule has skip=true are excluded from both lists.
    public static func apply(
        rules: [TriageRule],
        to messages: [MailMessage]
    ) -> (remaining: [MailMessage], ruleTriaged: [TriagedMessage]) {
        guard !rules.isEmpty else { return (messages, []) }

        var remaining: [MailMessage] = []
        var ruleTriaged: [TriagedMessage] = []

        for message in messages {
            if let match = firstMatch(rules: rules, message: message) {
                if match.action.skip == true { continue }
                ruleTriaged.append(TriagedMessage(
                    compoundId: message.id,
                    subject: message.subject,
                    from: message.from,
                    category: match.action.setCategory ?? .informational,
                    urgency: match.action.setUrgency ?? 2,
                    oneLiner: "Matched rule: \(match.name)"
                ))
            } else {
                remaining.append(message)
            }
        }

        return (remaining, ruleTriaged)
    }

    // MARK: - Private

    private static func firstMatch(rules: [TriageRule], message: MailMessage) -> TriageRule? {
        rules.first { matchesRule($0, message: message) }
    }

    private static func matchesRule(_ rule: TriageRule, message: MailMessage) -> Bool {
        let results = rule.conditions.map { matchesCondition($0, message: message) }
        return rule.conditionOperator == .and
            ? results.allSatisfy { $0 }
            : results.contains { $0 }
    }

    private static func matchesCondition(_ condition: RuleCondition, message: MailMessage) -> Bool {
        let haystack: String = {
            switch condition.field {
            case .sender: return message.from.lowercased()
            case .subject: return message.subject.lowercased()
            case .keyword: return (message.bodyPreview ?? message.subject).lowercased()
            case .account: return message.account.lowercased()
            }
        }()
        let needle = condition.value.lowercased()

        switch condition.matchOperator {
        case .contains: return haystack.contains(needle)
        case .equals: return haystack == needle
        case .startsWith: return haystack.hasPrefix(needle)
        case .matches:
            guard let regex = try? NSRegularExpression(pattern: condition.value, options: .caseInsensitive) else {
                return false
            }
            return regex.firstMatch(in: haystack, range: NSRange(haystack.startIndex..., in: haystack)) != nil
        }
    }
}
