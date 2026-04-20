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

    func testSearchScriptMbFilterNilIsNull() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, mailbox: nil, limit: 10)
        XCTAssertTrue(script.contains("var mbFilter = null;"))
    }

    func testSearchScriptMbFilterInterpolated() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, mailbox: "INBOX", limit: 10)
        XCTAssertTrue(script.contains("var mbFilter = 'INBOX';"))
    }

    func testSearchScriptMbFilterEscapesQuote() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, mailbox: "O'Brien", limit: 10)
        XCTAssertTrue(script.contains("mbFilter = 'O\\'Brien'"))
    }

    func testSearchScriptSearchBodyDefaultFalse() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10)
        XCTAssertTrue(script.contains("var searchBody = false;"))
    }

    func testSearchScriptSearchBodyTrue() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, searchBody: true, limit: 10)
        XCTAssertTrue(script.contains("var searchBody = true;"))
    }

    func testSearchScriptPerMailboxLimitIs500() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10)
        XCTAssertTrue(script.contains("var perMailboxLimit = 500;"))
    }

    func testSearchScriptFlattensNestedMailboxes() {
        // When no mailbox filter is set, the script must recurse into sub-mailboxes so Gmail's
        // [Gmail]/All Mail, Sent, Trash are scanned — not just the top-level INBOX + [Gmail] container.
        let script = MailBridge.buildSearchScript(query: "test", account: nil, mailbox: nil, limit: 10)
        XCTAssertTrue(script.contains("function collectAllMailboxes"))
        XCTAssertTrue(script.contains("collectAllMailboxes(acct.mailboxes(), [])"))
    }

    func testSearchScriptDedupesAcrossMailboxes() {
        // Gmail duplicates messages across INBOX and [Gmail]/All Mail — results must dedupe.
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10)
        XCTAssertTrue(script.contains("seenMsgKeys"))
        XCTAssertTrue(script.contains("msg.messageId()"))
    }

    func testSearchScriptSkipsFlattenWhenMailboxFilterSet() {
        // When a mailbox is explicitly requested, resolveMailbox is still used (not the flatten helper).
        let script = MailBridge.buildSearchScript(query: "test", account: nil, mailbox: "INBOX", limit: 10)
        XCTAssertTrue(script.contains("resolveMailbox(acct, mbFilter)"))
    }

    // MARK: - buildListScript (offset/pagination)

    func testListScriptDefaultOffsetZero() {
        let script = MailBridge.buildListScript(account: nil, mailbox: "INBOX", unread: false, limit: 20)
        XCTAssertTrue(script.contains("var offset = 0;"))
    }

    func testListScriptWithOffset() {
        let script = MailBridge.buildListScript(account: nil, mailbox: "INBOX", unread: false, limit: 20, offset: 40)
        XCTAssertTrue(script.contains("var offset = 40;"))
    }

    func testListScriptContainsMessageSize() {
        let script = MailBridge.buildListScript(account: nil, mailbox: "INBOX", unread: false, limit: 10)
        XCTAssertTrue(script.contains("msg.messageSize()"))
    }

    func testListScriptContainsHasAttachment() {
        let script = MailBridge.buildListScript(account: nil, mailbox: "INBOX", unread: false, limit: 10)
        XCTAssertTrue(script.contains("mailAttachments()"))
    }

    // MARK: - buildSearchScript (offset/pagination + metadata)

    func testSearchScriptDefaultOffsetZero() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10)
        XCTAssertTrue(script.contains("var offset = 0;"))
    }

    func testSearchScriptWithOffset() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10, offset: 20)
        XCTAssertTrue(script.contains("var offset = 20;"))
    }

    func testSearchScriptContainsMessageSize() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10)
        XCTAssertTrue(script.contains("msg.messageSize()"))
    }

    func testSearchScriptContainsHasAttachment() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10)
        XCTAssertTrue(script.contains("mailAttachments()"))
    }

    // MARK: - buildMailboxesScript

    func testMailboxesScriptAccountNilIsNull() {
        let script = MailBridge.buildMailboxesScript(account: nil)
        XCTAssertTrue(script.contains("var acctFilter = null;"))
    }

    func testMailboxesScriptAccountFiltered() {
        let script = MailBridge.buildMailboxesScript(account: "Work")
        XCTAssertTrue(script.contains("var acctFilter = 'Work';"))
    }

    func testMailboxesScriptContainsUnreadCount() {
        let script = MailBridge.buildMailboxesScript(account: nil)
        XCTAssertTrue(script.contains("mb.unreadCount()"))
    }

    func testMailboxesScriptOutputsJSONStringify() {
        let script = MailBridge.buildMailboxesScript(account: nil)
        XCTAssertTrue(script.contains("JSON.stringify(results)"))
    }

    func testMailboxesScriptEscapesQuoteInAccount() {
        let script = MailBridge.buildMailboxesScript(account: "O'Brien")
        XCTAssertTrue(script.contains("acctFilter = 'O\\'Brien'"))
    }

    // MARK: - buildReadScript (rich metadata)

    func testReadScriptContainsHtmlContent() {
        let script = MailBridge.buildReadScript(account: "Work", mailbox: "INBOX", messageId: "1")
        XCTAssertTrue(script.contains("msg.htmlContent()"))
    }

    func testReadScriptContainsAllHeaders() {
        let script = MailBridge.buildReadScript(account: "Work", mailbox: "INBOX", messageId: "1")
        XCTAssertTrue(script.contains("msg.allHeaders()"))
    }

    func testReadScriptContainsAttachmentFields() {
        let script = MailBridge.buildReadScript(account: "Work", mailbox: "INBOX", messageId: "1")
        XCTAssertTrue(script.contains("att.name()"))
        XCTAssertTrue(script.contains("att.mimeType()"))
    }

    func testReadScriptContainsMessageSize() {
        let script = MailBridge.buildReadScript(account: "Work", mailbox: "INBOX", messageId: "1")
        XCTAssertTrue(script.contains("msg.messageSize()"))
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
        XCTAssertTrue(script.contains("body: bodyText"))
    }

    func testReadScriptContentBeforeHtmlContent() throws {
        let script = MailBridge.buildReadScript(account: "Work", mailbox: "INBOX", messageId: "1")
        let contentIdx = try XCTUnwrap(script.range(of: "msg.content()")?.lowerBound)
        let htmlIdx = try XCTUnwrap(script.range(of: "msg.htmlContent()")?.lowerBound)
        XCTAssertLessThan(contentIdx, htmlIdx)
    }

    func testReadScriptHtmlContentRetry() {
        let script = MailBridge.buildReadScript(account: "Work", mailbox: "INBOX", messageId: "1")
        let occurrences = script.components(separatedBy: "msg.htmlContent()").count - 1
        XCTAssertEqual(occurrences, 2, "Expected two htmlContent() calls (initial + retry)")
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

    // MARK: - Alias resolution helpers

    func testJsFindMailboxByNameOutput() {
        let js = MailBridge.jsFindMailboxByName()
        XCTAssertTrue(js.contains("function findMailboxByName"))
        XCTAssertTrue(js.contains("mailboxes[i].mailboxes()"))
    }

    func testJsResolveMailboxContainsTrashAliases() {
        let js = MailBridge.jsResolveMailbox()
        XCTAssertTrue(js.contains("acct.trash()"))
        XCTAssertTrue(js.contains("deleted messages"))
        XCTAssertTrue(js.contains("deleted items"))
        XCTAssertTrue(js.contains("'bin'"))
    }

    func testJsResolveMailboxContainsJunkAndSentAndDrafts() {
        let js = MailBridge.jsResolveMailbox()
        XCTAssertTrue(js.contains("acct.junk()"))
        XCTAssertTrue(js.contains("acct.sent()"))
        XCTAssertTrue(js.contains("acct.drafts()"))
    }

    func testJsResolveMailboxFallsBackToFindMailboxByName() {
        let js = MailBridge.jsResolveMailbox()
        XCTAssertTrue(js.contains("findMailboxByName(acct.mailboxes(), name)"))
    }

    // MARK: - buildMoveScript (alias resolution)

    func testMoveScriptContainsResolveMailbox() {
        let script = MailBridge.buildMoveScript(account: "Work", mailbox: "INBOX", messageId: "1", toMailbox: "Trash", dryRun: false)
        XCTAssertTrue(script.contains("resolveMailbox(acct,"))
        XCTAssertTrue(script.contains("acct.trash()"))
    }

    func testMoveScriptContainsFindMailboxByName() {
        let script = MailBridge.buildMoveScript(account: "Work", mailbox: "INBOX", messageId: "1", toMailbox: "Archive", dryRun: false)
        XCTAssertTrue(script.contains("function findMailboxByName"))
    }

    // MARK: - buildListScript (alias resolution)

    func testListScriptContainsResolveMailbox() {
        let script = MailBridge.buildListScript(account: nil, mailbox: "Trash", unread: false, limit: 10)
        XCTAssertTrue(script.contains("resolveMailbox(acct,"))
        XCTAssertTrue(script.contains("function resolveMailbox"))
    }

    func testListScriptUsesResolvedMbName() {
        let script = MailBridge.buildListScript(account: nil, mailbox: "INBOX", unread: false, limit: 10)
        XCTAssertTrue(script.contains("resolvedMbName"))
    }

    // MARK: - buildSearchScript (alias resolution)

    func testSearchScriptContainsResolveMailbox() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, mailbox: "Junk", limit: 10)
        XCTAssertTrue(script.contains("resolveMailbox(acct,"))
        XCTAssertTrue(script.contains("function resolveMailbox"))
    }

    func testSearchScriptBuildsmbListFromResolveMailbox() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, mailbox: "Sent", limit: 10)
        XCTAssertTrue(script.contains("var mbList"))
        XCTAssertTrue(script.contains("resolveMailbox(acct, mbFilter)"))
    }

    // MARK: - buildSendScript

    func testSendScriptInterpolatesToAndSubject() {
        let script = MailBridge.buildSendScript(to: ["a@b.com"], subject: "Hello", body: "Body", dryRun: false)
        XCTAssertTrue(script.contains("'a@b.com'"))
        XCTAssertTrue(script.contains("'Hello'"))
    }

    func testSendScriptCcEmptyIsEmptyArray() {
        let script = MailBridge.buildSendScript(to: ["a@b.com"], subject: "Hi", body: "Body", dryRun: false)
        XCTAssertTrue(script.contains("var ccAddrs = [];"))
    }

    func testSendScriptCcInterpolated() {
        let script = MailBridge.buildSendScript(to: ["a@b.com"], subject: "Hi", body: "Body", cc: ["cc@b.com"], dryRun: false)
        XCTAssertTrue(script.contains("'cc@b.com'"))
        XCTAssertTrue(script.contains("var ccAddrs = "))
    }

    func testSendScriptBccInterpolated() {
        let script = MailBridge.buildSendScript(to: ["a@b.com"], subject: "Hi", body: "Body", bcc: ["bcc@b.com"], dryRun: false)
        XCTAssertTrue(script.contains("'bcc@b.com'"))
        XCTAssertTrue(script.contains("var bccAddrs = "))
    }

    func testSendScriptAttachmentEmpty() {
        let script = MailBridge.buildSendScript(to: ["a@b.com"], subject: "Hi", body: "Body", dryRun: false)
        XCTAssertTrue(script.contains("var attachPaths = [];"))
    }

    func testSendScriptAttachmentInterpolated() {
        let script = MailBridge.buildSendScript(to: ["a@b.com"], subject: "Hi", body: "Body", attachmentPaths: ["/tmp/file.pdf"], dryRun: false)
        XCTAssertTrue(script.contains("'/tmp/file.pdf'"))
    }

    func testSendScriptMultipleAttachments() {
        let script = MailBridge.buildSendScript(to: ["a@b.com"], subject: "Hi", body: "Body", attachmentPaths: ["/tmp/a.pdf", "/tmp/b.pdf"], dryRun: false)
        XCTAssertTrue(script.contains("'/tmp/a.pdf'"))
        XCTAssertTrue(script.contains("'/tmp/b.pdf'"))
    }

    func testSendScriptDryRunTrue() {
        let script = MailBridge.buildSendScript(to: ["a@b.com"], subject: "Hi", body: "Body", dryRun: true)
        XCTAssertTrue(script.contains("var isDryRun = true;"))
    }

    func testSendScriptEscapesNewlineInBody() {
        let script = MailBridge.buildSendScript(to: ["a@b.com"], subject: "Hi", body: "Line1\nLine2", dryRun: false)
        XCTAssertTrue(script.contains("Line1\\nLine2"))
        XCTAssertFalse(script.contains("Line1\nLine2"))
    }

    func testSendScriptFromNilIsNull() {
        let script = MailBridge.buildSendScript(to: ["a@b.com"], subject: "Hi", body: "Body", dryRun: false)
        XCTAssertTrue(script.contains("var fromAcct = null;"))
    }

    func testSendScriptFromInterpolated() {
        let script = MailBridge.buildSendScript(to: ["a@b.com"], subject: "Hi", body: "Body", from: "Personal", dryRun: false)
        XCTAssertTrue(script.contains("var fromAcct = 'Personal';"))
    }

    func testSendScriptMultipleToAddresses() {
        let script = MailBridge.buildSendScript(to: ["a@b.com", "c@d.com"], subject: "Hi", body: "Body", dryRun: false)
        XCTAssertTrue(script.contains("'a@b.com'"))
        XCTAssertTrue(script.contains("'c@d.com'"))
    }

    // MARK: - buildSearchScript (scan order fix)

    func testSearchScriptSlicesFromEnd() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10)
        XCTAssertTrue(script.contains("allMsgs.length - scanCount"))
        XCTAssertTrue(script.contains("allMsgs.slice(startIdx, allMsgs.length)"))
    }

    func testSearchScriptIteratesNewestFirst() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10)
        // Iterates from end to start (i = msgs.length - 1; i >= 0; i--)
        XCTAssertTrue(script.contains("msgs.length - 1"))
        XCTAssertTrue(script.contains("i--"))
    }

    func testSearchScriptOutputsMetaWrapper() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10)
        XCTAssertTrue(script.contains("JSON.stringify({results: results, meta: _meta})"))
    }

    // MARK: - buildSearchScript (date filters)

    func testSearchScriptAfterFilterNilIsNull() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10, after: nil)
        XCTAssertTrue(script.contains("var afterFilter = null;"))
    }

    func testSearchScriptAfterFilterInterpolated() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10, after: "2026-03-07")
        XCTAssertTrue(script.contains("var afterFilter = '2026-03-07';"))
    }

    func testSearchScriptBeforeFilterNilIsNull() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10, before: nil)
        XCTAssertTrue(script.contains("var beforeFilter = null;"))
    }

    func testSearchScriptBeforeFilterInterpolated() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10, before: "2026-03-10")
        XCTAssertTrue(script.contains("var beforeFilter = '2026-03-10';"))
    }

    func testSearchScriptDateComparisonLogic() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10, after: "2026-01-01")
        XCTAssertTrue(script.contains("afterDate !== null && msgDate < afterDate"))
        XCTAssertTrue(script.contains("beforeDate !== null && msgDate > beforeDate"))
    }

    // MARK: - buildSearchScript (to filter)

    func testSearchScriptToFilterNilIsNull() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10, to: nil)
        XCTAssertTrue(script.contains("var toFilter = null;"))
    }

    func testSearchScriptToFilterInterpolated() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10, to: "user@example.com")
        XCTAssertTrue(script.contains("var toFilter = 'user@example.com';"))
    }

    func testSearchScriptToRecipientsCalledOnMatch() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10, to: "user@example.com")
        XCTAssertTrue(script.contains("matched && toFilter !== null"))
        XCTAssertTrue(script.contains("msg.toRecipients()"))
    }

    func testSearchScriptToFieldPopulatedInResults() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10)
        XCTAssertTrue(script.contains("to: toAddrs"))
    }

    // MARK: - buildSearchScript (meta tracking)

    func testSearchScriptMetaAccountsScanned() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10)
        XCTAssertTrue(script.contains("_meta.accountsScanned++"))
    }

    func testSearchScriptMetaMailboxesScanned() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10)
        XCTAssertTrue(script.contains("_meta.mailboxesScanned++"))
    }

    func testSearchScriptMetaMessagesExamined() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10)
        XCTAssertTrue(script.contains("_meta.messagesExamined++"))
    }
}
