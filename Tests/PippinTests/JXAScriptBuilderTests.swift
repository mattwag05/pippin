@testable import PippinLib
import XCTest

/// Tests for MailBridge script builder methods.
///
/// These verify that each builder correctly interpolates parameters into the
/// JXA source strings without requiring osascript execution.
final class JXAScriptBuilderTests: XCTestCase {
    // MARK: - buildListScript

    func testListScriptDefaultsToINBOX() {
        let script = MailBridge.buildListScript(account: nil, mailbox: "INBOX", unread: false, limit: 20)
        XCTAssertTrue(script.contains("mbFilter = 'INBOX'"))
    }

    func testListScriptInterpolatesLimit() {
        let script = MailBridge.buildListScript(account: nil, mailbox: "INBOX", unread: false, limit: 42)
        XCTAssertTrue(script.contains("var limit = 42;"))
    }

    func testListScriptUnreadFalse() {
        let script = MailBridge.buildListScript(account: nil, mailbox: "INBOX", unread: false, limit: 10)
        XCTAssertTrue(script.contains("var unreadOnly = false;"))
    }

    func testListScriptUnreadTrue() {
        let script = MailBridge.buildListScript(account: nil, mailbox: "INBOX", unread: true, limit: 10)
        XCTAssertTrue(script.contains("var unreadOnly = true;"))
    }

    func testListScriptAccountFilterNilIsNull() {
        let script = MailBridge.buildListScript(account: nil, mailbox: "INBOX", unread: false, limit: 10)
        XCTAssertTrue(script.contains("var acctFilter = null;"))
    }

    func testListScriptAccountFilterInterpolated() {
        let script = MailBridge.buildListScript(account: "Work", mailbox: "INBOX", unread: false, limit: 10)
        XCTAssertTrue(script.contains("var acctFilter = 'Work';"))
    }

    func testListScriptEscapesSpecialCharsInMailbox() {
        let script = MailBridge.buildListScript(account: nil, mailbox: "Archive/2025", unread: false, limit: 5)
        // Slash is not a special JXA char — must pass through unchanged
        XCTAssertTrue(script.contains("mbFilter = 'Archive/2025'"))
    }

    func testListScriptEscapesQuoteInAccount() {
        let script = MailBridge.buildListScript(account: "O'Brien", mailbox: "INBOX", unread: false, limit: 5)
        XCTAssertTrue(script.contains("acctFilter = 'O\\'Brien'"))
    }

    // MARK: - buildSearchScript

    func testSearchScriptInterpolatesQuery() {
        let script = MailBridge.buildSearchScript(query: "invoice", account: nil, limit: 10)
        XCTAssertTrue(script.contains("'invoice'"))
    }

