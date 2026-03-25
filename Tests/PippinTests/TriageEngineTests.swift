@testable import PippinLib
import XCTest

private struct FakeTriageProvider: AIProvider {
    let response: String
    func complete(prompt _: String, system _: String) throws -> String {
        response
    }
}

private struct FailingTriageProvider: AIProvider {
    func complete(prompt _: String, system _: String) throws -> String {
        throw AIProviderError.networkError("simulated failure")
    }
}

// MARK: - Helpers

private func makeMessage(id: String, subject: String, from: String = "sender@example.com") -> MailMessage {
    MailMessage(
        id: id,
        account: "test",
        mailbox: "INBOX",
        subject: subject,
        from: from,
        to: ["me@example.com"],
        date: "2026-03-25T12:00:00Z",
        read: false
    )
}

private func triageJSON(for messages: [(id: String, subject: String, from: String, category: String, urgency: Int)],
                        summary: String = "Batch summary.",
                        actionItems: [String] = []) -> String
{
    let msgs = messages.map { m in
        """
        {
          "compoundId": "\(m.id)",
          "subject": "\(m.subject)",
          "from": "\(m.from)",
          "category": "\(m.category)",
          "urgency": \(m.urgency),
          "oneLiner": "One liner for \(m.subject)."
        }
        """
    }.joined(separator: ",\n")
    let items = actionItems.map { "\"\($0)\"" }.joined(separator: ", ")
    return """
    {
      "messages": [\(msgs)],
      "summary": "\(summary)",
      "actionItems": [\(items)]
    }
    """
}

// MARK: - Tests

final class TriageEngineTests: XCTestCase {
    /// 1. Single batch: 5 messages
    func testTriageSingleBatch() throws {
        let messages = (1 ... 5).map { makeMessage(id: "id\($0)", subject: "Subject \($0)") }
        let msgData = messages.map { (id: $0.id, subject: $0.subject, from: $0.from, category: "informational", urgency: 2) }
        let json = triageJSON(for: msgData, summary: "Five messages.", actionItems: ["Do something"])
        let provider = FakeTriageProvider(response: json)

        let result = try TriageEngine.triage(messages: messages, provider: provider)
        XCTAssertEqual(result.messages.count, 5)
        XCTAssertEqual(result.summary, "Five messages.")
        XCTAssertEqual(result.actionItems, ["Do something"])
    }

    /// 2. Multi-batch: 25 messages (batches of 10, 10, 5)
    func testTriageMultiBatch() throws {
        let messages = (1 ... 25).map { makeMessage(id: "id\($0)", subject: "Subject \($0)") }

        // The fake provider must return valid JSON for each batch call
        // We'll use a stateful provider that returns different JSON per call
        final class StatefulProvider: AIProvider, @unchecked Sendable {
            var callCount = 0
            func complete(prompt: String, system _: String) throws -> String {
                callCount += 1
                // Count messages in this prompt by counting "\n   ID:" occurrences
                let count = prompt.components(separatedBy: "   ID:").count - 1
                let msgs = (1 ... count).map { i in
                    (id: "id\(i + (callCount - 1) * 10)", subject: "Subject \(i)", from: "s@e.com", category: "informational", urgency: 1)
                }
                let summary = "Summary batch \(callCount)."
                return triageJSON(for: msgs, summary: summary)
            }
        }

        let provider = StatefulProvider()
        let result = try TriageEngine.triage(messages: messages, provider: provider)
        XCTAssertEqual(result.messages.count, 25)
        XCTAssertEqual(provider.callCount, 3)
        // Last batch summary wins
        XCTAssertEqual(result.summary, "Summary batch 3.")
    }

    /// 3. Action items deduplicated across batches
    func testTriageActionItemsDeduped() throws {
        // 12 messages -> 2 batches (10, 2)
        let messages = (1 ... 12).map { makeMessage(id: "id\($0)", subject: "Subj \($0)") }

        final class DedupProvider: AIProvider, @unchecked Sendable {
            var callCount = 0
            func complete(prompt: String, system _: String) throws -> String {
                callCount += 1
                let count = prompt.components(separatedBy: "   ID:").count - 1
                let msgs = (1 ... count).map { i in
                    (id: "id\(i + (callCount - 1) * 10)", subject: "Subj \(i)", from: "s@e.com", category: "informational", urgency: 1)
                }
                // Both batches share one action item; second batch adds a unique one
                let items = callCount == 1
                    ? ["shared action", "first-only action"]
                    : ["shared action", "second-only action"]
                return triageJSON(for: msgs, actionItems: items)
            }
        }

        let provider = DedupProvider()
        let result = try TriageEngine.triage(messages: messages, provider: provider)
        XCTAssertEqual(result.actionItems.count, 3)
        XCTAssertTrue(result.actionItems.contains("shared action"))
        XCTAssertTrue(result.actionItems.contains("first-only action"))
        XCTAssertTrue(result.actionItems.contains("second-only action"))
    }

