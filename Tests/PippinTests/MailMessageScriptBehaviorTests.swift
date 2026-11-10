import JavaScriptCore
@testable import PippinLib
import XCTest

/// Runs the generated per-message Mail JXA (read, mark, move, attachments) in
/// JavaScriptCore against a fake Mail, so the tests pin behavior, not source text.
final class MailMessageScriptBehaviorTests: XCTestCase {
    /// Fake Mail with one account `A` and one mailbox `INBOX` holding `__rows`.
    /// `__log` records every mutation the script performs.
    private static let fakeMail = """
    var __log = [];
    function delay() {}
    function Path(p) { return p; }
    function fakeAttachment(a) {
        return {
            name: function() { return a.name; },
            mimeType: function() { return 'text/plain'; },
            fileSize: function() { return 1; },
            save: function(o) {
                if (a.fails) throw new Error('save failed');
                __log.push('save:' + o['in']);
            }
        };
    }
    function fakeMessage(r) {
        var m = {
            id: function() { return r.id; },
            messageId: function() { if (r.noMessageId) throw new Error('no id'); return r.messageId; },
            source: function() { return ''; },
            content: function() { return 'body'; },
            htmlContent: function() { return '<p>body</p>'; },
            allHeaders: function() { return r.headers || ''; },
            mailAttachments: function() { return (r.attachments || []).map(fakeAttachment); },
            messageSize: function() { return 10; },
            dateSent: function() { return new Date('2026-01-01T00:00:00Z'); },
            dateReceived: function() { return new Date('2026-01-01T00:00:01Z'); },
            subject: function() { return 'subject'; },
            sender: function() { return 'sender@example.com'; },
            toRecipients: function() { return []; }
        };
        // JXA sets a property by assignment and reads it by call.
        Object.defineProperty(m, 'readStatus', {
            get: function() { return function() { return !!r.read; }; },
            set: function(v) { r.read = v; __log.push('mark:' + r.id + ':' + v); }
        });
        return m;
    }
    function fakeMailbox(name) {
        return {
            name: function() { return name; },
            mailboxes: function() { return []; },
            messages: {whose: function(q) { return function() {
                return __rows.filter(function(r) { return r.id == q.id; }).map(fakeMessage);
            }; }}
        };
    }
    var __inbox = fakeMailbox('INBOX');
    var __archive = fakeMailbox('Archive');
    var __account = {name: function() { return 'A'; }, mailboxes: function() { return [__inbox, __archive]; }};
    function Application() {
        return {
            accounts: function() { return [__account]; },
            move: function(msg, o) { __log.push('move:' + msg.id() + ':' + o.to.name()); }
        };
    }
    Application.currentApplication = function() {
        return {doShellScript: function(cmd) { __log.push('shell:' + cmd); }};
    };
    """

    private struct Run {
        let output: Any
        let log: [String]
    }

    /// Runs `script` against `rows` (a JS array literal). Throws `FailedRun`
    /// with the script's own error text when it throws.
    private func run(_ script: String, rows: String) throws -> Run {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(Self.fakeMail + "\nvar __rows = \(rows);")
        let value = context.evaluateScript(script)
        let log = context.evaluateScript("__log").toArray() as? [String] ?? []
        if let exception = context.exception {
            context.exception = nil
            throw FailedRun(message: exception.toString(), log: log)
        }
        let text = try XCTUnwrap(value?.toString())
        let output = try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
        return Run(output: output, log: log)
    }

    private struct FailedRun: Error {
        let message: String
        let log: [String]
    }

    // MARK: - Identity check before mutating (RC-19)

    private let rows = "[{id: 7, messageId: 'm7@example.com', attachments: [{name: 'a.txt'}]}]"

