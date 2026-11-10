import ArgumentParser
import Foundation
@testable import PippinLib
import XCTest

/// Covers the v4 `error.next_step` contract across every conforming error type.
///
/// Not in the table: `BrowserCommandError`, `AudioCommandError`,
/// `SmartCalendarError` and `SmartReminderError`. They are private to their
/// command files and only thrown after a live browser, audio or AI call, so no
/// argument parse can reach them. Each has a fixed code and `.none` next step.
final class NextStepTests: XCTestCase {
    private static let underlying = NSError(domain: "test", code: 1)

    private static let table: [any RemediableError] = [
        // CursorError
        CursorError.cursorMismatch, CursorError.invalidCursor, CursorError.invalidPageSize, CursorError.invalidPage,
        // MessagesError
        MessagesError.databaseNotFound("p"), MessagesError.accessDenied("p"),
        MessagesError.conversationNotFound("c"), MessagesError.databaseError("e"),
        MessagesError.conversationExcluded("c"), MessagesError.ambiguousConversation("c", ["a", "b"]),
        // ConfigError
        ConfigError.invalid(path: "p", detail: "e"),
        // MessagesSendError
        MessagesSendError.timeout, MessagesSendError.scriptFailed("e"), MessagesSendError.phiFiltered(["ssn"]),
        MessagesSendError.recipientNotAllowed("r"), MessagesSendError.autonomousNotAuthorized,
        MessagesSendError.accessDenied, MessagesSendError.auditLogUnavailable(path: "p", detail: "e"),
        // ScriptRunnerError
        ScriptRunnerError.timeout, ScriptRunnerError.nonZeroExit("e"), ScriptRunnerError.stderrOnSuccess("e"),
        ScriptRunnerError.launchFailed("e"), ScriptRunnerError.automationDenied("com.apple.mail"),
        // AIProviderError
        AIProviderError.networkError("e"), AIProviderError.apiError(400, "e"), AIProviderError.apiError(503, "e"),
        AIProviderError.rateLimited(retryAfterSeconds: nil, "e"), AIProviderError.rateLimited(retryAfterSeconds: 7, "e"),
        AIProviderError.timeout, AIProviderError.providerUnreachable("e"), AIProviderError.decodingFailed("e"),
        AIProviderError.missingAPIKey, AIProviderError.modelNotFound(model: "m", available: ["a"]),
        AIProviderError.remoteModelNotFound(model: "m", baseURL: "http://x"), AIProviderError.invalidProvider("p"),
        AIProviderError.incompleteCompletion,
        // SchemaValidatorError
        SchemaValidatorError.missingRequired("f"), SchemaValidatorError.unexpectedArgument("f"),
        SchemaValidatorError.wrongType(field: "f", expected: "string", got: "int"),
        // IntentPlannerError
        IntentPlannerError.parseFailed(reason: "r", rawOutput: nil), IntentPlannerError.unknownTool("t"),
        IntentPlannerError.invalidPlan("p"),
        // VoiceMemosError
        VoiceMemosError.databaseNotFound("p"), VoiceMemosError.unsupportedSchemaVersion(1),
        VoiceMemosError.memoNotFound("i"), VoiceMemosError.memoEvicted("i"), VoiceMemosError.fileNotFound("p"),
        VoiceMemosError.exportFailed("e"), VoiceMemosError.ambiguousId("i", ["a", "b"]),
        VoiceMemosError.accessDenied("p"),
        // AudioConverterError
        AudioConverterError.formatUnsupported("f"), AudioConverterError.bufferAllocationFailed,
        AudioConverterError.conversionFailed("e"),
        // TranscriberError
        TranscriberError.notAvailable, TranscriberError.unsupportedProvider("p"), TranscriberError.failed("e"),
        // MCPToolArgError
        MCPToolArgError.missingRequired("k"), MCPToolArgError.wrongType(field: "f", expected: "string"),
        // MCPServerRuntimeError
        MCPServerRuntimeError.processLaunchFailed("p", underlying: underlying),
        MCPServerRuntimeError.childTimedOut(seconds: 1), MCPServerRuntimeError.childCrashed(signal: 11),
        MCPServerRuntimeError.childNoOutput(exitCode: 1), MCPServerRuntimeError.inProcessTimedOut(seconds: 1),
        MCPServerRuntimeError.notInProcessCapable("c"),
        // ContactsBridgeError
        ContactsBridgeError.accessDenied, ContactsBridgeError.contactNotFound("i"), ContactsBridgeError.fetchFailed("e"),
        ContactsBridgeError.groupNotFound("g"), ContactsBridgeError.saveFailed("e"), ContactsBridgeError.deleteFailed("e"),
        // RemindersBridgeError
        RemindersBridgeError.accessDenied, RemindersBridgeError.reminderNotFound("i"), RemindersBridgeError.listNotFound("l"),
        RemindersBridgeError.saveFailed("e"), RemindersBridgeError.ambiguousId("i"), RemindersBridgeError.noDefaultCalendar,
        // MailBridgeError
        MailBridgeError.scriptFailed("e"), MailBridgeError.messageNotFound("i"),
        MailBridgeError.accountNotFound("a", available: ["b"]), MailBridgeError.searchIncomplete, MailBridgeError.timeout,
        MailBridgeError.sendOutcomeUnknown, MailBridgeError.decodingFailed("e"), MailBridgeError.invalidMessageId("i"),
        MailBridgeError.invalidMailbox("m"), MailBridgeError.accessDenied,
        // NotesBridgeError
        NotesBridgeError.scriptFailed("e"), NotesBridgeError.noteNotFound("i"), NotesBridgeError.timeout,
        NotesBridgeError.decodingFailed("e"), NotesBridgeError.accessDenied,
        // ActionExtractorError
        ActionExtractorError.malformedAIResponse("e"), ActionExtractorError.noSourcesSelected,
        // BrowserBridgeError
        BrowserBridgeError.nodeNotInstalled, BrowserBridgeError.playwrightNotInstalled, BrowserBridgeError.sessionNotActive,
        BrowserBridgeError.navigationFailed("e"), BrowserBridgeError.elementNotFound("r"), BrowserBridgeError.scriptFailed("e"),
        BrowserBridgeError.decodingFailed("e"), BrowserBridgeError.timeout, BrowserBridgeError.fetchFailed("e"),
        // TemplateError
        TemplateError.notFound("t"), TemplateError.invalidFrontmatter("e"),
        // MemosCaptureError
        MemosCaptureError.noRecordings, MemosCaptureError.memoTooShort(memoId: "i"),
        MemosCaptureError.malformedAIResponse("e"), MemosCaptureError.listNotFound(name: "n", available: "a"),
        // BatchError
        BatchError.emptyInput, BatchError.invalidEntriesJSON("e"),
        // JobCommandError
        JobCommandError.launchFailed("e"), JobCommandError.waitTimedOut("i", timeoutSeconds: 1),
        JobCommandError.invalidDuration("d"),
        // CalendarNameResolutionError
        CalendarNameResolutionError.invalidCalendarName("n"),
        // DoError
        DoError.stepValidationFailed(tool: "t", underlying: underlying),
        DoError.buildArgsFailed(tool: "t", underlying: underlying),
        // MailAIError
        MailAIError.malformedAIResponse("e"), MailAIError.emptyEmbeddingIndex, MailAIError.embeddingFailed("e"),
        MailAIError.unsupportedEmbeddingProvider("p"), MailAIError.embeddingModelRequired("p"),
        MailAIError.noEmbeddingsForModel("m"),
        // JobStoreError
        JobStoreError.rootCreationFailed("p"), JobStoreError.jobNotFound("i"),
        JobStoreError.ambiguousPrefix("a", matches: ["ab"]), JobStoreError.statusReadFailed("p"),
        JobStoreError.statusWriteFailed("p"),
        // CalendarBridgeError
        CalendarBridgeError.accessDenied, CalendarBridgeError.eventNotFound("i"), CalendarBridgeError.calendarNotFound("c"),
        CalendarBridgeError.saveFailed("e"), CalendarBridgeError.ambiguousId("i"), CalendarBridgeError.dateParseError("d"),
        CalendarBridgeError.aiParseError("e"),
        // MailEnvelopeIndexError
        MailEnvelopeIndexError.databaseNotFound("p"), MailEnvelopeIndexError.unsupportedVersion(1),
        MailEnvelopeIndexError.accessDenied("p"), MailEnvelopeIndexError.accountsUnavailable("e"),
        MailEnvelopeIndexError.mailboxUnresolved("m"), MailEnvelopeIndexError.accountUnknown("a"),
        // AudioBridgeError
        AudioBridgeError.notAvailable, AudioBridgeError.processFailed("e"), AudioBridgeError.timeout,
        AudioBridgeError.decodingFailed("e"), AudioBridgeError.versionMismatch(installed: "1", pinned: "2"),
    ]

