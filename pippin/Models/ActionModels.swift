import Foundation

public enum ActionSource: String, Codable, Sendable {
    case mail
    case note
}

public struct ExtractedAction: Codable, Sendable {
    public let source: ActionSource
    public let sourceId: String
    public let sourceTitle: String?
    public let snippet: String
    public let proposedTitle: String
    public let proposedDueDate: String?
    public let proposedPriority: Int?
    public let confidence: Float

    public init(
        source: ActionSource,
        sourceId: String,
        sourceTitle: String? = nil,
        snippet: String,
        proposedTitle: String,
        proposedDueDate: String? = nil,
        proposedPriority: Int? = nil,
        confidence: Float
    ) {
        self.source = source
        self.sourceId = sourceId
        self.sourceTitle = sourceTitle
        self.snippet = snippet
        self.proposedTitle = proposedTitle
        self.proposedDueDate = proposedDueDate
        self.proposedPriority = proposedPriority
        self.confidence = confidence
    }
}

public enum ActionExtractorError: LocalizedError, Sendable {
    case malformedAIResponse(String)
    case noSourcesSelected

    public var errorDescription: String? {
        switch self {
        case let .malformedAIResponse(raw):
            return "Failed to parse AI response as action list. Raw: \(raw.prefix(300))"
        case .noSourcesSelected:
            return "No sources selected. Enable at least one of --mail or --notes."
        }
    }
}
