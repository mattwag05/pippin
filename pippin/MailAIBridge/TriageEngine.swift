import Foundation

public enum TriageEngine {

    // Triage messages using metadata only (no body reads)
    public static func triage(
        messages: [MailMessage],
        provider: any AIProvider
    ) throws -> TriageResult {
        let batches = stride(from: 0, to: messages.count, by: 10).map {
            Array(messages[$0..<min($0 + 10, messages.count)])
        }

        var allTriaged: [TriagedMessage] = []
        var lastSummary = ""
        var allActionItems: [String] = []

        for batch in batches {
            let batchResult = try triageBatch(batch, provider: provider)
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

    // Get one-liners for a list of messages (for --summarize on mail list)
    // Reuses triage batching but only surfaces oneLiner per message
    public static func triageBatchForSummaries(
        messages: [MailMessage],
        provider: any AIProvider
    ) throws -> [TriagedMessage] {
        let batches = stride(from: 0, to: messages.count, by: 10).map {
            Array(messages[$0..<min($0 + 10, messages.count)])
        }
        var all: [TriagedMessage] = []
        for batch in batches {
            let result = try triageBatch(batch, provider: provider)
            all.append(contentsOf: result.messages)
        }
        return all
    }

    // Single message summary (for --summarize on mail show — DOES call readMessage)
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

        var stripped = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.hasPrefix("```") {
            var lines = stripped.components(separatedBy: "\n")
            lines.removeFirst() // remove opening ```json or ```
            if lines.last?.hasPrefix("```") == true {
                lines.removeLast() // remove closing ```
            }
            stripped = lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !stripped.hasPrefix("{") || !stripped.hasSuffix("}") {
            if let firstBrace = stripped.firstIndex(of: "{"),
               let lastBrace = stripped.lastIndex(of: "}") {
                stripped = String(stripped[firstBrace...lastBrace])
            }
        }

        do {
            return try JSONDecoder().decode(BatchResponse.self, from: Data(stripped.utf8))
        } catch {
            throw MailAIError.malformedAIResponse(response)
        }
    }
}
