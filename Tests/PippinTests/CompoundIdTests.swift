import XCTest
@testable import PippinLib

final class CompoundIdTests: XCTestCase {

    // MARK: - Valid IDs

    func testValidIdParsed() throws {
        let (account, mailbox, msgId) = try MailBridge.parseCompoundId("MyAccount||INBOX||42")
        XCTAssertEqual(account, "MyAccount")
        XCTAssertEqual(mailbox, "INBOX")
        XCTAssertEqual(msgId, "42")
    }

    func testLargeMessageId() throws {
        let (_, _, msgId) = try MailBridge.parseCompoundId("Work||Sent||9999999")
        XCTAssertEqual(msgId, "9999999")
    }

    // MARK: - Malformed IDs

    func testMissingThirdPartThrows() {
        XCTAssertThrowsError(try MailBridge.parseCompoundId("Account||INBOX")) { error in
            guard case MailBridgeError.invalidMessageId = error else {
                XCTFail("Expected invalidMessageId, got \(error)"); return
            }
        }
    }

    func testTooManyPartsThrows() {
        XCTAssertThrowsError(try MailBridge.parseCompoundId("Account||INBOX||42||extra")) { error in
            guard case MailBridgeError.invalidMessageId = error else {
                XCTFail("Expected invalidMessageId, got \(error)"); return
            }
        }
    }

    func testNonNumericMessageIdThrows() {
        XCTAssertThrowsError(try MailBridge.parseCompoundId("Account||INBOX||abc")) { error in
            guard case MailBridgeError.invalidMessageId = error else {
                XCTFail("Expected invalidMessageId, got \(error)"); return
            }
        }
    }

    func testEmptyMessageIdThrows() {
        XCTAssertThrowsError(try MailBridge.parseCompoundId("Account||INBOX||")) { error in
            guard case MailBridgeError.invalidMessageId = error else {
                XCTFail("Expected invalidMessageId, got \(error)"); return
            }
        }
    }

    func testEmptyStringThrows() {
        XCTAssertThrowsError(try MailBridge.parseCompoundId("")) { error in
            guard case MailBridgeError.invalidMessageId = error else {
                XCTFail("Expected invalidMessageId, got \(error)"); return
            }
        }
    }

    // MARK: - Single pipe in account/mailbox name

    func testSinglePipeInAccountNameIsAllowed() throws {
        // "My|Account||INBOX||99" splits on "||" → ["My|Account", "INBOX", "99"]
        let (account, mailbox, msgId) = try MailBridge.parseCompoundId("My|Account||INBOX||99")
        XCTAssertEqual(account, "My|Account")
        XCTAssertEqual(mailbox, "INBOX")
        XCTAssertEqual(msgId, "99")
    }

    func testSinglePipeInMailboxNameIsAllowed() throws {
        let (account, mailbox, msgId) = try MailBridge.parseCompoundId("Work||Archive|2024||100")
        XCTAssertEqual(account, "Work")
        XCTAssertEqual(mailbox, "Archive|2024")
        XCTAssertEqual(msgId, "100")
    }
}
