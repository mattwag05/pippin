@testable import PippinLib
import XCTest

final class MailModelsTests: XCTestCase {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    // MARK: - MailMessage encoding

    func testMailMessageAllFields() throws {
        let msg = MailMessage(
            id: "acct||INBOX||42",
            account: "Work",
            mailbox: "INBOX",
            subject: "Hello",
            from: "sender@example.com",
            to: ["a@example.com", "b@example.com"],
            date: "2024-06-15T10:00:00Z",
            read: false,
            body: "Message body"
        )
        let data = try encoder.encode(msg)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["id"] as? String, "acct||INBOX||42")
        XCTAssertEqual(json["account"] as? String, "Work")
        XCTAssertEqual(json["mailbox"] as? String, "INBOX")
        XCTAssertEqual(json["subject"] as? String, "Hello")
        XCTAssertEqual(json["from"] as? String, "sender@example.com")
        XCTAssertEqual(json["to"] as? [String], ["a@example.com", "b@example.com"])
        XCTAssertEqual(json["date"] as? String, "2024-06-15T10:00:00Z")
        XCTAssertEqual(json["read"] as? Bool, false)
        XCTAssertEqual(json["body"] as? String, "Message body")
    }

    func testMailMessageBodyNull() throws {
        let msg = MailMessage(
            id: "acct||INBOX||1",
            account: "Personal",
            mailbox: "INBOX",
            subject: "Test",
            from: "x@x.com",
            to: ["y@y.com"],
            date: "2024-01-01T00:00:00Z",
            read: true,
            body: nil
        )
        let data = try encoder.encode(msg)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        // body key must be present with null value (NSNull in JSONSerialization)
        XCTAssertTrue(json.keys.contains("body"), "body key must be present even when nil")
        XCTAssertTrue(json["body"] is NSNull, "body must serialize as JSON null")
    }

    // MARK: - Compound ID format

    func testCompoundIdSplitting() {
        let id = "MyAccount||Sent||12345"
        let parts = id.components(separatedBy: "||")
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0], "MyAccount")
        XCTAssertEqual(parts[1], "Sent")
        XCTAssertEqual(parts[2], "12345")
    }

    func testCompoundIdWithSpecialCharsInMailbox() {
        // Mailboxes can have slashes in their names (e.g. "Archive/2024")
        let id = "Work||Archive/2024||99"
        let parts = id.components(separatedBy: "||")
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[1], "Archive/2024")
    }

    // MARK: - MailActionResult encoding

    func testMailActionResultEncoding() throws {
        let result = MailActionResult(
            success: true,
            action: "mark_read",
            details: ["account": "Work", "mailbox": "INBOX", "messageId": "42"]
        )
        let data = try encoder.encode(result)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["success"] as? Bool, true)
        XCTAssertEqual(json["action"] as? String, "mark_read")
        let details = json["details"] as? [String: String]
        XCTAssertEqual(details?["account"], "Work")
    }

    func testMailActionResultFailure() throws {
        let result = MailActionResult(
            success: false,
            action: "send",
            details: ["error": "SMTP authentication failed"]
        )
        let data = try encoder.encode(result)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["success"] as? Bool, false)
    }

    // MARK: - MailAccount encoding

    func testMailAccountEncoding() throws {
        let account = MailAccount(name: "Work", email: "work@example.com")
        let data = try encoder.encode(account)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "Work")
        XCTAssertEqual(json["email"] as? String, "work@example.com")
    }
}