    /// Retrying a send that may have gone out could deliver it twice.
    private static let neverRetryable: Set<String> = ["send_outcome_unknown"]

    private struct NextCallRoot: ParsableCommand {
        static let configuration = CommandConfiguration(subcommands: [
            MailCommand.self, CalendarCommand.self, RemindersCommand.self, NotesCommand.self,
            ContactsCommand.self, MessagesCommand.self, MemosCommand.self, JobCommand.self, DoctorCommand.self,
        ])
    }

    private func isStableCode(_ code: String) -> Bool {
        code.range(of: "^[a-z0-9_]+$", options: .regularExpression) != nil
            && code.split(separator: "_", omittingEmptySubsequences: false).allSatisfy { $0.count >= 2 }
    }

    func testCodeValidatorRejectsGarbledCodes() {
        XCTAssertTrue(isStableCode("missing_api_key"))
        XCTAssertFalse(isStableCode("missing_a_p_i_key"))
        XCTAssertFalse(isStableCode("missingApiKey"))
        XCTAssertFalse(isStableCode(""))
    }

    func testEveryCodeIsStableSnakeCase() {
        for error in Self.table {
            XCTAssertTrue(isStableCode(error.agentCode), "\(error): '\(error.agentCode)'")
        }
    }

    func testRetryableMatchesExitClass() {
        for error in Self.table where !Self.neverRetryable.contains(error.agentCode) {
            XCTAssertEqual(
                error.nextStep.retryable, PippinExitCode.classify(error.agentCode) == 7,
                "\(error): code '\(error.agentCode)'"
            )
        }
    }

