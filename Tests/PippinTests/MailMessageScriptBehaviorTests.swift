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
