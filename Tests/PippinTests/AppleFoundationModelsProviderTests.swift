import Foundation
@_weakLinked import FoundationModels
@testable import PippinLib
import XCTest

/// Answers triage prompts with one entry per message in the prompt, and
/// rejects any prompt holding more than `maxMessages`, the way the on-device
/// model rejects a prompt over its context window.
private final class ContextLimitedTriageProvider: AIProvider, @unchecked Sendable {
    let maxMessages: Int
    private let lock = NSLock()
    private(set) var requestSizes: [Int] = []
    private(set) var schemaSizes: [Int?] = []

    init(maxMessages: Int) {
        self.maxMessages = maxMessages
    }

    func complete(prompt: String, system: String) throws -> String {
        try complete(prompt: prompt, system: system, options: AICompletionOptions())
    }

    func complete(prompt: String, system _: String, options: AICompletionOptions) throws -> String {
        let ids = prompt.components(separatedBy: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("ID: ") ? String(trimmed.dropFirst(4)) : nil
        }
        var schemaCount: Int?
        if case let .object(fields)? = options.schema, case let .array(_, _, max) = fields.first?.schema {
            schemaCount = max
        }
        lock.withLock {
            requestSizes.append(ids.count)
            schemaSizes.append(schemaCount)
        }
        if ids.count > maxMessages {
            throw AIProviderError.contextExceeded(limit: 4096, tokens: 5000)
        }
        let entries = ids.map {
            #"{"compoundId":"\#($0)","subject":"s","from":"f","category":"automated","urgency":1,"oneLiner":"o"}"#
        }
        return #"{"messages":[\#(entries.joined(separator: ","))],"summary":"part","actionItems":["a"]}"#
    }
}

private func message(_ id: String) -> MailMessage {
    MailMessage(
        id: id, account: "test", mailbox: "INBOX", subject: "Subject", from: "sender@example.com",
        to: ["me@example.com"], date: "2026-03-25T12:00:00Z", read: false
    )
}

final class AppleFoundationModelsProviderTests: XCTestCase {
    // MARK: - Schema conversion