    /// The three scripts that act on a bare compound id, built with `expect`.
    private func mutatingScripts(expect: String?) -> [(name: String, script: String, mutation: String)] {
        [
            ("mark", MailBridge.buildMarkScript(
                account: "A", mailbox: "INBOX", messageId: "7", read: true, dryRun: false, expectMessageId: expect
            ), "mark:7:true"),
            ("move", MailBridge.buildMoveScript(
                account: "A", mailbox: "INBOX", messageId: "7", toMailbox: "Archive", dryRun: false,
                expectMessageId: expect
            ), "move:7:Archive"),
            ("attachments", MailBridge.buildSaveAttachmentsScript(
                account: "A", mailbox: "INBOX", messageId: "7", saveDir: "/stage", expectMessageId: expect
            ), "save:/stage/0"),
        ]
    }

    func testMismatchedExpectationAbortsBeforeAnyMutation() throws {
        for (name, script, _) in mutatingScripts(expect: "someone-else@example.com") {
            XCTAssertThrowsError(try run(script, rows: rows), name) { error in
                let failed = error as? FailedRun
                XCTAssertEqual(failed?.log, [], "\(name) acted on the wrong message")
                guard case .messageIdentityMismatch = MailBridge.mapScriptFailure(failed?.message ?? "") else {
                    return XCTFail("\(name): expected message_identity_mismatch, got \(String(describing: failed?.message))")
                }
            }
        }
    }

    func testMatchingExpectationActsWithOrWithoutAngleBrackets() throws {
        for expect in ["m7@example.com", "<m7@example.com>", " <m7@example.com>\n"] {
            for (name, script, mutation) in mutatingScripts(expect: expect) {
                XCTAssertTrue(try run(script, rows: rows).log.contains(mutation), "\(name) with \(expect.debugDescription)")
            }
        }
    }

    func testNoExpectationKeepsTheOldBehavior() throws {
        for (name, script, mutation) in mutatingScripts(expect: nil) {
            XCTAssertTrue(try run(script, rows: rows).log.contains(mutation), name)
        }
    }

    func testExpectationFailsClosedWhenTheMessageIdCannotBeRead() throws {
        for (name, script, _) in mutatingScripts(expect: "m7@example.com") {
            XCTAssertThrowsError(try run(script, rows: "[{id: 7, noMessageId: true}]"), name) { error in
                XCTAssertEqual((error as? FailedRun)?.log, [])
            }
        }
    }

    func testDryRunStillChecksIdentity() {
        let script = MailBridge.buildMoveScript(
            account: "A", mailbox: "INBOX", messageId: "7", toMailbox: "Archive", dryRun: true,
            expectMessageId: "someone-else@example.com"
        )
        XCTAssertThrowsError(try run(script, rows: rows))
    }

    func testReadScriptEmitsTheMessageId() throws {
        let result = try run(MailBridge.buildReadScript(account: "A", mailbox: "INBOX", messageId: "7"), rows: rows)
        XCTAssertEqual((result.output as? [String: Any])?["messageIdHeader"] as? String, "m7@example.com")
    }

    func testReplyAndForwardIdentityCheck() throws {
        func message(id: String?, headers: [String: String]? = nil) -> MailMessage {
            MailMessage(
                id: "A||INBOX||7", account: "A", mailbox: "INBOX", subject: "s", from: "a@b.c", to: [],
                date: "2026-01-01T00:00:00Z", read: true, headers: headers, messageIdHeader: id
            )
        }
        XCTAssertNoThrow(try MailBridge.requireIdentity(of: message(id: nil), expectMessageId: nil))
        XCTAssertNoThrow(try MailBridge.requireIdentity(of: message(id: "m7@example.com"), expectMessageId: "<m7@example.com>"))
        // A cached read from before the field existed still has the header.
        XCTAssertNoThrow(try MailBridge.requireIdentity(
            of: message(id: nil, headers: ["Message-Id": "<m7@example.com>"]), expectMessageId: "m7@example.com"
        ))
        for wrong in [message(id: "other@example.com"), message(id: nil)] {
            XCTAssertThrowsError(try MailBridge.requireIdentity(of: wrong, expectMessageId: "m7@example.com")) { error in
                XCTAssertEqual((error as? MailBridgeError)?.agentCode, "message_identity_mismatch")
            }
        }
    }

