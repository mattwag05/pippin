@testable import PippinLib
import XCTest

final class DecoderTests: XCTestCase {
    // MARK: - Generic decode<T>

    func testDecodeMessagesFromValidJSON() throws {
        let json = """
        [{"id":"a||INBOX||1","account":"a","mailbox":"INBOX","subject":"Hello","from":"x@x.com","to":["y@y.com"],"date":"2024-01-01T00:00:00Z","read":false,"body":null}]
        """
        let messages = try MailBridge.decode([MailMessage].self, from: json)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].subject, "Hello")
        XCTAssertEqual(messages[0].id, "a||INBOX||1")
        XCTAssertNil(messages[0].body)
    }

    func testDecodeAccountsFromValidJSON() throws {
        let json = """
        [{"name":"Work","email":"work@example.com"}]
        """
        let accounts = try MailBridge.decode([MailAccount].self, from: json)
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts[0].name, "Work")
        XCTAssertEqual(accounts[0].email, "work@example.com")
    }

    func testDecodeActionResultFromValidJSON() throws {
        let json = """
        {"success":true,"action":"mark","details":{"messageId":"42"}}
        """
        let result = try MailBridge.decode(MailActionResult.self, from: json)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.action, "mark")
        XCTAssertEqual(result.details["messageId"], "42")
    }

    func testDecodeEmptyStringThrows() {
        XCTAssertThrowsError(try MailBridge.decode([MailMessage].self, from: "")) { error in
            guard case let MailBridgeError.decodingFailed(msg) = error else {
                XCTFail("Expected decodingFailed, got \(error)"); return
            }
            XCTAssertTrue(msg.contains("empty output"), "Expected 'empty output' in: \(msg)")
        }
    }

    func testDecodeMalformedJSONThrows() {
        XCTAssertThrowsError(try MailBridge.decode([MailMessage].self, from: "{not valid")) { error in
            guard case MailBridgeError.decodingFailed = error else {
                XCTFail("Expected decodingFailed, got \(error)"); return
            }
        }
    }

    func testDecodeWrongTypeThrows() {
        // Array of numbers, not MailMessage objects
        XCTAssertThrowsError(try MailBridge.decode([MailMessage].self, from: "[1, 2, 3]")) { error in
            guard case MailBridgeError.decodingFailed = error else {
                XCTFail("Expected decodingFailed, got \(error)"); return
            }
        }
    }

    // MARK: - MailBridgeError descriptions

    func testScriptFailedDescription() {
        let error = MailBridgeError.scriptFailed("osascript exited with code 1")
        XCTAssertEqual(error.errorDescription, "Mail automation script failed: osascript exited with code 1")
        XCTAssertEqual(error.debugDetail, "osascript exited with code 1")
    }

    func testTimeoutDescription() {
        let error = MailBridgeError.timeout
        XCTAssertEqual(error.errorDescription, "Mail automation timed out. Try narrowing with --account, --mailbox, or --after.")
        XCTAssertNil(error.debugDetail)
    }

    func testDecodingFailedDescription() {
        let error = MailBridgeError.decodingFailed("unexpected null")
        XCTAssertEqual(error.errorDescription, "Failed to decode Mail response")
        XCTAssertEqual(error.debugDetail, "unexpected null")
    }

    func testInvalidMessageIdDescription() {
        let error = MailBridgeError.invalidMessageId("bad||id")
        XCTAssertEqual(error.errorDescription, "Invalid message id: bad||id")
        XCTAssertNil(error.debugDetail)
    }

    func testInvalidMailboxDescription() {
        let error = MailBridgeError.invalidMailbox("bad name")
        XCTAssertEqual(error.errorDescription, "Invalid mailbox name: bad name")
        XCTAssertNil(error.debugDetail)
    }
}
