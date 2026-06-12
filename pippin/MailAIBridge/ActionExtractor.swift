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

    private static let batchSize = 10

    /// Convenience: extract under an unlimited budget (CLI/tests). Discards the
    /// `timedOut` flag (always false here) and throws on the first batch error,
    /// preserving the original fail-fast contract.
    public static func extract(
        items: [Item],
        provider: any AIProvider,
        minConfidence: Float = 0.5
    ) throws -> [ExtractedAction] {
        try extract(items: items, provider: provider, minConfidence: minConfidence, budget: BatchBudget(softTimeoutMs: 0)).actions
    }

    /// Budget-aware extraction: bounds the whole AI pass by `budget` so an MCP
    /// caller gets partial results + `timedOut: true` instead of a 60s SIGKILL
    /// halfway through. Under an unlimited budget (CLI) it waits for every batch
    /// and throws on the first batch error (fail-fast, as before). When the
    /// deadline fires, abandoned batches are dropped — and their errors swallowed
    /// — in favor of the successes already gathered. (pippin-hzg)
    public static func extract(
        items: [Item],
        provider: any AIProvider,
        minConfidence: Float = 0.5,
        budget: BatchBudget
    ) throws -> (actions: [ExtractedAction], timedOut: Bool) {
        guard !items.isEmpty else { return ([], false) }

        let systemPrompt = renderSystemPrompt(now: Date())
        let batches = stride(from: 0, to: items.count, by: batchSize).map {
            Array(items[$0 ..< min($0 + batchSize, items.count)])
        }

        // One slot per batch; nil after the wait means the batch was abandoned
        // past the deadline. A semaphore caps in-flight AI calls at 4 (matching
        // the prior maxConcurrent) so we don't oversubscribe a local model.
        let slots = batches.map { _ in ConcurrentSlot<Result<BatchResponse, Error>>() }
        let rateLimiter = DispatchSemaphore(value: 4)
        let tasks: [@Sendable () -> Void] = zip(batches, slots).map { batch, slot in
            {
                rateLimiter.wait()
                defer { rateLimiter.signal() }
                do {
                    try slot.set(.success(extractBatch(batch, provider: provider, systemPrompt: systemPrompt)))
                } catch {
                    slot.set(.failure(error))
                }
            }
        }
        let completed = runConcurrentlyWithBudget(budgetMs: budget.softTimeoutMs, tasks)
        let timedOut = !completed

        var all: [ExtractedAction] = []
        var firstError: Error?
        for (batch, slot) in zip(batches, slots) {
            switch slot.get() {
            case let .success(response):
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
            case let .failure(error):
                if firstError == nil { firstError = error }
            case .none:
                break // abandoned past the deadline — counted via `timedOut`
            }
        }
        // Surface a real batch error only when the budget didn't cut us short; on
        // a timeout we prefer the partial successes we did gather.
        if !timedOut, let firstError { throw firstError }
        return (all, timedOut)
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

    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }()

    private static let timeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "HH:mm"
        return fmt
    }()

    private static func renderSystemPrompt(now: Date) -> String {
        BuiltInTemplates.extractActions.content
            .replacingOccurrences(of: "{{CURRENT_DATE}}", with: dateFormatter.string(from: now))
            .replacingOccurrences(of: "{{CURRENT_TIME}}", with: timeFormatter.string(from: now))
    }

    private static func extractBatch(
        _ batch: [Item],
        provider: any AIProvider,
        systemPrompt: String
    ) throws -> BatchResponse {
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

        let response = try provider.complete(
            prompt: promptJSON,
            system: systemPrompt,
            options: AICompletionOptions(jsonMode: true)
        )
        let stripped = stripAIResponseJSON(response)
        do {
            return try JSONDecoder().decode(BatchResponse.self, from: Data(stripped.utf8))
        } catch {
            throw ActionExtractorError.malformedAIResponse(response)
        }
    }
}
