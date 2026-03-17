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
