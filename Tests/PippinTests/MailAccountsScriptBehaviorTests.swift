import JavaScriptCore
@testable import PippinLib
import XCTest

/// Runs the Mail accounts script against a fake `Application('Mail')` in
/// JavaScriptCore. The script reads every account's name, addresses and id in
/// three bulk Apple Events and falls back to the per-account loop whenever the
/// bulk lists cannot be trusted to line up.
final class MailAccountsScriptBehaviorTests: XCTestCase {
    private struct Row: Decodable, Equatable {
        let name: String
        let email: String
        let id: String
    }

    /// `rows` is the truth. `bulk` overrides what the three bulk reads return.
    /// Every call that would be an Apple Event is counted in `events`.
    private static let fakeMail = """
    var events = 0;
    var rows = [
        {name: 'Personal', emails: ['p@example.com', 'alias@example.com'], id: 'AAAA'},
        {name: 'Work', emails: ['w@example.com'], id: 'BBBB'},
        {name: 'Bare', emails: null, id: 'CCCC'}
    ];
    var bulk = {};
    function account(row) {
        return {
            name: function() { events++; return row.name; },
            emailAddresses: function() { events++; return row.emails; },
            id: function() { events++; return row.id; }
        };
    }
    function bulkRead(key, live) {
        return function() {
            events++;
            if (bulk[key] === 'throw') { throw new Error('bulk read failed'); }
            return bulk[key] !== undefined ? bulk[key] : live();
        };
    }
    var accounts = function() { events++; return rows.map(account); };
    // A function's own `name` is read-only, so plain assignment would be ignored.
    Object.defineProperty(accounts, 'name', {
        value: bulkRead('name', function() { return rows.map(function(r) { return r.name; }); })
    });
    accounts.emailAddresses = bulkRead('emails', function() { return rows.map(function(r) { return r.emails; }); });
    accounts.id = bulkRead('id', function() { return rows.map(function(r) { return r.id; }); });
    function Application(name) { return {accounts: accounts}; }
    function delay(seconds) {}
    """

    private let expected = [
        Row(name: "Personal", email: "p@example.com", id: "AAAA"),
        Row(name: "Work", email: "w@example.com", id: "BBBB"),
        Row(name: "Bare", email: "", id: "CCCC"),
    ]

    private func runAccountsScript(setup: String = "") throws -> (rows: [Row], events: Int) {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(Self.fakeMail + "\n" + setup)
        let value = context.evaluateScript(MailBridge.buildAccountsScript())
        XCTAssertNil(context.exception, "script threw: \(String(describing: context.exception))")
        let json = try XCTUnwrap(value?.toString())
        let rows = try JSONDecoder().decode([Row].self, from: Data(json.utf8))
        return (rows, Int(context.evaluateScript("events").toInt32()))
    }

    func testBulkReadReturnsEveryAccountInThreeEvents() throws {
        let result = try runAccountsScript()
        XCTAssertEqual(result.rows, expected)
        // One event per property, whatever the account count; the names read doubles as the
        // readiness check, so the poll runs only when it comes back empty (pippin-k177).
        XCTAssertEqual(result.events, 3)
    }

    func testBulkListsOfDifferentLengthsFallBackToThePerAccountRead() throws {
        // An account vanished between two of the bulk reads: positions no
        // longer line up, so no row may be built from them.
        let result = try runAccountsScript(setup: "bulk.id = ['AAAA', 'BBBB'];")
        XCTAssertEqual(result.rows, expected)
        XCTAssertGreaterThan(result.events, 3)
    }

    func testAFailedBulkReadFallsBackToThePerAccountRead() throws {
        let result = try runAccountsScript(setup: "bulk.emails = 'throw';")
        XCTAssertEqual(result.rows, expected)
    }

    func testTheFallbackKeepsItsOwnPerAccountErrorHandling() throws {
        let result = try runAccountsScript(setup: """
        bulk.name = 'throw';
        var plain = account;
        account = function(row) {
            var a = plain(row);
            if (row.name === 'Work') { a.id = function() { throw new Error('no id'); }; }
            return a;
        };
        """)
        XCTAssertEqual(result.rows.map(\.id), ["AAAA", "", "CCCC"])
        XCTAssertEqual(result.rows.map(\.name), expected.map(\.name))
    }

    func testNoAccountsStillFailsTheReadyPoll() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(Self.fakeMail + "\nrows = [];")
        context.evaluateScript(MailBridge.buildAccountsScript())
        XCTAssertNotNil(context.exception)
    }
}
