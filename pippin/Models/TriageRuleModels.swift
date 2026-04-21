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

    public init(
        setCategory: TriageCategory? = nil,
        setUrgency: Int? = nil,
        label: String? = nil,
        skip: Bool? = nil
    ) {
        self.setCategory = setCategory
        self.setUrgency = setUrgency
        self.label = label
        self.skip = skip
    }
}
