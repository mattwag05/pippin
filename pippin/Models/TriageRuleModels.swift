import Foundation

// MARK: - TriageRule

public struct TriageRule: Codable, Sendable {
    public let id: String
    public let name: String
    public let conditions: [RuleCondition]
    public let conditionOperator: ConditionOperator
    public let action: RuleAction
    public let enabled: Bool

    public init(
        id: String,
        name: String,
        conditions: [RuleCondition],
        conditionOperator: ConditionOperator = .and,
        action: RuleAction,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.conditions = conditions
        self.conditionOperator = conditionOperator
        self.action = action
        self.enabled = enabled
    }
}

// MARK: - RuleCondition

public struct RuleCondition: Codable, Sendable {
    public let field: RuleField
    public let matchOperator: MatchOperator
    public let value: String

    enum CodingKeys: String, CodingKey {
        case field
        case matchOperator = "operator"
        case value
    }

    public init(field: RuleField, matchOperator: MatchOperator, value: String) {
        self.field = field
        self.matchOperator = matchOperator
        self.value = value
    }
}

// MARK: - Enums

public enum RuleField: String, Codable, Sendable {
    case sender
    case subject
    case keyword // matches bodyPreview if present, otherwise subject
    case account
}

public enum MatchOperator: String, Codable, Sendable {
    case contains
    case equals
    case startsWith
    case matches // regex (case-insensitive)
}

public enum ConditionOperator: String, Codable, Sendable {
    case and
    case or
}

// MARK: - RuleAction

public struct RuleAction: Codable, Sendable {
    public let setCategory: TriageCategory?
    public let setUrgency: Int?
    public let label: String?
    public let skip: Bool? // true = exclude from triage results entirely
    public let moveTo: String? // destination mailbox — actuated by `mail apply-rules`
    public let markRead: Bool? // actuated by `mail apply-rules`

    public init(
        setCategory: TriageCategory? = nil,
        setUrgency: Int? = nil,
        label: String? = nil,
        skip: Bool? = nil,
        moveTo: String? = nil,
        markRead: Bool? = nil
    ) {
        self.setCategory = setCategory
        self.setUrgency = setUrgency
        self.label = label
        self.skip = skip
        self.moveTo = moveTo
        self.markRead = markRead
    }

    /// True when this action mutates the mailbox rather than only classifying.
    /// `mail triage` ignores actuating fields entirely; only `mail apply-rules`
    /// executes them, so adding one to a rules file never makes triage mutate.
    public var isActuating: Bool {
        moveTo != nil || markRead != nil
    }
}

// MARK: - Rule actuation (mail apply-rules)

/// One planned — or, after a `--live` run, performed — actuation of a rule
/// against a single message.
public struct RuleApplyAction: Codable, Sendable {
    public let messageId: String
    public let subject: String
    public let from: String
    public let date: String
    public let rule: String
    public let moveTo: String?
    public let markRead: Bool?
    public let applied: Bool
    public let error: String?

    public init(
        messageId: String,
        subject: String,
        from: String,
        date: String,
        rule: String,
        moveTo: String? = nil,
        markRead: Bool? = nil,
        applied: Bool = false,
        error: String? = nil
    ) {
        self.messageId = messageId
        self.subject = subject
        self.from = from
        self.date = date
        self.rule = rule
        self.moveTo = moveTo
        self.markRead = markRead
        self.applied = applied
        self.error = error
    }
}

/// Planned actuations for one sender. The plan is grouped by sender because a
/// count-only summary hides an over-broad rule: a `@example.org` domain rule
/// that also sweeps up two individual humans is only visible when each sender
/// is listed separately.
public struct RuleApplySenderGroup: Codable, Sendable {
    public let sender: String
    public let count: Int
    public let actions: [RuleApplyAction]

    public init(sender: String, count: Int, actions: [RuleApplyAction]) {
        self.sender = sender
        self.count = count
        self.actions = actions
    }
}

public struct RuleApplyResult: Codable, Sendable {
    public let dryRun: Bool
    public let scanned: Int
    public let matched: Int
    public let planned: Int
    public let applied: Int
    public let failed: Int
    public let heldTooNew: Int
    public let heldUnread: Int
    public let heldOverCap: Int
    public let bySender: [RuleApplySenderGroup]

    public init(
        dryRun: Bool,
        scanned: Int,
        matched: Int,
        planned: Int,
        applied: Int,
        failed: Int,
        heldTooNew: Int,
        heldUnread: Int,
        heldOverCap: Int,
        bySender: [RuleApplySenderGroup]
    ) {
        self.dryRun = dryRun
        self.scanned = scanned
        self.matched = matched
        self.planned = planned
        self.applied = applied
        self.failed = failed
        self.heldTooNew = heldTooNew
        self.heldUnread = heldUnread
        self.heldOverCap = heldOverCap
        self.bySender = bySender
    }
}
