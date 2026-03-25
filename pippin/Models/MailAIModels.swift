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
