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

    // MARK: - buildSearchScript (soft timeout)

    func testSearchScriptDefaultSoftTimeoutIs22Seconds() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10)
        XCTAssertTrue(script.contains("var softTimeoutMs = 22000;"))
    }

    func testSearchScriptInterpolatesSoftTimeout() {
        let script = MailBridge.buildSearchScript(
            query: "test", account: nil, limit: 10, softTimeoutMs: 5000
        )
        XCTAssertTrue(script.contains("var softTimeoutMs = 5000;"))
    }

    func testSearchScriptClampsSoftTimeoutBelowOneSecond() {
        let script = MailBridge.buildSearchScript(
            query: "test", account: nil, limit: 10, softTimeoutMs: 0
        )
        XCTAssertTrue(script.contains("var softTimeoutMs = 1000;"))
    }

    func testSearchScriptClampsSoftTimeoutAboveFiveMinutes() {
        let script = MailBridge.buildSearchScript(
            query: "test", account: nil, limit: 10, softTimeoutMs: 999_999_999
        )
        XCTAssertTrue(script.contains("var softTimeoutMs = 300000;"))
    }

    func testSearchScriptInjectsTimedOutMetaField() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10)
        XCTAssertTrue(script.contains("timedOut: false"))
    }

    func testSearchScriptInjectsStartTimestamp() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10)
        XCTAssertTrue(script.contains("var _searchStart = Date.now();"))
    }

    func testSearchScriptBreaksOnSoftTimeoutInPerMessageLoop() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10)
        XCTAssertTrue(
            script.contains("Date.now() - _searchStart > softTimeoutMs"),
            "search script must check elapsed time inside the scan loops"
        )
        XCTAssertTrue(script.contains("_meta.timedOut = true"))
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

    // MARK: - buildListScript (preview)

    func testListScriptPreviewDisabledByDefault() {
        let script = MailBridge.buildListScript(account: nil, mailbox: "INBOX", unread: false, limit: 10)
        XCTAssertTrue(script.contains("var previewChars = 0;"))
    }

    func testListScriptPreviewInterpolatesValue() {
        let script = MailBridge.buildListScript(
            account: nil, mailbox: "INBOX", unread: false, limit: 10, preview: 200
        )
        XCTAssertTrue(script.contains("var previewChars = 200;"))
        // msg.content() is required to trigger the IMAP body fetch per CLAUDE.md.
        XCTAssertTrue(script.contains("msg.content()"), "preview branch must call msg.content() to force IMAP fetch")
        XCTAssertTrue(script.contains("row.bodyPreview"), "preview values should be attached as bodyPreview key")
    }

    func testListScriptPreviewClampsAbove4000() {
        let script = MailBridge.buildListScript(
            account: nil, mailbox: "INBOX", unread: false, limit: 10, preview: 99999
        )
        XCTAssertTrue(script.contains("var previewChars = 4000;"), "preview should clamp at 4000")
    }

    // MARK: - buildListScript (soft timeout)

    func testListScriptDefaultSoftTimeoutIs22Seconds() {
        let script = MailBridge.buildListScript(account: nil, mailbox: "INBOX", unread: false, limit: 10)
        XCTAssertTrue(script.contains("var softTimeoutMs = 22000;"))
    }

    func testListScriptInterpolatesSoftTimeout() {
        let script = MailBridge.buildListScript(
            account: nil, mailbox: "INBOX", unread: false, limit: 10, softTimeoutMs: 5000
        )
        XCTAssertTrue(script.contains("var softTimeoutMs = 5000;"))
    }

    func testListScriptClampsSoftTimeoutBelowOneSecond() {
        let script = MailBridge.buildListScript(
            account: nil, mailbox: "INBOX", unread: false, limit: 10, softTimeoutMs: 0
        )
        XCTAssertTrue(script.contains("var softTimeoutMs = 1000;"))
    }

    func testListScriptClampsSoftTimeoutAboveFiveMinutes() {
        let script = MailBridge.buildListScript(
            account: nil, mailbox: "INBOX", unread: false, limit: 10, softTimeoutMs: 999_999_999
        )
        XCTAssertTrue(script.contains("var softTimeoutMs = 300000;"))
    }

    func testListScriptInjectsStartTimestamp() {
        let script = MailBridge.buildListScript(account: nil, mailbox: "INBOX", unread: false, limit: 10)
        XCTAssertTrue(script.contains("var _listStart = Date.now();"))
    }

    func testListScriptBreaksOnSoftTimeoutInPerMessageLoop() {
        let script = MailBridge.buildListScript(account: nil, mailbox: "INBOX", unread: false, limit: 10)
        XCTAssertTrue(
            script.contains("Date.now() - _listStart > softTimeoutMs"),
            "list script must check elapsed time inside the per-message body-fetch loop"
        )
        XCTAssertTrue(script.contains("_meta.timedOut = true"))
    }

    func testListScriptInjectsTimedOutMetaField() {
        let script = MailBridge.buildListScript(account: nil, mailbox: "INBOX", unread: false, limit: 10)
        XCTAssertTrue(script.contains("timedOut: false"))
    }

    func testListScriptOutputsMetaWrapper() {
        let script = MailBridge.buildListScript(account: nil, mailbox: "INBOX", unread: false, limit: 10)
        XCTAssertTrue(script.contains("JSON.stringify({results: results, meta: _meta})"))
    }

    // MARK: - buildActivityScript

    func testActivityScriptDefaultMailboxesAreInboxAndSent() {
        let script = MailBridge.buildActivityScript(
            account: nil, mailboxes: ["INBOX", "Sent"], since: nil, limit: 50, preview: 200
        )
        XCTAssertTrue(script.contains("'INBOX'"))
        XCTAssertTrue(script.contains("'Sent'"))
    }

    func testActivityScriptInterpolatesLimit() {
        let script = MailBridge.buildActivityScript(
            account: nil, mailboxes: ["INBOX"], since: nil, limit: 33, preview: 0
        )
        XCTAssertTrue(script.contains("var limit = 33;"))
    }

    func testActivityScriptPreviewClampsAbove4000() {
        let script = MailBridge.buildActivityScript(
            account: nil, mailboxes: ["INBOX"], since: nil, limit: 10, preview: 99999
        )
        XCTAssertTrue(script.contains("var previewChars = 4000;"))
    }

    func testActivityScriptDefaultSoftTimeoutIs22Seconds() {
        let script = MailBridge.buildActivityScript(
            account: nil, mailboxes: ["INBOX"], since: nil, limit: 10, preview: 0
        )
        XCTAssertTrue(script.contains("var softTimeoutMs = 22000;"))
    }

    func testActivityScriptInterpolatesSoftTimeout() {
        let script = MailBridge.buildActivityScript(
            account: nil, mailboxes: ["INBOX"], since: nil, limit: 10, preview: 0, softTimeoutMs: 8000
        )
        XCTAssertTrue(script.contains("var softTimeoutMs = 8000;"))
    }

    func testActivityScriptClampsSoftTimeoutBelowOneSecond() {
        let script = MailBridge.buildActivityScript(
            account: nil, mailboxes: ["INBOX"], since: nil, limit: 10, preview: 0, softTimeoutMs: 0
        )
        XCTAssertTrue(script.contains("var softTimeoutMs = 1000;"))
    }

    func testActivityScriptClampsSoftTimeoutAboveFiveMinutes() {
        let script = MailBridge.buildActivityScript(
            account: nil, mailboxes: ["INBOX"], since: nil, limit: 10, preview: 0, softTimeoutMs: 999_999_999
        )
        XCTAssertTrue(script.contains("var softTimeoutMs = 300000;"))
    }

    func testActivityScriptInjectsStartTimestamp() {
        let script = MailBridge.buildActivityScript(
            account: nil, mailboxes: ["INBOX"], since: nil, limit: 10, preview: 0
        )
        XCTAssertTrue(script.contains("var _activityStart = Date.now();"))
    }

    func testActivityScriptBreaksOnSoftTimeoutInScanLoop() {
        let script = MailBridge.buildActivityScript(
            account: nil, mailboxes: ["INBOX"], since: nil, limit: 10, preview: 0
        )
        XCTAssertTrue(
            script.contains("Date.now() - _activityStart > softTimeoutMs"),
            "activity script must check elapsed time inside the scan + preview loops"
        )
        XCTAssertTrue(script.contains("_meta.timedOut = true"))
    }

    func testActivityScriptInjectsTimedOutMetaField() {
        let script = MailBridge.buildActivityScript(
            account: nil, mailboxes: ["INBOX"], since: nil, limit: 10, preview: 0
        )
        XCTAssertTrue(script.contains("timedOut: false"))
    }

    func testActivityScriptOutputsMetaWrapper() {
        let script = MailBridge.buildActivityScript(
            account: nil, mailboxes: ["INBOX"], since: nil, limit: 10, preview: 0
        )
        XCTAssertTrue(script.contains("JSON.stringify({results: results, meta: _meta})"))
    }

    func testActivityScriptPreviewLoopHasTimeoutCheck() {
        // The post-slice preview loop fetches msg.content() which can be slow on iCloud;
        // it must also bail out on soft-timeout, not just the metadata-collection loop.
        let script = MailBridge.buildActivityScript(
            account: nil, mailboxes: ["INBOX"], since: nil, limit: 10, preview: 200
        )
        // Two separate timeout checks: one in the scan loop, one in the preview loop.
        let occurrences = script.components(separatedBy: "Date.now() - _activityStart > softTimeoutMs").count - 1
        XCTAssertGreaterThanOrEqual(occurrences, 2, "expected timeout check in both scan and preview loops")
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

    func testReadScriptHandlesAttachmentMimeTypeFailure() {
        // att.mimeType() raises -10000 on some IMAP-backed attachments; the script must
        // catch per-attachment and fall back to application/octet-stream instead of
        // swallowing the entire loop and returning attachments:[].
        let script = MailBridge.buildReadScript(account: "Work", mailbox: "INBOX", messageId: "1")
        XCTAssertTrue(script.contains("application/octet-stream"))
        XCTAssertTrue(script.contains("try { var m = att.mimeType();"))
    }

    func testReadScriptHandlesAttachmentNameFailure() {
        // att.name() also throws on some attachments; fall back to `attachment_<i>`.
        let script = MailBridge.buildReadScript(account: "Work", mailbox: "INBOX", messageId: "1")
        XCTAssertTrue(script.contains("'attachment_' + ai"))
        XCTAssertTrue(script.contains("try { attName = att.name(); } catch(e) {}"))
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

    // MARK: - Scan direction probe (GitHub #23/#24)

    func testJsProbeNewestFirstComparesEndpointDates() {
        let js = MailBridge.jsProbeNewestFirst(collection: "allMsgs", fallbackNewestFirst: false)
        XCTAssertTrue(js.contains("var newestFirst = false;"))
        XCTAssertTrue(js.contains("allMsgs[0].dateSent()"))
        XCTAssertTrue(js.contains("allMsgs[allMsgs.length - 1].dateSent()"))
        XCTAssertTrue(js.contains("allMsgs.length >= 2"), "probe must guard against 0/1-message collections")
        XCTAssertTrue(js.contains("try {"), "probe must fall back to the assumption on Apple Event errors")
    }

    func testJsProbeNewestFirstFallbackTrue() {
        let js = MailBridge.jsProbeNewestFirst(collection: "msgs", fallbackNewestFirst: true)
        XCTAssertTrue(js.contains("var newestFirst = true;"))
        XCTAssertTrue(js.contains("msgs[0].dateSent()"))
    }

    func testSearchScriptProbesScanDirection() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10)
        XCTAssertTrue(script.contains("var newestFirst"))
        XCTAssertTrue(
            script.contains("newestFirst ? k : totalMsgs - 1 - k"),
            "scan index must be derived from the probed direction so the walk is newest→oldest either way"
        )
    }

    func testListScriptProbesScanDirection() {
        let script = MailBridge.buildListScript(account: nil, mailbox: "INBOX", unread: false, limit: 10)
        XCTAssertTrue(script.contains("var newestFirst"))
        XCTAssertTrue(
            script.contains("newestFirst ? offset + k : totalMsgs - 1 - offset - k"),
            "list window must map offset/limit onto the probed direction"
        )
    }

    func testActivityScriptProbesScanDirection() {
        let script = MailBridge.buildActivityScript(
            account: nil, mailboxes: ["INBOX"], since: nil, limit: 10, preview: 0
        )
        XCTAssertTrue(script.contains("var newestFirst"))
        XCTAssertTrue(
            script.contains("newestFirst ? k : totalMsgs - 1 - k"),
            "activity scan must walk the newest N regardless of underlying order"
        )
    }

    func testSearchScriptWindowIsNewestNRegardlessOfOrder() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10)
        // The per-mailbox cap still applies, but as a count of newest positions,
        // not a raw index slice from either end.
        XCTAssertTrue(script.contains("Math.min(totalMsgs, perMailboxLimit)"))
        XCTAssertFalse(script.contains("allMsgs.slice("), "raw slices bake in an ordering assumption")
    }

    // MARK: - buildSearchScript (#23: date-window scan efficiency)

    func testSearchScriptBreaksOnceOlderThanAfterDate() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10, after: "2026-06-01")
        XCTAssertTrue(
            script.contains("if (afterDate !== null && msgDate < afterDate) break;"),
            "walking newest→oldest, the first message older than --after ends the mailbox scan"
        )
    }

    func testSearchScriptKeepsBeforeContinueGuard() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10, before: "2026-06-10")
        XCTAssertTrue(
            script.contains("if (beforeDate !== null && msgDate > beforeDate) continue;"),
            "messages newer than --before must be skipped cheaply before any content() call"
        )
    }

    func testSearchScriptShiftsWindowTowardBeforeDate() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10, before: "2026-06-10")
        // Binary search over dateSent() probes to start the window near --before.
        XCTAssertTrue(script.contains("var scanFrom = 0;"))
        XCTAssertTrue(script.contains("(lo + hi) >> 1"), "window shift must binary-search index positions")
        XCTAssertTrue(script.contains(".dateSent()"), "probes must use dateSent(), never content()")
        XCTAssertTrue(script.contains("_meta.windowsShifted++"))
    }

    func testSearchScriptDateGuardPrecedesContentFetch() throws {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, searchBody: true, limit: 10, after: "2026-06-01")
        let guardIdx = try XCTUnwrap(script.range(of: "msgDate < afterDate")?.lowerBound)
        let bodyIdx = try XCTUnwrap(script.range(of: "msg.content()")?.lowerBound)
        XCTAssertLessThan(guardIdx, bodyIdx)
    }

    func testSearchScriptEmitsWindowsShiftedMeta() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10)
        XCTAssertTrue(script.contains("windowsShifted: 0"))
    }

    // MARK: - buildSearchScript (--from filter, GitHub #21)

    func testSearchScriptFromFilterNilIsNull() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10, from: nil)
        XCTAssertTrue(script.contains("var fromFilter = null;"))
    }

    func testSearchScriptFromFilterInterpolated() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10, from: "boss@example.com")
        XCTAssertTrue(script.contains("var fromFilter = 'boss@example.com';"))
    }

    func testSearchScriptFromFilterEscapesQuote() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10, from: "O'Brien")
        XCTAssertTrue(script.contains("fromFilter = 'O\\'Brien'"))
    }

    func testSearchScriptFromFilterGuardsSender() {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, limit: 10, from: "boss")
        XCTAssertTrue(script.contains(
            "if (fromFilter !== null && sender.toLowerCase().indexOf(fromFilter.toLowerCase()) === -1) continue;"
        ))
    }

    func testSearchScriptFromGuardPrecedesBodyFetch() throws {
        let script = MailBridge.buildSearchScript(query: "test", account: nil, searchBody: true, limit: 10, from: "boss")
        let guardIdx = try XCTUnwrap(script.range(of: "fromFilter.toLowerCase()")?.lowerBound)
        let bodyIdx = try XCTUnwrap(script.range(of: "msg.content()")?.lowerBound)
        XCTAssertLessThan(guardIdx, bodyIdx, "sender guard must skip messages before the expensive content() fetch")
    }

    // MARK: - buildListScript (date filters, GitHub #25)

    func testListScriptAfterFilterNilIsNull() {
        let script = MailBridge.buildListScript(account: nil, mailbox: "INBOX", unread: false, limit: 10)
        XCTAssertTrue(script.contains("var afterFilter = null;"))
    }

    func testListScriptAfterFilterInterpolated() {
        let script = MailBridge.buildListScript(account: nil, mailbox: "INBOX", unread: false, limit: 10, after: "2026-06-01")
        XCTAssertTrue(script.contains("var afterFilter = '2026-06-01';"))
    }

    func testListScriptBeforeFilterInterpolated() {
        let script = MailBridge.buildListScript(account: nil, mailbox: "INBOX", unread: false, limit: 10, before: "2026-06-10")
        XCTAssertTrue(script.contains("var beforeFilter = '2026-06-10';"))
    }

    func testListScriptParsesDateFilters() {
        let script = MailBridge.buildListScript(account: nil, mailbox: "INBOX", unread: false, limit: 10, after: "2026-06-01")
        XCTAssertTrue(script.contains("new Date(afterFilter)"))
        XCTAssertTrue(script.contains("new Date(beforeFilter)"))
    }

    func testListScriptDateComparisonLogic() {
        let script = MailBridge.buildListScript(
            account: nil, mailbox: "INBOX", unread: false, limit: 10, after: "2026-06-01", before: "2026-06-10"
        )
        XCTAssertTrue(script.contains("afterDate !== null && msgDate < afterDate"))
        XCTAssertTrue(script.contains("beforeDate !== null && msgDate > beforeDate"))
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

    // MARK: - buildSaveAttachmentsScript (pippin-20v regression)

    func testSaveAttachmentsScriptFallsBackToAllMailboxesOnLabel() {
        // Gmail labels like "Important" return -1728 from resolveMailbox; the script must fall
        // back to collectAllMailboxes and scan every mailbox by id before giving up.
        let script = MailBridge.buildSaveAttachmentsScript(
            account: "user@example.com", mailbox: "Important", messageId: "6442", saveDir: "/tmp/out"
        )
        XCTAssertTrue(script.contains("function collectAllMailboxes"))
        XCTAssertTrue(script.contains("collectAllMailboxes(acct.mailboxes(), [])"))
        XCTAssertTrue(script.contains("function findMessageById"))
        XCTAssertFalse(
            script.contains("MAILBRIDGE_ERR_MAILBOX_NOT_FOUND"),
            "Must not throw on mailbox lookup failure — fallback scans all mailboxes"
        )
    }

    func testSaveAttachmentsScriptPreTouchesSaveTarget() {
        // att.save({to: Path(dest)}) returns -10000 unless the target file already exists.
        // The script must pre-create (touch) the destination before calling save().
        let script = MailBridge.buildSaveAttachmentsScript(
            account: "acc", mailbox: "INBOX", messageId: "123", saveDir: "/tmp/out"
        )
        XCTAssertTrue(script.contains("function prepareSaveTarget"))
        XCTAssertTrue(script.contains("/usr/bin/touch "))
        XCTAssertTrue(script.contains("prepareSaveTarget(dest)"))
        // {in: Path(dest)} — JXA preposition maps to AppleScript 'save a in POSIX file ...';
        // {to: ...} raises -10000.
        XCTAssertTrue(script.contains("att.save({in: Path(dest)})"))
        XCTAssertFalse(script.contains("att.save({to: Path(dest)})"))
        let touchIdx = script.range(of: "prepareSaveTarget(dest)")?.lowerBound
        let saveIdx = script.range(of: "att.save({in: Path(dest)})")?.lowerBound
        XCTAssertNotNil(touchIdx)
        XCTAssertNotNil(saveIdx)
        if let t = touchIdx, let s = saveIdx { XCTAssertLessThan(t, s, "Touch must precede save") }
    }

    func testSaveAttachmentsScriptHandlesMimeTypeFailure() {
        // att.mimeType() throws "AppleEvent handler failed" (-10000) on some IMAP-backed
        // attachments; an unhandled throw propagates as a top-level script failure. The script
        // must fall back to a generic MIME instead of crashing.
        let script = MailBridge.buildSaveAttachmentsScript(
            account: "acc", mailbox: "INBOX", messageId: "123", saveDir: "/tmp/out"
        )
        XCTAssertTrue(script.contains("application/octet-stream"))
        XCTAssertTrue(script.contains("try { var m = att.mimeType();"))
    }

    func testSaveAttachmentsScriptNoSaveDirStillSafe() {
        // Metadata-only call (saveDir=nil): script builds cleanly and the touch is gated by
        // saveDir !== null at runtime so nothing gets created.
        let script = MailBridge.buildSaveAttachmentsScript(
            account: "acc", mailbox: "INBOX", messageId: "123", saveDir: nil
        )
        XCTAssertTrue(script.contains("var saveDir = null;"))
        XCTAssertTrue(script.contains("if (saveDir !== null)"))
    }
}
