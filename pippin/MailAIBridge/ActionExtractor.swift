import Foundation

public enum ActionExtractor {
    public struct Item: Sendable {
        public let source: ActionSource
        public let sourceId: String
        public let sourceTitle: String?
        public let text: String

        public init(source: ActionSource, sourceId: String, sourceTitle: String?, text: String) {
            self.source = source
            self.sourceId = sourceId
            self.sourceTitle = sourceTitle
            self.text = text
        }
    }

    public static func extract(
        items: [Item],
        provider: any AIProvider,
        minConfidence: Float = 0.5
    ) throws -> [ExtractedAction] {
        guard !items.isEmpty else { return [] }

        let batches = stride(from: 0, to: items.count, by: 10).map {
            Array(items[$0 ..< min($0 + 10, items.count)])
        }
        let responses = try runConcurrently(batches, maxConcurrent: 4, failFast: true) { batch in
            try extractBatch(batch, provider: provider)
        }

        var all: [ExtractedAction] = []
        for (batch, response) in zip(batches, responses) {
            for entry in response.actions where entry.confidence >= minConfidence {
                guard entry.sourceIndex >= 0, entry.sourceIndex < batch.count else { continue }
                let item = batch[entry.sourceIndex]
                all.append(
                    ExtractedAction(
                        source: item.source,
                        sourceId: item.sourceId,
                        sourceTitle: item.sourceTitle,
                        snippet: entry.snippet,
                        proposedTitle: entry.proposedTitle,
                        proposedDueDate: entry.proposedDueDate,
                        proposedPriority: entry.proposedPriority,
                        confidence: entry.confidence
                    )
                )
            }
        }
        return all
    }

    // MARK: - Private

    private struct BatchResponse: Codable {
        let actions: [Entry]
    }

    private struct Entry: Codable {
        let sourceIndex: Int
        let snippet: String
        let proposedTitle: String
        let proposedDueDate: String?
        let proposedPriority: Int?
        let confidence: Float
    }

    private struct PromptItem: Encodable {
        let sourceIndex: Int
        let kind: String
        let title: String?
        let text: String
    }

    private static func extractBatch(_ batch: [Item], provider: any AIProvider) throws -> BatchResponse {
        let now = Date()
        let dateFmt = DateFormatter()
        dateFmt.locale = Locale(identifier: "en_US_POSIX")
        dateFmt.dateFormat = "yyyy-MM-dd"
        let today = dateFmt.string(from: now)

        let timeFmt = DateFormatter()
        timeFmt.locale = Locale(identifier: "en_US_POSIX")
        timeFmt.dateFormat = "HH:mm"
        let currentTime = timeFmt.string(from: now)

        let systemPrompt = BuiltInTemplates.extractActions.content
            .replacingOccurrences(of: "{{CURRENT_DATE}}", with: today)
            .replacingOccurrences(of: "{{CURRENT_TIME}}", with: currentTime)

        let promptItems = batch.enumerated().map { index, item in
            PromptItem(
                sourceIndex: index,
                kind: item.source.rawValue,
                title: item.sourceTitle,
                text: item.text
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        let promptData = try encoder.encode(promptItems)
        let promptJSON = String(data: promptData, encoding: .utf8) ?? "[]"

        let response = try provider.complete(prompt: promptJSON, system: systemPrompt)
        let stripped = stripAIResponseJSON(response)
        do {
            return try JSONDecoder().decode(BatchResponse.self, from: Data(stripped.utf8))
        } catch {
            throw ActionExtractorError.malformedAIResponse(response)
        }
    }
}