    func testCommandsAndToolsCarryTheExpectation() throws {
        XCTAssertEqual(try MailCommand.Mark.parse(["A||INBOX||7", "--read", "--expect-message-id", "m7@x"]).expectMessageId, "m7@x")
        XCTAssertNil(try MailCommand.Move.parse(["A||INBOX||7", "--to", "Archive"]).expectMessageId)
        let required: [String: [String: JSONValue]] = [
            "mail_mark": ["read": .bool(true)],
            "mail_move": ["to": .string("Archive")],
            "mail_attachments": [:],
            "mail_reply": ["body": .string("hi")],
            "mail_forward": ["to": .array([.string("a@b.co")])],
        ]
        for (name, extra) in required {
            let tool = try XCTUnwrap(MCPToolRegistry.tool(named: name))
            var args = extra
            args["messageId"] = .string("A||INBOX||7")
            XCTAssertFalse(try tool.buildArgs(.object(args)).contains { $0.contains("expect-message-id") }, name)
            args["expectMessageId"] = .string("m7@example.com")
            XCTAssertTrue(try tool.buildArgs(.object(args)).contains("--expect-message-id=m7@example.com"), name)
        }
    }

    // MARK: - Attachment saving (RC-07)

    func testSaveScriptNeverPutsTheSenderChosenNameInAPath() throws {
        let result = try run(
            MailBridge.buildSaveAttachmentsScript(account: "A", mailbox: "INBOX", messageId: "7", saveDir: "/stage"),
            rows: "[{id: 7, attachments: [{name: '../../Library/LaunchAgents/evil.plist'}, {name: 'b.txt'}]}]"
        )
        XCTAssertEqual(result.log.filter { $0.hasPrefix("save:") }, ["save:/stage/0", "save:/stage/1"])
        XCTAssertFalse(result.log.contains { $0.contains("evil") || $0.contains("..") }, "\(result.log)")
        let rows = try XCTUnwrap(result.output as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["savedPath"] as? String }, ["/stage/0", "/stage/1"])
        XCTAssertEqual(rows.first?["name"] as? String, "../../Library/LaunchAgents/evil.plist")
    }

    func testSaveScriptReportsAFailedSaveAndKeepsGoing() throws {
        let result = try run(
            MailBridge.buildSaveAttachmentsScript(account: "A", mailbox: "INBOX", messageId: "7", saveDir: "/stage"),
            rows: "[{id: 7, attachments: [{name: 'a.txt', fails: true}, {name: 'b.txt'}]}]"
        )
        let rows = try XCTUnwrap(result.output as? [[String: Any]])
        XCTAssertTrue(rows[0]["savedPath"] is NSNull)
        XCTAssertEqual(rows[0]["saveError"] as? String, "save failed")
        XCTAssertEqual(rows[1]["savedPath"] as? String, "/stage/1")
        XCTAssertTrue(rows[1]["saveError"] is NSNull)
    }

    // MARK: - Repeated headers (first occurrence wins)

    func testReadScriptKeepsTheTopmostOfARepeatedHeader() throws {
        // The receiving server's verdict is prepended; the lower one came with the message.
        let headers = [
            "Authentication-Results: mx.receiver.example; dkim=fail",
            "\theader.d=evil.example",
            "Subject: hi",
            "authentication-results: evil.example; dkim=pass",
            "\tspf=pass",
        ].joined(separator: "\\n")
        let result = try run(
            MailBridge.buildReadScript(account: "A", mailbox: "INBOX", messageId: "7"),
            rows: "[{id: 7, messageId: 'm7@example.com', headers: '\(headers)'}]"
        )
        let row = try XCTUnwrap(result.output as? [String: Any])
        let parsed = try XCTUnwrap(row["headers"] as? [String: String])
        XCTAssertEqual(parsed["Authentication-Results"], "mx.receiver.example; dkim=fail header.d=evil.example")
        XCTAssertNil(parsed["authentication-results"], "a later repeat must not add a second key")
        XCTAssertEqual(
            HeaderAnomalies.detect(from: "a@evil.example", to: ["me@example.com"], headers: parsed),
            ["Authentication failure: dkim=fail"]
        )
    }
}
