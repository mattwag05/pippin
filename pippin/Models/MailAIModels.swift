import Foundation

// MARK: - Embedding Models

public struct IndexResult: Codable, Sendable {
    public let indexed: Int
    public let skipped: Int
    public let total: Int

    public init(indexed: Int, skipped: Int, total: Int) {
        self.indexed = indexed
        self.skipped = skipped
        self.total = total
    }
}

// MARK: - Prompt Injection Models

public struct ScanResult: Codable, Sendable {
    public let originalBody: String
    public let sanitizedBody: String
    public let threats: [Threat]
    public let riskLevel: RiskLevel

    public init(originalBody: String, sanitizedBody: String, threats: [Threat], riskLevel: RiskLevel) {
        self.originalBody = originalBody
        self.sanitizedBody = sanitizedBody
        self.threats = threats
        self.riskLevel = riskLevel
    }
}

public struct Threat: Codable, Sendable {
    public let category: ThreatCategory
    public let confidence: Float
    public let matchedText: String
    public let explanation: String

    public init(category: ThreatCategory, confidence: Float, matchedText: String, explanation: String) {
        self.category = category
        self.confidence = confidence
        self.matchedText = matchedText
        self.explanation = explanation
    }
}

public enum ThreatCategory: String, Codable, Sendable, CaseIterable {
    case boundaryManipulation
    case systemPromptOverride
    case dataExfiltration
    case roleHijacking
    case toolInvocation
    case encodingTricks
}

public enum RiskLevel: String, Codable, Sendable {
    case none, low, medium, high, critical
}

// MARK: - Data Extraction Models

public struct ExtractionResult: Codable, Sendable {
    public let dates: [ExtractedDate]
    public let amounts: [ExtractedAmount]
    public let trackingNumbers: [String]
    public let actionItems: [String]
    public let contacts: [ExtractedContact]
    public let urls: [String]

    public init(
        dates: [ExtractedDate],
        amounts: [ExtractedAmount],
        trackingNumbers: [String],
        actionItems: [String],
        contacts: [ExtractedContact],
        urls: [String]
    ) {
        self.dates = dates
        self.amounts = amounts
        self.trackingNumbers = trackingNumbers
        self.actionItems = actionItems
        self.contacts = contacts
        self.urls = urls
    }
}

public struct ExtractedDate: Codable, Sendable {
    public let text: String
    public let isoDate: String?
    public let context: String

    public init(text: String, isoDate: String?, context: String) {
        self.text = text
        self.isoDate = isoDate
        self.context = context
    }
}

public struct ExtractedAmount: Codable, Sendable {
    public let text: String
    public let value: Double?
    public let currency: String?
    public let context: String

    public init(text: String, value: Double?, currency: String?, context: String) {
        self.text = text
        self.value = value
        self.currency = currency
        self.context = context
    }
}

public struct ExtractedContact: Codable, Sendable {
    public let name: String?
    public let email: String?
    public let phone: String?

    public init(name: String?, email: String?, phone: String?) {
        self.name = name
        self.email = email
        self.phone = phone
    }
}

// MARK: - Triage Models

public struct TriageResult: Codable, Sendable {
    public let messages: [TriagedMessage]
    public let summary: String
    public let actionItems: [String]

    public init(messages: [TriagedMessage], summary: String, actionItems: [String]) {
        self.messages = messages
        self.summary = summary
        self.actionItems = actionItems
    }
}

public struct TriagedMessage: Codable, Sendable {
    public let compoundId: String
    public let subject: String
    public let from: String
    public let category: TriageCategory
    public let urgency: Int
    public let oneLiner: String

    public init(compoundId: String, subject: String, from: String, category: TriageCategory, urgency: Int, oneLiner: String) {
        self.compoundId = compoundId
        self.subject = subject
        self.from = from
        self.category = category
        self.urgency = urgency
        self.oneLiner = oneLiner
    }
}

public enum TriageCategory: String, Codable, Sendable, CaseIterable {
    case urgent
    case actionRequired
    case informational
    case promotional
    case automated
}

// MARK: - Semantic Search Models

public struct SemanticSearchResult: Codable, Sendable {
    public let compoundId: String
    public let score: Float
    public init(compoundId: String, score: Float) {
        self.compoundId = compoundId
        self.score = score
    }
}
