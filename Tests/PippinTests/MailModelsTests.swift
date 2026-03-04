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

    // MARK: - Attachment encoding

    func testAttachmentEncoding() throws {
        let att = Attachment(name: "report.pdf", mimeType: "application/pdf", size: 102_400)
        let data = try encoder.encode(att)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "report.pdf")
        XCTAssertEqual(json["mimeType"] as? String, "application/pdf")
        XCTAssertEqual(json["size"] as? Int, 102_400)
    }

    func testAttachmentRoundTrip() throws {
        let att = Attachment(name: "photo.jpg", mimeType: "image/jpeg", size: 512_000)
        let data = try encoder.encode(att)
        let decoded = try decode(Attachment.self, from: data)
        XCTAssertEqual(decoded.name, att.name)
        XCTAssertEqual(decoded.mimeType, att.mimeType)
        XCTAssertEqual(decoded.size, att.size)
    }

    // MARK: - Mailbox encoding

    func testMailboxEncoding() throws {
        let mb = Mailbox(name: "INBOX", account: "Work", messageCount: 150, unreadCount: 5)
        let data = try encoder.encode(mb)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "INBOX")
        XCTAssertEqual(json["account"] as? String, "Work")
        XCTAssertEqual(json["messageCount"] as? Int, 150)
        XCTAssertEqual(json["unreadCount"] as? Int, 5)
    }

    // MARK: - MailMessage new optional fields

    func testMailMessageNewFieldsAbsentWhenNil() throws {
        let msg = MailMessage(
            id: "a||b||1",
            account: "Work",
            mailbox: "INBOX",
            subject: "Test",
            from: "x@x.com",
            to: [],
            date: "2024-01-01T00:00:00Z",
            read: false
        )
        let data = try encoder.encode(msg)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // New optional fields should be absent (encodeIfPresent with nil omits the key)
        XCTAssertFalse(json.keys.contains("size"), "size should be absent when nil")
        XCTAssertFalse(json.keys.contains("hasAttachment"), "hasAttachment should be absent when nil")
        XCTAssertFalse(json.keys.contains("htmlBody"), "htmlBody should be absent when nil")
        XCTAssertFalse(json.keys.contains("headers"), "headers should be absent when nil")
        XCTAssertFalse(json.keys.contains("attachments"), "attachments should be absent when nil")
    }

    func testMailMessageWithSizeAndHasAttachment() throws {
        let msg = MailMessage(
            id: "a||b||2",
            account: "Work",
            mailbox: "INBOX",
            subject: "Has attachment",
            from: "x@x.com",
            to: [],
            date: "2024-01-01T00:00:00Z",
            read: true,
            size: 50000,
            hasAttachment: true
        )
        let data = try encoder.encode(msg)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["size"] as? Int, 50000)
        XCTAssertEqual(json["hasAttachment"] as? Bool, true)
        // Detail fields still absent
        XCTAssertFalse(json.keys.contains("htmlBody"))
        XCTAssertFalse(json.keys.contains("headers"))
        XCTAssertFalse(json.keys.contains("attachments"))
    }

    func testMailMessageWithFullDetail() throws {
        let att = Attachment(name: "file.pdf", mimeType: "application/pdf", size: 1024)
        let msg = MailMessage(
            id: "a||b||3",
            account: "Work",
            mailbox: "INBOX",
            subject: "Detailed",
            from: "x@x.com",
            to: ["y@y.com"],
            date: "2024-01-01T00:00:00Z",
            read: false,
            body: "plain text",
            size: 2048,
            hasAttachment: true,
            htmlBody: "<p>html</p>",
            headers: ["From": "x@x.com", "Subject": "Detailed"],
            attachments: [att]
        )
        let data = try encoder.encode(msg)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["size"] as? Int, 2048)
        XCTAssertEqual(json["hasAttachment"] as? Bool, true)
        XCTAssertEqual(json["htmlBody"] as? String, "<p>html</p>")
        let headers = json["headers"] as? [String: String]
        XCTAssertEqual(headers?["Subject"], "Detailed")
        let attachments = json["attachments"] as? [[String: Any]]
        XCTAssertEqual(attachments?.count, 1)
        XCTAssertEqual(attachments?.first?["name"] as? String, "file.pdf")
    }

    func testMailMessageDecodesWithoutNewFields() throws {
        // JSON without new fields should decode cleanly (all new fields = nil)
        let jsonStr = """
        {
            "id": "a||b||5",
            "account": "Work",
            "mailbox": "INBOX",
            "subject": "Old format",
            "from": "x@x.com",
            "to": [],
            "date": "2024-01-01T00:00:00Z",
            "read": false,
            "body": null
        }
        """
        let data = try XCTUnwrap(jsonStr.data(using: .utf8))
        let msg = try decode(MailMessage.self, from: data)
        XCTAssertNil(msg.size)
        XCTAssertNil(msg.hasAttachment)
        XCTAssertNil(msg.htmlBody)
        XCTAssertNil(msg.headers)
        XCTAssertNil(msg.attachments)
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