    private func encoded(_ schema: AIOutputSchema) throws -> [String: Any] {
        guard #available(macOS 26, *) else { throw XCTSkip("FoundationModels needs macOS 26") }
        let generation = try AppleFoundationModelsProvider.generationSchema(schema)
        let data = try JSONEncoder().encode(generation)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTriageSchemaPinsIDsCategoriesAndCount() throws {
        let json = try encoded(TriageEngine.outputSchema(ids: ["a", "b", "a"]))
        XCTAssertEqual(json["required"] as? [String], ["messages", "summary", "actionItems"])
        let properties = try XCTUnwrap(json["properties"] as? [String: Any])
        let messages = try XCTUnwrap(properties["messages"] as? [String: Any])
        // A duplicate ID is listed once, and the count follows the unique IDs.
        XCTAssertEqual(messages["minItems"] as? Int, 2)
        XCTAssertEqual(messages["maxItems"] as? Int, 2)
        let defs = try XCTUnwrap(json["$defs"] as? [String: Any])
        let item = try XCTUnwrap(defs["Response_messagesItem"] as? [String: Any])
        let itemProperties = try XCTUnwrap(item["properties"] as? [String: Any])
        XCTAssertEqual((itemProperties["compoundId"] as? [String: Any])?["enum"] as? [String], ["a", "b"])
        XCTAssertEqual(
            (itemProperties["category"] as? [String: Any])?["enum"] as? [String],
            TriageCategory.allCases.map(\.rawValue)
        )
        XCTAssertEqual((itemProperties["urgency"] as? [String: Any])?["type"] as? String, "integer")
    }

    func testOptionalFieldsAreNotRequired() throws {
        let json = try encoded(.object([
            AIOutputField("title", .string),
            AIOutputField("end", .string, optional: true),
            AIOutputField("allDay", .boolean, optional: true),
            AIOutputField("score", .number),
        ]))
        XCTAssertEqual(json["required"] as? [String], ["title", "score"])
        let properties = try XCTUnwrap(json["properties"] as? [String: Any])
        XCTAssertEqual((properties["allDay"] as? [String: Any])?["type"] as? String, "boolean")
        XCTAssertEqual((properties["score"] as? [String: Any])?["type"] as? String, "number")
    }

    /// Every schema a feature supplies must convert; a name clash or empty
    /// choice would only surface on the first real request otherwise.
    func testEveryFeatureSchemaConverts() throws {
        for schema in [
            TriageEngine.outputSchema(ids: ["x"]), DataExtractor.outputSchema,
            PromptInjectionScanner.aiOutputSchema, ActionExtractor.outputSchema,
        ] {
            XCTAssertNotNil(try encoded(schema)["properties"])
        }
    }

    // MARK: - Errors

    func testContextSizeErrorNamesTheLimit() throws {
        #if compiler(>=6.4)
            guard #available(macOS 27, *) else { throw XCTSkip("LanguageModelError needs macOS 27") }
            let source = LanguageModelError.contextSizeExceeded(
                .init(contextSize: 8192, tokenCount: 9100, debugDescription: "too long")
            )
            let mapped = try XCTUnwrap(AppleFoundationModelsProvider.mapError(source) as? AIProviderError)
            guard case .contextExceeded(limit: 8192, tokens: 9100) = mapped else {
                return XCTFail("unexpected mapping: \(mapped)")
            }
            XCTAssertEqual(mapped.agentCode, "context_exceeded")
            XCTAssertTrue(mapped.localizedDescription.contains("8192-token"))
        #else
            throw XCTSkip("LanguageModelError needs the macOS 27 SDK")
        #endif
    }

    func testUnavailableModelIsANotAvailableError() {
        let error = AIProviderError.modelUnavailable("Apple Intelligence is turned off")
        XCTAssertEqual(error.agentCode, "not_available")
        XCTAssertEqual(PippinExitCode.classify(error.agentCode), 4)
        XCTAssertNotNil(error.remediation)
    }

    func testFactoryBuildsAppleProvider() throws {
        let path = NSTemporaryDirectory() + "pippin-apple-\(UUID().uuidString).json"
        try Data(#"{"ai":{"provider":"apple"}}"#.utf8).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        setenv("PIPPIN_CONFIG", path, 1)
        defer { unsetenv("PIPPIN_CONFIG") }
        XCTAssertTrue(try AIProviderFactory.make() is AppleFoundationModelsProvider)
    }

    // MARK: - Triage chunking

    func testTriageSplitsABatchThatOverflowsTheContext() throws {
        let messages = (1 ... 10).map { message("id\($0)") }
        let provider = ContextLimitedTriageProvider(maxMessages: 3)
        let result = try TriageEngine.triage(messages: messages, provider: provider)

        XCTAssertEqual(result.messages.map(\.compoundId), messages.map(\.id))
        XCTAssertTrue(provider.requestSizes.contains(10), "the full batch was tried first")
        XCTAssertTrue(provider.requestSizes.contains { $0 <= 3 && $0 > 0 }, "smaller halves were sent")
        // Each request's schema pins the count to that request's messages.
        XCTAssertEqual(provider.requestSizes, provider.schemaSizes.map { $0 ?? -1 })
    }

    func testOneMessageOverTheContextStillFails() throws {
        let provider = ContextLimitedTriageProvider(maxMessages: 0)
        XCTAssertThrowsError(try TriageEngine.triage(messages: [message("only")], provider: provider)) { error in
            guard case .contextExceeded? = error as? AIProviderError else {
                return XCTFail("expected contextExceeded, got \(error)")
            }
        }
    }

    // MARK: - Real model (skipped where unavailable)

    func testRealModelReturnsSchemaShapedJSON() throws {
        if let problem = AppleFoundationModelsProvider.availabilityProblem() {
            throw XCTSkip("Apple on-device model unavailable: \(problem)")
        }
        let schema = AIOutputSchema.object([
            AIOutputField("title", .string),
            AIOutputField("priority", .integer, optional: true),
            AIOutputField("color", .choice(["red", "green"])),
        ])
        let raw = try AppleFoundationModelsProvider().complete(
            prompt: "Buy green paint, high priority.",
            system: "Turn the request into a task.",
            options: AICompletionOptions(jsonMode: true, schema: schema)
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertNotNil(object["title"] as? String)
        XCTAssertTrue(["red", "green"].contains(object["color"] as? String ?? ""))
    }
}
