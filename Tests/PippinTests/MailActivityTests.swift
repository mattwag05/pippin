@testable import PippinLib
import XCTest

/// Tests for `MailCommand.Activity` — the combined multi-mailbox recent scan.
/// Assertions target the generated JXA script string; no osascript execution.
final class MailActivityTests: XCTestCase {
    // MARK: - Subcommand wiring

    func testActivityIsRegisteredUnderMail() {
        let names = MailCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("activity"), "Expected 'activity' subcommand, got: \(names)")
    }

    func testActivityCommandName() {
        XCTAssertEqual(MailCommand.Activity.configuration.commandName, "activity")
    }

    // MARK: - Validation

    func testActivityDefaults() throws {
        let cmd = try MailCommand.Activity.parse([])
        XCTAssertEqual(cmd.mailboxes, "INBOX,Sent")
        XCTAssertEqual(cmd.limit, 50)
        XCTAssertEqual(cmd.preview, 200)
        XCTAssertNil(cmd.since)
        XCTAssertNil(cmd.account)
    }

    func testActivityAcceptsSince() throws {
        let cmd = try MailCommand.Activity.parse(["--since", "2026-04-13"])
        XCTAssertEqual(cmd.since, "2026-04-13")
    }

    func testActivityInvalidSinceFails() {
        XCTAssertThrowsError(try MailCommand.Activity.parse(["--since", "yesterday"]))
    }

    func testActivityZeroLimitFails() {
        XCTAssertThrowsError(try MailCommand.Activity.parse(["--limit", "0"]))
    }

    func testActivityNegativePreviewFails() {
        XCTAssertThrowsError(try MailCommand.Activity.parse(["--preview", "-1"]))
    }

    func testActivityPreviewZeroPasses() throws {
        let cmd = try MailCommand.Activity.parse(["--preview", "0"])
        XCTAssertEqual(cmd.preview, 0)
    }

    func testActivityEmptyMailboxesFails() {
        XCTAssertThrowsError(try MailCommand.Activity.parse(["--mailboxes", " , , "]))
    }

    func testActivityCustomMailboxesParse() throws {
        let cmd = try MailCommand.Activity.parse(["--mailboxes", "INBOX, Drafts ,Sent"])
        XCTAssertEqual(cmd.mailboxes, "INBOX, Drafts ,Sent")
        XCTAssertEqual(MailCommand.Activity.parseMailboxList(cmd.mailboxes), ["INBOX", "Drafts", "Sent"])
    }

    func testActivityAcceptsJsonFormat() {
        XCTAssertNoThrow(try MailCommand.Activity.parse(["--format", "json"]))
    }

    func testActivityAcceptsAgentFormat() {
        XCTAssertNoThrow(try MailCommand.Activity.parse(["--format", "agent"]))
    }

    // MARK: - Script builder

    func testBuildActivityScriptDefaultMailboxes() {
        let script = MailBridge.buildActivityScript(
            account: nil, mailboxes: ["INBOX", "Sent"], since: nil, limit: 50, preview: 200
        )
        XCTAssertTrue(script.contains("'INBOX'"), "INBOX must be embedded in target list")
        XCTAssertTrue(script.contains("'Sent'"), "Sent must be embedded in target list")
        XCTAssertTrue(script.contains("collectAllMailboxes"), "activity script must fall back to collectAllMailboxes when resolveMailbox misses")
        XCTAssertTrue(script.contains("resolveMailbox(acct, targetName)"), "alias resolution must run per target name")
    }

    func testBuildActivityScriptAccountFilterInterpolated() {
        let script = MailBridge.buildActivityScript(
            account: "Work", mailboxes: ["INBOX"], since: nil, limit: 10, preview: nil
        )
        XCTAssertTrue(script.contains("var acctFilter = 'Work';"))
    }

    func testBuildActivityScriptNoAccountIsNull() {
        let script = MailBridge.buildActivityScript(
            account: nil, mailboxes: ["INBOX"], since: nil, limit: 10, preview: nil
        )
        XCTAssertTrue(script.contains("var acctFilter = null;"))
    }

    func testBuildActivityScriptSinceDateEmittedAsISO() throws {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let date = try XCTUnwrap(fmt.date(from: "2026-04-13T00:00:00Z"))
        let script = MailBridge.buildActivityScript(
            account: nil, mailboxes: ["INBOX"], since: date, limit: 10, preview: nil
        )
        XCTAssertTrue(script.contains("var sinceRaw = '2026-04-13T00:00:00Z';"), "since must emit ISO 8601 for new Date(...)")
        XCTAssertTrue(script.contains("new Date(sinceRaw)"))
    }

    func testBuildActivityScriptNoSinceIsNull() {
        let script = MailBridge.buildActivityScript(
            account: nil, mailboxes: ["INBOX"], since: nil, limit: 10, preview: nil
        )
        XCTAssertTrue(script.contains("var sinceRaw = null;"))
    }

    func testBuildActivityScriptPreviewDisabledByDefault() {
        let script = MailBridge.buildActivityScript(
            account: nil, mailboxes: ["INBOX"], since: nil, limit: 10, preview: nil
        )
        XCTAssertTrue(script.contains("var previewChars = 0;"))
    }

    func testBuildActivityScriptPreviewInterpolated() {
        let script = MailBridge.buildActivityScript(
            account: nil, mailboxes: ["INBOX"], since: nil, limit: 10, preview: 200
        )
        XCTAssertTrue(script.contains("var previewChars = 200;"))
        XCTAssertTrue(script.contains("msg.content()"), "preview path must call msg.content() to force IMAP fetch")
        XCTAssertTrue(script.contains("row.bodyPreview"), "preview path must attach bodyPreview key")
    }

    func testBuildActivityScriptPreviewClampsAbove4000() {
        let script = MailBridge.buildActivityScript(
            account: nil, mailboxes: ["INBOX"], since: nil, limit: 10, preview: 99999
        )
        XCTAssertTrue(script.contains("var previewChars = 4000;"))
    }

    func testBuildActivityScriptEmitsDedup() {
        let script = MailBridge.buildActivityScript(
            account: nil, mailboxes: ["INBOX", "Sent"], since: nil, limit: 10, preview: nil
        )
        XCTAssertTrue(script.contains("seenMsgKeys"), "cross-mailbox dedup must be present")
        XCTAssertTrue(script.contains("msg.messageId()"), "dedup should try messageId first")
    }

    func testBuildActivityScriptEmitsSortAndTruncate() {
        let script = MailBridge.buildActivityScript(
            account: nil, mailboxes: ["INBOX"], since: nil, limit: 7, preview: nil
        )
        XCTAssertTrue(script.contains("results.sort"), "final sort must be emitted")
        XCTAssertTrue(script.contains("results.slice(0, limit)"), "final truncate must be emitted")
        XCTAssertTrue(script.contains("var limit = 7;"))
    }

    func testBuildActivityScriptEscapesMailboxNames() {
        let script = MailBridge.buildActivityScript(
            account: nil, mailboxes: ["O'Brien"], since: nil, limit: 10, preview: nil
        )
        XCTAssertTrue(script.contains("'O\\'Brien'"), "single quotes in mailbox names must be escaped")
    }

    // MARK: - parseMailboxList helper

    func testParseMailboxListTrimsWhitespace() {
        XCTAssertEqual(
            MailCommand.Activity.parseMailboxList(" INBOX , Sent , Drafts "),
            ["INBOX", "Sent", "Drafts"]
        )
    }

    func testParseMailboxListDropsEmptyTokens() {
        XCTAssertEqual(
            MailCommand.Activity.parseMailboxList("INBOX,,Sent"),
            ["INBOX", "Sent"]
        )
    }
}
