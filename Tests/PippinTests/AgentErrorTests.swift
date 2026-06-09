import ArgumentParser
@testable import PippinLib
import XCTest

final class AgentErrorTests: XCTestCase {
    // MARK: - AgentError.from() conversions

    func testAgentErrorFromMailBridgeError() {
        let err = MailBridgeError.timeout
        let agentError = AgentError.from(err)
        XCTAssertEqual(agentError.error.code, "timeout")
        XCTAssertFalse(agentError.error.message.isEmpty)
    }

    func testAgentErrorFromScriptFailed() {
        let err = MailBridgeError.scriptFailed("osascript error -1743")
        let agentError = AgentError.from(err)
        XCTAssertEqual(agentError.error.code, "script_failed")
        XCTAssertFalse(agentError.error.message.isEmpty)
    }

    func testAgentErrorFromAccessDenied() {
        let err = CalendarBridgeError.accessDenied
        let agentError = AgentError.from(err)
        XCTAssertEqual(agentError.error.code, "access_denied")
        XCTAssertTrue(agentError.error.message.contains("Calendar access denied"))
    }

    func testAgentErrorFromGenericError() {
        struct SimpleError: Error, LocalizedError {
            var errorDescription: String? {
                "Something went wrong"
            }
        }
        let agentError = AgentError.from(SimpleError())
        XCTAssertEqual(agentError.error.message, "Something went wrong")
        XCTAssertFalse(agentError.error.code.isEmpty)
    }

    func testAgentErrorCodeStripsAssociatedValues() {
        let err = MailBridgeError.scriptFailed("some long stderr content that should not appear in code")
        let agentError = AgentError.from(err)
        XCTAssertEqual(agentError.error.code, "script_failed")
        XCTAssertFalse(agentError.error.code.contains("some long"), "Associated value must not leak into code")
    }

    // MARK: - ArgumentParser error message recovery (pippin-kzi)

    /// Regression for pippin-kzi: ArgumentParser wraps a thrown `ValidationError`
    /// in a non-public error whose `localizedDescription` is the opaque
    /// "(ArgumentParser.ValidationError error 1.)". The agent envelope must
    /// surface the real validation text instead, via the injected
    /// `argumentParserMessage` extractor (`ParsableCommand.message(for:)`).
    func testAgentErrorRecoversArgumentParserValidationMessage() {
        let previous = AgentError.argumentParserMessage
        defer { AgentError.argumentParserMessage = previous }
        // Stand in for `Pippin.message(for:)`, which the executable injects.
        AgentError.argumentParserMessage = { _ in "--start must be in YYYY-MM-DD or ISO 8601 format." }

        let err = ValidationError("--start must be in YYYY-MM-DD or ISO 8601 format.")
        let agentError = AgentError.from(err)
        XCTAssertTrue(
            agentError.error.message.contains("YYYY-MM-DD"),
            "ArgumentParser validation text must survive into the agent envelope, got: \(agentError.error.message)"
        )
        XCTAssertFalse(
            agentError.error.message.contains("couldn’t be completed"),
            "Opaque localizedDescription must not be used for ArgumentParser errors"
        )
    }

    /// Without the extractor (or for non-ArgumentParser errors) the existing
    /// LocalizedError path must remain unchanged.
    func testAgentErrorNonArgumentParserUnaffectedByExtractor() {
        let previous = AgentError.argumentParserMessage
        defer { AgentError.argumentParserMessage = previous }
        AgentError.argumentParserMessage = { _ in "SHOULD NOT BE USED" }

        let agentError = AgentError.from(CalendarBridgeError.accessDenied)
        XCTAssertTrue(agentError.error.message.contains("Calendar access denied"))
        XCTAssertFalse(agentError.error.message.contains("SHOULD NOT BE USED"))
    }

    // MARK: - JSON shape

    func testAgentErrorJSONShape() throws {
        let agentError = AgentError(code: "not_found", message: "Item not found")
        let data = try JSONEncoder().encode(agentError)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let errorDict = try XCTUnwrap(dict["error"] as? [String: Any])
        XCTAssertEqual(errorDict["code"] as? String, "not_found")
        XCTAssertEqual(errorDict["message"] as? String, "Item not found")
        XCTAssertNil(dict["code"], "Top-level should not have 'code' key")
    }

    // MARK: - Foreign / non-enum error codes (pippin-2tg)

    //
    // agentErrorCode camelToSnakeCases String(describing: error). For a bridged
    // NSError/URLError/CocoaError that description is a full sentence, so the
    // derived code was junk like `error _domain=_n_s_u_r_l_error_domain
    // _code=-1001 "` — a per-instance garbage string in the `error.code`
    // contract field. Hardening: foreign descriptions collapse to a clean,
    // stable `unknown_error`; typed PippinLib enum codes are unchanged.

    private func isCleanCode(_ code: String) -> Bool {
        guard let first = code.first, first.isLetter || first == "_" else { return false }
        return code.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    func testForeignNSErrorProducesCleanCode() {
        let err = NSError(
            domain: "NSCocoaErrorDomain",
            code: 260,
            userInfo: [NSLocalizedDescriptionKey: "The file doesn’t exist."]
        )
        let code = agentErrorCode(for: err)
        XCTAssertTrue(isCleanCode(code), "Foreign NSError must yield a clean identifier code, got: \(code)")
    }

    func testForeignURLErrorProducesCleanStableCode() {
        let a = agentErrorCode(for: URLError(.timedOut))
        let b = agentErrorCode(for: URLError(.cannotFindHost))
        XCTAssertTrue(isCleanCode(a), "got: \(a)")
        XCTAssertEqual(a, b, "Distinct foreign errors should collapse to one stable generic code")
    }

    func testForeignErrorAgentEnvelopeCodeIsCleanButMessageKept() {
        let err = NSError(
            domain: "X",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "boom (paren) =eq \"quote\""]
        )
        let agentError = AgentError.from(err)
        XCTAssertTrue(isCleanCode(agentError.error.code), "envelope code must be clean, got: \(agentError.error.code)")
        XCTAssertTrue(agentError.error.message.contains("boom"), "human detail must survive in message")
    }

    /// Typed PippinLib enum codes must be UNCHANGED by the foreign-error
    /// hardening — these feed exit-code classification and MCP branching.
    func testTypedEnumCodesUnchangedByHardening() {
        XCTAssertEqual(agentErrorCode(for: RemindersBridgeError.accessDenied), "access_denied")
        XCTAssertEqual(agentErrorCode(for: MailBridgeError.scriptFailed("x")), "script_failed")
        XCTAssertEqual(agentErrorCode(for: AudioBridgeError.timeout), "timeout")
        XCTAssertEqual(agentErrorCode(for: AudioBridgeError.notAvailable), "not_available")
    }

    // MARK: - camelToSnakeCase (via agentErrorCode)

    func testCamelToSnakeCaseViaErrorCode() {
        // notAvailable → not_available
        let notAvailable = AudioBridgeError.notAvailable
        XCTAssertEqual(agentErrorCode(for: notAvailable), "not_available")

        // noDefaultCalendar — test via CalendarBridgeError.accessDenied as a simple control
        let accessDenied = CalendarBridgeError.accessDenied
        XCTAssertEqual(agentErrorCode(for: accessDenied), "access_denied")

        // timeout stays lowercase
        let timeout = AudioBridgeError.timeout
        XCTAssertEqual(agentErrorCode(for: timeout), "timeout")
    }
}