    /// 4. triageBatchForSummaries: 12 messages -> 12 TriagedMessages
    func testTriageBatchForSummaries() throws {
        let messages = (1 ... 12).map { makeMessage(id: "id\($0)", subject: "Subj \($0)") }

        final class SummaryProvider: AIProvider, @unchecked Sendable {
            var callCount = 0
            func complete(prompt: String, system _: String) throws -> String {
                callCount += 1
                let count = prompt.components(separatedBy: "   ID:").count - 1
                let msgs = (1 ... count).map { i in
                    (id: "id\(i + (callCount - 1) * 10)", subject: "Subj \(i)", from: "s@e.com", category: "informational", urgency: 1)
                }
                return triageJSON(for: msgs)
            }
        }

        let provider = SummaryProvider()
        let triaged = try TriageEngine.triageBatchForSummaries(messages: messages, provider: provider)
        XCTAssertEqual(triaged.count, 12)
        XCTAssertEqual(provider.callCount, 2)
    }

    /// 5. Throws malformedAIResponse on non-JSON
    func testTriageThrowsMalformedAIResponse() throws {
        let messages = [makeMessage(id: "id1", subject: "Test")]
        let provider = FakeTriageProvider(response: "This is not JSON at all.")

        XCTAssertThrowsError(
            try TriageEngine.triage(messages: messages, provider: provider)
        ) { error in
            guard case MailAIError.malformedAIResponse = error else {
                XCTFail("Expected MailAIError.malformedAIResponse, got \(error)")
                return
            }
        }
    }