    func testSendOutcomeUnknownIsNeverRetryable() {
        let sends = Self.table.filter { Self.neverRetryable.contains($0.agentCode) }
        XCTAssertEqual(sends.count, 2, "MailBridgeError.sendOutcomeUnknown and MessagesSendError.timeout")
        for error in sends {
            XCTAssertFalse(error.nextStep.retryable, "\(error)")
            XCTAssertNil(error.nextStep.retryAfterSeconds, "\(error)")
        }
    }

    func testRetryAfterIsPositiveWhenSet() {
        for error in Self.table {
            if let seconds = error.nextStep.retryAfterSeconds {
                XCTAssertGreaterThan(seconds, 0, "\(error)")
            }
        }
    }

    func testNextCallsNameRealToolsWithValidArgsAndArgv() throws {
        var checked = 0
        for error in Self.table {
            guard let call = error.nextStep.nextCall else { continue }
            checked += 1
            guard let tool = MCPToolRegistry.tool(named: call.tool) else {
                XCTFail("\(error): unknown tool '\(call.tool)'")
                continue
            }
            var properties: [String: JSONValue] = [:]
            if case let .object(found)? = tool.inputSchema["properties"] { properties = found }
            for key in call.args.keys {
                XCTAssertNotNil(properties[key], "\(error): '\(key)' is not in \(call.tool)'s schema")
            }
            for key in tool.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                XCTAssertNotNil(call.args[key], "\(error): required '\(key)' missing for \(call.tool)")
            }
            let parsed = try NextCallRoot.parseAsRoot(call.argv)
            XCTAssertFalse(parsed is NextCallRoot, "\(error): argv \(call.argv) selected no subcommand")
        }
        XCTAssertGreaterThan(checked, 0)
    }

    // MARK: - Envelope

    private func encodedError(_ error: Error) throws -> [String: Any] {
        let data = try JSONEncoder().encode(AgentError.from(error))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["error"] as? [String: Any])
    }

    func testAccessDeniedEncodesHumanAction() throws {
        let payload = try encodedError(MailBridgeError.accessDenied)
        XCTAssertEqual(payload["code"] as? String, "access_denied")
        let step = try XCTUnwrap(payload["next_step"] as? [String: Any])
        XCTAssertEqual(step["retryable"] as? Bool, false)
        XCTAssertFalse(try XCTUnwrap(step["human_action"] as? String).isEmpty)
    }

    func testForeignErrorGetsUnknownCodeAndNotRetryable() throws {
        let foreign = NSError(domain: "NSURLErrorDomain", code: -1001, userInfo: [NSLocalizedDescriptionKey: "timed out"])
        let payload = try encodedError(foreign)
        XCTAssertEqual(payload["code"] as? String, "unknown_error")
        let step = try XCTUnwrap(payload["next_step"] as? [String: Any])
        XCTAssertEqual(step["retryable"] as? Bool, false)
    }

    /// A misspelled or mistyped safety key must stop the call, not be dropped
    /// (the write would otherwise run for real). `/usr/bin/false` stands in
    /// for pippin so a call that slipped through would fail differently.
    func testToolsCallRejectsUnknownAndMistypedArguments() async throws {
        let cases = [
            (#"{"messageId":"a||b||1","read":true,"dry_run":true}"#, "unexpected_argument"),
            (#"{"messageId":"a||b||1","read":true,"dryRun":"true"}"#, "wrong_type"),
        ]
        for (arguments, expectedCode) in cases {
            let json = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"mail_mark","arguments":"# + arguments + "}}"
            let request = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(json.utf8))
            let response = await MCPDispatcher.handle(request, pippinPath: "/usr/bin/false")
            let encoded = try JSONEncoder().encode(XCTUnwrap(response))
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            let result = try XCTUnwrap(root["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, true)
            let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let error = try XCTUnwrap(envelope["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, expectedCode, arguments)
        }
    }

    func testTimeoutEncodesRetryableWithDelay() throws {
        let payload = try encodedError(MailBridgeError.timeout)
        let step = try XCTUnwrap(payload["next_step"] as? [String: Any])
        XCTAssertEqual(step["retryable"] as? Bool, true)
        XCTAssertEqual(step["retry_after_seconds"] as? Int, 5)
    }

    // MARK: - Dispatcher

    func testBuildArgsErrorReturnsEnvelopeWithIsError() async throws {
        let json = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"reminders_create","arguments":{}}}"#
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(json.utf8))
        let response = await MCPDispatcher.handle(request, pippinPath: "/bin/echo")
        let encoded = try JSONEncoder().encode(XCTUnwrap(response))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(root["error"], "argument errors are tool-level, not JSON-RPC errors")

        let result = try XCTUnwrap(root["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)

        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(envelope["v"] as? Int, AGENT_SCHEMA_VERSION)
        XCTAssertEqual(envelope["status"] as? String, "error")
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "missing_required")
        let step = try XCTUnwrap(error["next_step"] as? [String: Any])
        XCTAssertEqual(step["retryable"] as? Bool, false)
    }

    func testRunChildReportsTimeout() {
        XCTAssertThrowsError(
            try MCPServerRuntime.runChild(argv: ["10"], pippinPath: "/bin/sleep", timeoutSeconds: 1)
        ) { error in
            guard case MCPServerRuntimeError.childTimedOut(seconds: 1) = error else {
                return XCTFail("expected childTimedOut(1), got \(error)")
            }
        }
    }

    func testRunChildReportsCrashNotTimeout() {
        XCTAssertThrowsError(
            try MCPServerRuntime.runChild(argv: ["-c", "kill -SEGV $$"], pippinPath: "/bin/sh", timeoutSeconds: 30)
        ) { error in
            guard case let MCPServerRuntimeError.childCrashed(signal) = error else {
                return XCTFail("expected childCrashed, got \(error)")
            }
            XCTAssertEqual(signal, SIGSEGV)
            XCTAssertEqual(agentErrorCode(for: error), "child_crashed")
            XCTAssertEqual((error as? RemediableError)?.nextStep.retryable, false)
        }
    }

    func testMessagesSendTimeoutIsOutcomeUnknown() {
        XCTAssertThrowsError(
            try MessagesSender.send(to: "+15551234567", body: "hi", runner: { _, _ in throw ScriptRunnerError.timeout })
        ) { error in
            guard case MessagesSendError.timeout = error else {
                return XCTFail("expected MessagesSendError.timeout, got \(error)")
            }
            XCTAssertEqual(agentErrorCode(for: error), "send_outcome_unknown")
            XCTAssertEqual((error as? RemediableError)?.nextStep.retryable, false)
        }
    }

    // MARK: - Rate limiting

    private func retryAfter(_ header: String?) throws -> Int? {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: XCTUnwrap(URL(string: "http://localhost")), statusCode: 429, httpVersion: nil,
            headerFields: header.map { ["Retry-After": $0] }
        ))
        return parseRetryAfter(response)
    }

    func testParseRetryAfter() throws {
        XCTAssertEqual(try retryAfter("42"), 42)
        XCTAssertNil(try retryAfter(nil))
        XCTAssertNil(try retryAfter("-1"))
        XCTAssertNil(try retryAfter("Wed, 21 Oct 2026 07:28:00 GMT"), "HTTP-date form is not parsed")
    }

    func test429MapsToRateLimited() {
        let error = OpenAIProvider.errorForHTTPStatus(429, data: Data(), model: "m", baseURL: "http://x", retryAfter: 12)
        guard case .rateLimited(retryAfterSeconds: 12, _) = error else {
            return XCTFail("expected rateLimited(12), got \(error)")
        }
        XCTAssertEqual(error.agentCode, "rate_limited")
        XCTAssertEqual(PippinExitCode.classify(error.agentCode), 7)
        XCTAssertEqual(error.nextStep, NextStep(retryable: true, retryAfterSeconds: 12))
    }

    func test429WithoutHeaderDefaultsDelay() {
        let error = OpenAIProvider.errorForHTTPStatus(429, data: Data(), model: "m", baseURL: "http://x")
        XCTAssertEqual(error.nextStep, NextStep(retryable: true, retryAfterSeconds: 30))
    }
}
