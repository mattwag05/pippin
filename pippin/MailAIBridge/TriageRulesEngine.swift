import Foundation

/// A message paired with the rule that claimed it. Returned by
/// `TriageRulesEngine.actionable` so callers can report *which* rule planned
/// each mutation — an over-broad rule is only diagnosable by name.
public struct RuleMatch: Sendable {
    public let message: MailMessage
    public let rule: TriageRule

    public init(message: MailMessage, rule: TriageRule) {
        self.message = message
        self.rule = rule
    }
}

/// Selects which of the rule-matched messages `mail apply-rules` may actually
/// touch. Pure and time-injectable so every guardrail (age floor, unread hold,
/// per-run cap, oldest-first ordering) is directly testable — these are the
/// only things standing between a bad rule and a mass archive.
public enum RuleApplyPlanner {
    public struct Plan: Sendable {
        public let planned: [RuleMatch]
        public let heldTooNew: Int
        public let heldUnread: Int
        public let heldOverCap: Int
    }

    public static func plan(
        matches: [RuleMatch],
        now: Date,
        minAgeDays: Int,
        skipUnread: Bool,
        maxActions: Int
    ) -> Plan {
        let cutoff = now.addingTimeInterval(-Double(minAgeDays) * 86400)
        var heldTooNew = 0
        var heldUnread = 0
        var eligible: [(match: RuleMatch, date: Date)] = []

        for match in matches {
            // A message whose date won't parse is held, never acted on: the age
            // guard fails closed.
            guard let date = parseISODate(match.message.date), date <= cutoff else {
                heldTooNew += 1
                continue
            }
            if skipUnread, !match.message.read {
                heldUnread += 1
                continue
            }
            eligible.append((match, date))
        }

        // Oldest first, so a capped run drains the oldest backlog instead of
        // skimming whatever the scan happened to return first.
        eligible.sort { $0.date < $1.date }

        return Plan(
            planned: eligible.prefix(maxActions).map(\.match),
            heldTooNew: heldTooNew,
            heldUnread: heldUnread,
            heldOverCap: max(0, eligible.count - maxActions)
        )
    }

    /// Parse an ISO 8601 timestamp with or without fractional seconds. Returns
    /// nil when neither shape parses, which the age guard treats as "too new".
    private static func parseISODate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

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
    /// Disabled rules (enabled=false) are always ignored.
    public static func apply(
        rules: [TriageRule],
        to messages: [MailMessage]
    ) -> (remaining: [MailMessage], ruleTriaged: [TriagedMessage]) {
        let activeRules = rules.filter(\.enabled)
        guard !activeRules.isEmpty else { return (messages, []) }

        var remaining: [MailMessage] = []
        var ruleTriaged: [TriagedMessage] = []

        for message in messages {
            if let match = firstMatch(rules: activeRules, message: message) {
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

    /// Messages whose first matching rule carries an actuating action
    /// (`moveTo` and/or `markRead`), paired with the rule that matched.
    ///
    /// Uses the same first-match-wins ordering as `apply`, so a message is
    /// never planned against a rule that `apply` would not have picked.
    /// `skip: true` rules never actuate: skip means "drop this message", and a
    /// skip rule that also carried a `moveTo` would mutate mail the user asked
    /// triage to ignore. Disabled rules are ignored, as everywhere else.
    public static func actionable(
        rules: [TriageRule],
        to messages: [MailMessage]
    ) -> [RuleMatch] {
        let activeRules = rules.filter(\.enabled)
        guard !activeRules.isEmpty else { return [] }

        return messages.compactMap { message in
            guard let rule = firstMatch(rules: activeRules, message: message) else { return nil }
            guard rule.action.skip != true, rule.action.isActuating else { return nil }
            return RuleMatch(message: message, rule: rule)
        }
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