    /// 6. Markdown fence stripping
    func testTriageMarkdownFenceStripping() throws {
        let messages = [makeMessage(id: "acc||INBOX||1", subject: "Hello")]
        let innerJSON = triageJSON(
            for: [(id: "acc||INBOX||1", subject: "Hello", from: "sender@example.com", category: "informational", urgency: 2)],
            summary: "Just one."
        )
        let fenced = "```json\n\(innerJSON)\n```"
        let provider = FakeTriageProvider(response: fenced)

        let result = try TriageEngine.triage(messages: messages, provider: provider)
        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.messages[0].subject, "Hello")
    }

    /// 7. TriagedMessage codable round-trip
    func testTriagedMessageCodable() throws {
        let original = TriagedMessage(
            compoundId: "acc||INBOX||42",
            subject: "Important meeting",
            from: "boss@company.com",
            category: .urgent,
            urgency: 5,
            oneLiner: "Boss wants you in the meeting room NOW."
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TriagedMessage.self, from: data)

        XCTAssertEqual(decoded.compoundId, original.compoundId)
        XCTAssertEqual(decoded.subject, original.subject)
        XCTAssertEqual(decoded.from, original.from)
        XCTAssertEqual(decoded.category, .urgent)
        XCTAssertEqual(decoded.urgency, 5)
        XCTAssertEqual(decoded.oneLiner, original.oneLiner)
    }

    /// 8. TriageCategory raw values
    func testTriageCategoryRawValues() {
        XCTAssertEqual(TriageCategory.urgent.rawValue, "urgent")
        XCTAssertEqual(TriageCategory.actionRequired.rawValue, "actionRequired")
        XCTAssertEqual(TriageCategory.informational.rawValue, "informational")
        XCTAssertEqual(TriageCategory.promotional.rawValue, "promotional")
        XCTAssertEqual(TriageCategory.automated.rawValue, "automated")
        XCTAssertEqual(TriageCategory.allCases.count, 5)
    }

    /// 9. summarizeMessage uses body (or fallback)
    func testSummarizeMessageUsesBody() throws {
        let message = MailMessage(
            id: "acc||INBOX||1",
            account: "acc",
            mailbox: "INBOX",
            subject: "Test",
            from: "a@b.com",
            to: ["me@c.com"],
            date: "2026-03-25T12:00:00Z",
            read: false,
            body: "This is the email body."
        )
        let provider = FakeTriageProvider(response: "Two sentence summary. It covers the main points.")
        let summary = try TriageEngine.summarizeMessage(message: message, provider: provider)
        XCTAssertEqual(summary, "Two sentence summary. It covers the main points.")
    }

    /// 10. triage with zero messages returns empty result without calling AI
    func testTriageEmptyMessages() throws {
        struct FailingProvider: AIProvider {
            func complete(prompt _: String, system _: String) throws -> String {
                throw AIProviderError.networkError("should not be called")
            }
        }
        let result = try TriageEngine.triage(messages: [], provider: FailingProvider())
        XCTAssertTrue(result.messages.isEmpty)
        XCTAssertEqual(result.summary, "")
        XCTAssertTrue(result.actionItems.isEmpty)
    }

    /// 11. exactly 10 messages produces one batch (one AI call)
    func testTriageTenMessagesSingleBatch() throws {
        let messages = (1 ... 10).map { makeMessage(id: "acc||INBOX||\($0)", subject: "Subject \($0)") }
        let msgData = messages.map { (id: $0.id, subject: $0.subject, from: $0.from, category: "informational", urgency: 2) }
        let json = triageJSON(for: msgData, summary: "Ten messages.")

        final class CountingProvider: AIProvider, @unchecked Sendable {
            var callCount = 0
            let response: String
            init(response: String) {
                self.response = response
            }

            func complete(prompt _: String, system _: String) throws -> String {
                callCount += 1
                return response
            }
        }

        let provider = CountingProvider(response: json)
        let result = try TriageEngine.triage(messages: messages, provider: provider)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(result.messages.count, 10)
    }

    /// 12. 11 messages produces two batches (two AI calls)
    func testTriageElevenMessagesTwoBatches() throws {
        let messages = (1 ... 11).map { makeMessage(id: "acc||INBOX||\($0)", subject: "Subject \($0)") }

        final class TwoBatchProvider: AIProvider, @unchecked Sendable {
            var callCount = 0
            func complete(prompt: String, system _: String) throws -> String {
                callCount += 1
                let count = prompt.components(separatedBy: "   ID:").count - 1
                let offset = (callCount - 1) * 10
                let msgs = (1 ... max(count, 1)).map { i in
                    (id: "acc||INBOX||\(i + offset)", subject: "Subject \(i + offset)", from: "s@e.com", category: "informational", urgency: 1)
                }
                return triageJSON(for: msgs, summary: "Batch \(callCount) summary.")
            }
        }

        let provider = TwoBatchProvider()
        let result = try TriageEngine.triage(messages: messages, provider: provider)
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertEqual(result.messages.count, 11)
    }

    /// 13. summarizeMessage with nil body passes "(no body)" to provider
    func testSummarizeMessageNilBody() throws {
        final class CapturingProvider: AIProvider, @unchecked Sendable {
            var capturedPrompt: String = ""
            func complete(prompt: String, system _: String) throws -> String {
                capturedPrompt = prompt
                return "Summary of empty message."
            }
        }
        let message = MailMessage(
            id: "acc||INBOX||1",
            account: "acc",
            mailbox: "INBOX",
            subject: "Test",
            from: "test@example.com",
            to: [],
            date: "2026-01-01",
            read: false,
            body: nil
        )
        let provider = CapturingProvider()
        let summary = try TriageEngine.summarizeMessage(message: message, provider: provider)
        XCTAssertEqual(provider.capturedPrompt, "(no body)")
        XCTAssertEqual(summary, "Summary of empty message.")
    }

    /// 14. fence stripping with trailing text after closing fence
    func testTriageMarkdownFenceWithTrailingText() throws {
        let messages = [makeMessage(id: "acc||INBOX||1", subject: "Hello")]
        let innerJSON = triageJSON(
            for: [(id: "acc||INBOX||1", subject: "Hello", from: "sender@example.com", category: "informational", urgency: 2)],
            summary: "Just one."
        )
        // trailing text after the closing fence — old dropLast() would drop this line instead of ```
        let fenced = "```json\n\(innerJSON)\n```\nsome trailing note"
        let provider = FakeTriageProvider(response: fenced)

        let result = try TriageEngine.triage(messages: messages, provider: provider)
        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.messages[0].subject, "Hello")
    }
}
