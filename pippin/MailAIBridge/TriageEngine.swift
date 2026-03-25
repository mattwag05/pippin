import Foundation

public enum TriageEngine {
    /// Triage messages using metadata only (no body reads).
    /// Batches of 10 are dispatched concurrently (max 4 in-flight) to reduce AI round-trip latency.
    public static func triage(
        messages: [MailMessage],
        provider: any AIProvider
    ) throws -> TriageResult {
        let batches = stride(from: 0, to: messages.count, by: 10).map {
            Array(messages[$0 ..< min($0 + 10, messages.count)])
        }

        nonisolated(unsafe) var batchResults: [(index: Int, result: BatchResponse)] = []
        nonisolated(unsafe) var firstError: Error?

        let group = DispatchGroup()
        let lock = NSLock()
        let rateLimiter = DispatchSemaphore(value: 4)

        for (i, batch) in batches.enumerated() {
            rateLimiter.wait()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer {
                    rateLimiter.signal()
                    group.leave()
                }
                lock.lock()
                guard firstError == nil else {
                    lock.unlock()
                    return
                }
                lock.unlock()
                do {
                    let result = try triageBatch(batch, provider: provider)
                    lock.lock()
                    batchResults.append((index: i, result: result))
                    lock.unlock()
                } catch {
                    lock.lock()
                    if firstError == nil { firstError = error }
                    lock.unlock()
                }
            }
        }

        group.wait()

        if let error = firstError {
            throw error
        }

        batchResults.sort { $0.index < $1.index }

        var allTriaged: [TriagedMessage] = []
        var lastSummary = ""
        var allActionItems: [String] = []
        for (_, batchResult) in batchResults {
            allTriaged.append(contentsOf: batchResult.messages)
            lastSummary = batchResult.summary
            for item in batchResult.actionItems {
                if !allActionItems.contains(item) {
                    allActionItems.append(item)
                }
            }
        }

        return TriageResult(
            messages: allTriaged,
            summary: lastSummary,
            actionItems: allActionItems
        )
    }

    /// Get one-liners for a list of messages (for --summarize on mail list).
    /// Batches are dispatched concurrently (max 4 in-flight).
    public static func triageBatchForSummaries(
        messages: [MailMessage],
        provider: any AIProvider
    ) throws -> [TriagedMessage] {
        let batches = stride(from: 0, to: messages.count, by: 10).map {
            Array(messages[$0 ..< min($0 + 10, messages.count)])
        }

        nonisolated(unsafe) var batchResults: [(index: Int, messages: [TriagedMessage])] = []
        nonisolated(unsafe) var firstError: Error?

        let group = DispatchGroup()
        let lock = NSLock()
        let rateLimiter = DispatchSemaphore(value: 4)

        for (i, batch) in batches.enumerated() {
            rateLimiter.wait()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer {
                    rateLimiter.signal()
                    group.leave()
                }
                lock.lock()
                guard firstError == nil else {
                    lock.unlock()
                    return
                }
                lock.unlock()
                do {
                    let result = try triageBatch(batch, provider: provider)
                    lock.lock()
                    batchResults.append((index: i, messages: result.messages))
                    lock.unlock()
                } catch {
                    lock.lock()
                    if firstError == nil { firstError = error }
                    lock.unlock()
                }
            }
        }

        group.wait()

        if let error = firstError {
            throw error
        }

        return batchResults
            .sorted { $0.index < $1.index }
            .flatMap(\.messages)
    }

    /// Single message summary (for --summarize on mail show — DOES call readMessage)
    public static func summarizeMessage(
        message: MailMessage,
        provider: any AIProvider
    ) throws -> String {
        let body = message.body ?? "(no body)"
        return try provider.complete(prompt: body, system: MailAIPrompts.singleSummarySystemPrompt)
    }

    // MARK: - Private

    private struct BatchResponse: Codable {
        let messages: [TriagedMessage]
        let summary: String
        let actionItems: [String]
    }

    private static func triageBatch(_ batch: [MailMessage], provider: any AIProvider) throws -> BatchResponse {
        var prompt = "Messages to triage:\n\n"
        for (i, msg) in batch.enumerated() {
            prompt += "\(i + 1). Subject: \(msg.subject)\n   From: \(msg.from)\n   Date: \(msg.date)\n   ID: \(msg.id)\n\n"
        }

        let response = try provider.complete(prompt: prompt, system: MailAIPrompts.triageSystemPrompt)

        let stripped = stripAIResponseJSON(response)

        do {
            return try JSONDecoder().decode(BatchResponse.self, from: Data(stripped.utf8))
        } catch {
            throw MailAIError.malformedAIResponse(response)
        }
    }
}