    func testSearchScriptAccountNilIsNull() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10)
        XCTAssertTrue(script.contains("var acctFilter = null;"))
    }

    func testSearchScriptAccountFilterInterpolated() {
        let script = MailBridge.buildSearchScript(query: "test", account: "Personal", limit: 10)
        XCTAssertTrue(script.contains("var acctFilter = 'Personal';"))
    }

    func testSearchScriptClampsLimitAbove500() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 9999)
        XCTAssertTrue(script.contains("var limit = 500;"))
    }

    func testSearchScriptClampsLimitBelow1() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 0)
        XCTAssertTrue(script.contains("var limit = 1;"))
    }

    func testSearchScriptEscapesNewlineInQuery() {
        let script = MailBridge.buildSearchScript(query: "line1\nline2", account: nil, limit: 5)
        XCTAssertTrue(script.contains("line1\\nline2"))
        XCTAssertFalse(script.contains("line1\nline2"))
    }

    // MARK: - buildAccountsScript

    func testAccountsScriptContainsMailAccountsCall() {
        let script = MailBridge.buildAccountsScript()
        XCTAssertTrue(script.contains("mail.accounts()"))
    }

    func testAccountsScriptOutputsJSONStringify() {
        let script = MailBridge.buildAccountsScript()
        XCTAssertTrue(script.contains("JSON.stringify(results)"))
    }

    // MARK: - buildReadScript

    func testReadScriptInterpolatesAccount() {
        let script = MailBridge.buildReadScript(account: "Work", mailbox: "INBOX", messageId: "42")
        XCTAssertTrue(script.contains("'Work'"))
    }

    func testReadScriptInterpolatesMailbox() {
        let script = MailBridge.buildReadScript(account: "Work", mailbox: "Sent", messageId: "42")
        XCTAssertTrue(script.contains("'Sent'"))
    }

    func testReadScriptInterpolatesMessageId() {
        let script = MailBridge.buildReadScript(account: "Work", mailbox: "INBOX", messageId: "99")
        XCTAssertTrue(script.contains("99"))
    }

    func testReadScriptIncludesBodyField() {
        let script = MailBridge.buildReadScript(account: "Work", mailbox: "INBOX", messageId: "1")
        XCTAssertTrue(script.contains("body: msg.content()"))
    }

    // MARK: - buildMarkScript

    func testMarkScriptReadTrue() {
        let script = MailBridge.buildMarkScript(account: "Work", mailbox: "INBOX", messageId: "5", read: true, dryRun: false)
        XCTAssertTrue(script.contains("var targetRead = true;"))
    }

    func testMarkScriptReadFalse() {
        let script = MailBridge.buildMarkScript(account: "Work", mailbox: "INBOX", messageId: "5", read: false, dryRun: false)
        XCTAssertTrue(script.contains("var targetRead = false;"))
    }

    func testMarkScriptDryRunTrue() {
        let script = MailBridge.buildMarkScript(account: "Work", mailbox: "INBOX", messageId: "5", read: true, dryRun: true)
        XCTAssertTrue(script.contains("var isDryRun = true;"))
    }

    func testMarkScriptDryRunFalse() {
        let script = MailBridge.buildMarkScript(account: "Work", mailbox: "INBOX", messageId: "5", read: true, dryRun: false)
        XCTAssertTrue(script.contains("var isDryRun = false;"))
    }

    // MARK: - buildMoveScript

    func testMoveScriptInterpolatesTargetMailbox() {
        let script = MailBridge.buildMoveScript(account: "Work", mailbox: "INBOX", messageId: "7", toMailbox: "Archive", dryRun: false)
        XCTAssertTrue(script.contains("'Archive'"))
    }

    func testMoveScriptDryRun() {
        let script = MailBridge.buildMoveScript(account: "Work", mailbox: "INBOX", messageId: "7", toMailbox: "Archive", dryRun: true)
        XCTAssertTrue(script.contains("var isDryRun = true;"))
    }

    func testMoveScriptEscapesBackslashInMailbox() {
        let script = MailBridge.buildMoveScript(account: "Work", mailbox: "INBOX", messageId: "1", toMailbox: "Folder\\Sub", dryRun: false)
        XCTAssertTrue(script.contains("Folder\\\\Sub"))
    }

    // MARK: - buildSendScript

    func testSendScriptInterpolatesToAndSubject() {
        let script = MailBridge.buildSendScript(to: "a@b.com", subject: "Hello", body: "Body", cc: nil, from: nil, attachmentPath: nil, dryRun: false)
        XCTAssertTrue(script.contains("'a@b.com'"))
        XCTAssertTrue(script.contains("'Hello'"))
    }

    func testSendScriptCcNilIsNull() {
        let script = MailBridge.buildSendScript(to: "a@b.com", subject: "Hi", body: "Body", cc: nil, from: nil, attachmentPath: nil, dryRun: false)
        XCTAssertTrue(script.contains("var ccAddr = null;"))
    }

    func testSendScriptCcInterpolated() {
        let script = MailBridge.buildSendScript(to: "a@b.com", subject: "Hi", body: "Body", cc: "cc@b.com", from: nil, attachmentPath: nil, dryRun: false)
        XCTAssertTrue(script.contains("var ccAddr = 'cc@b.com';"))
    }

    func testSendScriptAttachmentNilIsNull() {
        let script = MailBridge.buildSendScript(to: "a@b.com", subject: "Hi", body: "Body", cc: nil, from: nil, attachmentPath: nil, dryRun: false)
        XCTAssertTrue(script.contains("var attachPath = null;"))
    }

    func testSendScriptAttachmentInterpolated() {
        let script = MailBridge.buildSendScript(to: "a@b.com", subject: "Hi", body: "Body", cc: nil, from: nil, attachmentPath: "/tmp/file.pdf", dryRun: false)
        XCTAssertTrue(script.contains("var attachPath = '/tmp/file.pdf';"))
    }

    func testSendScriptDryRunTrue() {
        let script = MailBridge.buildSendScript(to: "a@b.com", subject: "Hi", body: "Body", cc: nil, from: nil, attachmentPath: nil, dryRun: true)
        XCTAssertTrue(script.contains("var isDryRun = true;"))
    }

    func testSendScriptEscapesNewlineInBody() {
        let script = MailBridge.buildSendScript(to: "a@b.com", subject: "Hi", body: "Line1\nLine2", cc: nil, from: nil, attachmentPath: nil, dryRun: false)
        XCTAssertTrue(script.contains("Line1\\nLine2"))
        XCTAssertFalse(script.contains("Line1\nLine2"))
    }

    func testSendScriptFromNilIsNull() {
        let script = MailBridge.buildSendScript(to: "a@b.com", subject: "Hi", body: "Body", cc: nil, from: nil, attachmentPath: nil, dryRun: false)
        XCTAssertTrue(script.contains("var fromAcct = null;"))
    }

    func testSendScriptFromInterpolated() {
        let script = MailBridge.buildSendScript(to: "a@b.com", subject: "Hi", body: "Body", cc: nil, from: "Personal", attachmentPath: nil, dryRun: false)
        XCTAssertTrue(script.contains("var fromAcct = 'Personal';"))
    }
}
