import JavaScriptCore
@testable import PippinLib
import XCTest

/// Executes the generated Mail JXA in JavaScriptCore against a fake Mail, so these
/// tests pin what the scripts do rather than how their source text reads.
final class MailBulkScriptBehaviorTests: XCTestCase {
    /// Fake Mail. `__reads` records every per-message Apple Event equivalent and
    /// which mailboxes were bulk read; `__clock` replaces `Date.now`.
    private static let fakeMail = """
    var __clock = 1000000;
    Date.now = function() { return __clock; };
    var __reads = {bulk: [], materialized: 0, content: [], attachments: [], recipients: []};
    function delay() {}
    function __date(v) { return v === null || v === undefined ? null : new Date(v); }
    function __row(r) {
        return {
            id: r.id,
            received: __date(r.received),
            sent: 'sent' in r ? __date(r.sent) : __date(r.received),
            read: !!r.read,
            subject: r.subject === undefined ? 'subject ' + r.id : r.subject,
            sender: r.sender === undefined ? 'sender@example.com' : r.sender,
            size: r.size === undefined ? 100 + r.id : r.size,
            body: r.body === undefined ? 'body ' + r.id : r.body,
            to: r.to || [],
            messageId: r.messageId === undefined ? 'mid-' + r.id : r.messageId,
            attachments: r.attachments || []
        };
    }
    function __message(row) {
        return {
            id: function() { return row.id; },
            content: function() { __reads.content.push(row.id); return row.body; },
            mailAttachments: function() { __reads.attachments.push(row.id); return row.attachments; },
            toRecipients: function() {
                __reads.recipients.push(row.id);
                return row.to.map(function(a) { return {address: function() { return a; }}; });
            },
            messageId: function() { return row.messageId; }
        };
    }
    // opts.overrides replaces any bulk property getter; opts.onBulk runs once per bulk read.
    function fakeMailbox(name, rawRows, opts) {
        opts = opts || {};
        var rows = rawRows.map(__row);
        var messages = function() {
            __reads.materialized++;
            return opts.materialized ? opts.materialized(rows.map(__message)) : rows.map(__message);
        };
        function column(key) { return function() { return rows.map(function(r) { return r[key]; }); }; }
        messages.id = function() {
            if (__reads.bulk.indexOf(name) === -1) __reads.bulk.push(name);
            return rows.map(function(r) { return r.id; });
        };
        messages.dateReceived = column('received');
        messages.dateSent = column('sent');
        messages.readStatus = column('read');
        messages.subject = column('subject');
        messages.sender = column('sender');
        messages.messageSize = function() {
            if (opts.onBulk) opts.onBulk();
            return rows.map(function(r) { return r.size; });
        };
        for (var key in (opts.overrides || {})) messages[key] = opts.overrides[key];
        Object.defineProperty(messages, 'length', {get: function() { return rows.length; }});
        return {name: function() { return name; }, messages: messages, mailboxes: function() { return []; }};
    }
    function fakeAccount(name, mailboxes) {
        return {name: function() { return name; }, mailboxes: function() { return mailboxes; }};
    }
    function Application() { return {accounts: function() { return __accounts; }}; }
    var __rows = [{id: 1, received: '2026-01-01T00:00:00Z'}, {id: 2, received: '2026-01-02T00:00:00Z'}];
    """

    private func makeContext() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(MailBridge.jsMailDates() + "\n" + MailBridge.jsBulkMailbox() + "\n" + Self.fakeMail)
        try assertNoException(context)
        return context
    }

    private func assertNoException(_ context: JSContext) throws {
        if let exception = context.exception {
            throw ScriptFailure(message: exception.toString())
        }
    }

    private struct ScriptFailure: Error { let message: String }

    /// Evaluates `expression`, which must produce a JSON string, in the helper context.
    private func json(_ expression: String) throws -> Any {
        let context = try makeContext()
        return try json(expression, in: context)
    }

    private func json(_ expression: String, in context: JSContext) throws -> Any {
        let value = context.evaluateScript(expression)
        try assertNoException(context)
        let text = try XCTUnwrap(value?.toString())
        return try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
    }

    private struct Run {
        let results: [[String: Any]]
        let meta: [String: Any]
        let context: JSContext

        var ids: [String] { results.map { $0["id"] as? String ?? "?" } }

        func reads(_ key: String) throws -> [Any] {
            let text = try XCTUnwrap(context.evaluateScript("JSON.stringify(__reads.\(key))")?.toString())
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any])
        }

        func readIds(_ key: String) throws -> [Int] {
            try reads(key).compactMap { $0 as? Int }
        }

        var materializations: Int32 { context.evaluateScript("__reads.materialized").toInt32() }
    }

    /// Runs a full generated script against `accounts`, a JS expression.
    private func execute(_ script: String, accounts: String) throws -> Run {
        let context = try makeContext()
        context.evaluateScript("var __accounts = \(accounts);")
        try assertNoException(context)
        let object = try XCTUnwrap(json(script, in: context) as? [String: Any])
        return try Run(
            results: XCTUnwrap(object["results"] as? [[String: Any]]),
            meta: XCTUnwrap(object["meta"] as? [String: Any]),
            context: context
        )
    }

    private func oneAccount(_ rows: String, opts: String = "{}") -> String {
        "[fakeAccount('A', [fakeMailbox('INBOX', \(rows), \(opts))])]"
    }

    private func listScript(limit: Int = 10, offset: Int = 0, preview: Int? = nil, unread: Bool = false, softTimeoutMs: Int = 10000) -> String {
        MailBridge.buildListScript(
            account: nil, mailbox: "INBOX", unread: unread, limit: limit, offset: offset, preview: preview, softTimeoutMs: softTimeoutMs
        )
    }

    private func activityScript(limit: Int = 10, preview: Int? = nil, mailboxes: [String] = ["INBOX"]) -> String {
        MailBridge.buildActivityScript(account: nil, mailboxes: mailboxes, since: nil, limit: limit, preview: preview, softTimeoutMs: 10000)
    }

    private func searchScript(
        query: String = "subject", searchBody: Bool = false, limit: Int = 10, after: String? = nil, to: String? = nil, from: String? = nil
    ) -> String {
        MailBridge.buildSearchScript(
            query: query, account: nil, searchBody: searchBody, limit: limit, after: after, to: to, from: from, softTimeoutMs: 10000
        )
    }

    // MARK: - Message-ID on rows (RC-19)

    func testEveryScanScriptEmitsTheRFCMessageIdOnItsRows() throws {
        for script in [listScript(), activityScript(), searchScript()] {
            let run = try execute(script, accounts: oneAccount("__rows"))
            XCTAssertEqual(run.results.count, 2)
            XCTAssertEqual(
                Set(run.results.compactMap { $0["messageIdHeader"] as? String }), ["mid-1", "mid-2"]
            )
        }
    }

    // MARK: - bulkMailbox

    func testBulkMailboxReturnsPopulatedObjectForAlignedArrays() throws {
        let b = try XCTUnwrap(json("JSON.stringify(bulkMailbox(fakeMailbox('INBOX', __rows)))") as? [String: Any])
        XCTAssertEqual(b["ids"] as? [Int], [1, 2])
        XCTAssertEqual(b["subject"] as? [String], ["subject 1", "subject 2"])
        XCTAssertEqual(b["sender"] as? [String], ["sender@example.com", "sender@example.com"])
        XCTAssertEqual(b["read"] as? [Bool], [false, false])
        XCTAssertEqual(b["size"] as? [Int], [101, 102])
        XCTAssertEqual((b["received"] as? [Any])?.count, 2)
        XCTAssertEqual((b["sent"] as? [Any])?.count, 2)
    }

    func testBulkMailboxReturnsNullWhenAnyPropertyArrayHasDifferentLength() throws {
        for property in ["dateReceived", "dateSent", "readStatus", "subject", "sender", "messageSize"] {
            let result = try json("""
            JSON.stringify(bulkMailbox(fakeMailbox('INBOX', __rows, {overrides: {\(property): function() { return ['only one']; }}})))
            """)
            XCTAssertTrue(result is NSNull, "\(property) with a short array must reject the read")
        }
    }

    func testBulkMailboxReturnsNullWhenIdsChangeBetweenReads() throws {
        let result = try json("""
        var calls = 0;
        JSON.stringify(bulkMailbox(fakeMailbox('INBOX', __rows, {overrides: {id: function() { calls++; return calls === 1 ? [1, 2] : [1, 3]; }}})))
        """)
        XCTAssertTrue(result is NSNull)
    }

    func testBulkMailboxReturnsNullWhenIdCountChangesBetweenReads() throws {
        let result = try json("""
        var calls = 0;
        JSON.stringify(bulkMailbox(fakeMailbox('INBOX', __rows, {overrides: {id: function() { calls++; return calls === 1 ? [1, 2] : [1, 2, 3]; }}})))
        """)
        XCTAssertTrue(result is NSNull)
    }

    func testBulkMailboxReturnsNullWhenGetterThrows() throws {
        let result = try json("""
        JSON.stringify(bulkMailbox(fakeMailbox('INBOX', __rows, {overrides: {sender: function() { throw new Error('AppleEvent failed'); }}})))
        """)
        XCTAssertTrue(result is NSNull)
    }

    // MARK: - bulkDates

    private func bulkDates(received: String, sent: String) throws -> [String: Any] {
        try XCTUnwrap(json("""
        var d = bulkDates({received: [\(received)], sent: [\(sent)]}, 0);
        JSON.stringify(d)
        """) as? [String: Any])
    }

    func testBulkDatesPrefersReceivedForOperationalDate() throws {
        let d = try bulkDates(received: "new Date('2026-01-05T00:00:00Z')", sent: "new Date('2026-01-01T00:00:00Z')")
        XCTAssertEqual(d["operationalDate"] as? String, "2026-01-05T00:00:00.000Z")
        XCTAssertEqual(d["sentDate"] as? String, "2026-01-01T00:00:00.000Z")
    }

    func testBulkDatesFallsBackToSentWhenReceivedIsNull() throws {
        let d = try bulkDates(received: "null", sent: "new Date('2026-01-01T00:00:00Z')")
        XCTAssertTrue(d["receivedDate"] is NSNull)
        XCTAssertEqual(d["operationalDate"] as? String, "2026-01-01T00:00:00.000Z")
    }

    func testBulkDatesTreatsEpochZeroAndInvalidReceivedAsAbsent() throws {
        for absent in ["new Date(0)", "new Date(NaN)"] {
            let d = try bulkDates(received: absent, sent: "new Date('2026-01-01T00:00:00Z')")
            XCTAssertTrue(d["receivedDate"] is NSNull, absent)
            XCTAssertEqual(d["operationalDate"] as? String, "2026-01-01T00:00:00.000Z", absent)
        }
    }

    func testBulkDatesHasNoOperationalDateWhenBothAreAbsent() throws {
        let d = try bulkDates(received: "new Date(0)", sent: "new Date(NaN)")
        XCTAssertTrue(d["sentDate"] is NSNull)
        XCTAssertTrue(d["operationalDate"] is NSNull)
    }

    // MARK: - messageAt

    private func messageAtId(opts: String) throws -> Any {
        try json("""
        var mb = fakeMailbox('INBOX', __rows, \(opts));
        var m = messageAt(mb, bulkMailbox(mb), 1);
        JSON.stringify(m === null ? null : m.id())
        """)
    }

    func testMessageAtReturnsElementWhenIdMatches() throws {
        XCTAssertEqual(try messageAtId(opts: "{}") as? Int, 2)
    }

    func testMessageAtReturnsNullWhenElementIdNoLongerMatches() throws {
        let opts = "{materialized: function(msgs) { return [msgs[1], msgs[0]]; }}"
        XCTAssertTrue(try messageAtId(opts: opts) is NSNull)
    }

    func testMessageAtReturnsNullWhenMaterializedLengthDiffers() throws {
        let opts = "{materialized: function(msgs) { return msgs.concat(msgs[0]); }}"
        XCTAssertTrue(try messageAtId(opts: opts) is NSNull)
    }

    func testMessageAtMaterializesMailboxOnlyOnce() throws {
        let count = try json("""
        var mb = fakeMailbox('INBOX', __rows);
        var b = bulkMailbox(mb);
        messageAt(mb, b, 0); messageAt(mb, b, 1);
        JSON.stringify(__reads.materialized)
        """)
        XCTAssertEqual(count as? Int, 1)
    }

    // MARK: - newestFirstThenRowId

    func testNewestFirstThenRowIdOrdersNewestFirstAndBreaksTiesByAscendingRowId() throws {
        let order = try json("""
        var rows = [
            {opIso: '2026-01-01T00:00:00.000Z', rowId: 1},
            {opIso: '2026-01-03T00:00:00.000Z', rowId: 10},
            {opIso: '2026-01-03T00:00:00.000Z', rowId: 2},
            {opIso: '2026-01-02T00:00:00.000Z', rowId: 7}
        ];
        rows.sort(newestFirstThenRowId);
        JSON.stringify(rows.map(function(r) { return r.rowId; }))
        """)
        XCTAssertEqual(order as? [Int], [2, 10, 7, 1])
    }

    // MARK: - Page selection precedes per-message reads

    private let fourDays = """
    [{id: 1, received: '2026-01-01T00:00:00Z'}, {id: 2, received: '2026-01-02T00:00:00Z'},
     {id: 3, received: '2026-01-03T00:00:00Z'}, {id: 4, received: '2026-01-04T00:00:00Z'}]
    """

    func testListReadsContentAndAttachmentsOnlyForSelectedPage() throws {
        let run = try execute(listScript(limit: 1, offset: 1, preview: 50), accounts: oneAccount(fourDays))
        XCTAssertEqual(run.ids, ["A||INBOX||3"])
        XCTAssertEqual(try run.readIds("content"), [3])
        XCTAssertEqual(try run.readIds("attachments"), [3])
        XCTAssertEqual(run.results[0]["bodyPreview"] as? String, "body 3")
        XCTAssertEqual(run.results[0]["hasAttachment"] as? Bool, false)
        XCTAssertEqual(run.results[0]["size"] as? Int, 103)
    }

    func testActivityReadsContentOnlyForSelectedPage() throws {
        let run = try execute(activityScript(limit: 2, preview: 50), accounts: oneAccount(fourDays))
        XCTAssertEqual(run.ids, ["A||INBOX||4", "A||INBOX||3"])
        XCTAssertEqual(try run.readIds("content"), [4, 3])
    }

    func testSearchWithoutBodyNeverReadsContentAndStopsPerMessageReadsAtPage() throws {
        let run = try execute(searchScript(limit: 1), accounts: oneAccount(fourDays))
        XCTAssertEqual(run.ids, ["A||INBOX||4"])
        XCTAssertEqual(try run.readIds("content"), [])
        XCTAssertEqual(try run.readIds("attachments"), [4])
    }

    func testNoScriptLeaksInternalMessageHandle() throws {
        for script in [listScript(preview: 50), activityScript(preview: 50), searchScript()] {
            let run = try execute(script, accounts: oneAccount(fourDays))
            XCTAssertEqual(run.results.count, 4)
            for row in run.results {
                XCTAssertNil(row["__msg"], "\(row)")
            }
        }
    }

    // MARK: - Ordering and dates

    func testListSortsAcrossAccountsThenPaginates() throws {
        let accounts = """
        [fakeAccount('A', [fakeMailbox('INBOX', [{id: 10, received: '2026-01-02T00:00:00Z'}, {id: 1, received: '2026-01-01T00:00:00Z'}])]),
         fakeAccount('B', [fakeMailbox('INBOX', [{id: 2, received: '2026-01-02T00:00:00Z'}, {id: 3, received: '2026-01-03T00:00:00Z'}])])]
        """
        let run = try execute(listScript(limit: 2, offset: 1), accounts: accounts)
        XCTAssertEqual(run.ids, ["B||INBOX||2", "A||INBOX||10"], "numeric rowId tie break puts 2 before 10")
    }

    func testListUnreadExcludesReadMessages() throws {
        let rows = "[{id: 1, received: '2026-01-01T00:00:00Z', read: true}, {id: 2, received: '2026-01-02T00:00:00Z'}]"
        let run = try execute(listScript(unread: true), accounts: oneAccount(rows))
        XCTAssertEqual(run.ids, ["A||INBOX||2"])
    }

    func testAllScriptsOrderByReceivedWithSentFallbackAndSkipUndated() throws {
        let rows = """
        [{id: 1, received: '2026-01-05T00:00:00Z', sent: '2026-01-01T00:00:00Z'},
         {id: 2, received: null, sent: '2026-01-03T00:00:00Z'},
         {id: 3, received: '1970-01-01T00:00:00Z', sent: null}]
        """
        for script in [listScript(), activityScript(), searchScript()] {
            let run = try execute(script, accounts: oneAccount(rows))
            XCTAssertEqual(run.ids, ["A||INBOX||1", "A||INBOX||2"])
            XCTAssertEqual(run.results[0]["date"] as? String, "2026-01-01T00:00:00.000Z", "date stays the sent time")
            XCTAssertEqual(run.results[0]["receivedAt"] as? String, "2026-01-05T00:00:00.000Z")
            XCTAssertEqual(run.results[1]["date"] as? String, "2026-01-03T00:00:00.000Z")
            XCTAssertTrue(run.results[1]["receivedAt"] is NSNull)
        }
    }

    func testActivityUsesReceivedAsDateWhenSentIsMissing() throws {
        let rows = "[{id: 1, received: '2026-01-05T00:00:00Z', sent: null}]"
        let run = try execute(activityScript(), accounts: oneAccount(rows))
        XCTAssertEqual(run.results[0]["date"] as? String, "2026-01-05T00:00:00.000Z")
    }

    // MARK: - Soft timeout

    /// Past the 8000 ms scan budget for a 10000 ms soft timeout, but not past the timeout.
    private let pastScanBudget = "{onBulk: function() { __clock += 9000; }}"
    private let pastSoftTimeout = "{onBulk: function() { __clock += 20000; }}"

    func testListScanStopsAtBudgetBetweenAccounts() throws {
        let accounts = "[fakeAccount('A', [fakeMailbox('INBOX', __rows, \(pastScanBudget))]), fakeAccount('B', [fakeMailbox('Second', __rows)])]"
        let run = try execute(listScript(), accounts: accounts)
        XCTAssertEqual(try run.reads("bulk") as? [String], ["INBOX"], "second account must not be scanned")
        XCTAssertEqual(run.meta["timedOut"] as? Bool, true)
        XCTAssertEqual(run.ids, ["A||INBOX||2", "A||INBOX||1"], "rows already scanned are still returned")
    }

    func testSearchAndActivityScanStopAtBudgetBetweenMailboxes() throws {
        let accounts = "[fakeAccount('A', [fakeMailbox('INBOX', __rows, \(pastScanBudget)), fakeMailbox('Second', __rows)])]"
        for script in [searchScript(), activityScript(mailboxes: ["INBOX", "Second"])] {
            let run = try execute(script, accounts: accounts)
            XCTAssertEqual(try run.reads("bulk") as? [String], ["INBOX"])
            XCTAssertEqual(run.meta["timedOut"] as? Bool, true)
        }
    }

    func testPerMessageLoopReturnsMetadataOnlyRowsAfterSoftTimeout() throws {
        for script in [listScript(preview: 50), activityScript(preview: 50), searchScript()] {
            let run = try execute(script, accounts: oneAccount("__rows", opts: pastSoftTimeout))
            XCTAssertEqual(run.meta["timedOut"] as? Bool, true)
            XCTAssertEqual(run.results.count, 2)
            XCTAssertEqual(run.results[0]["subject"] as? String, "subject 2")
            XCTAssertTrue(run.results[0]["hasAttachment"] is NSNull, "null means the read was skipped, not false")
            XCTAssertEqual(try run.readIds("content"), [])
            XCTAssertEqual(try run.readIds("attachments"), [])
            XCTAssertEqual(run.materializations, 0)
        }
    }

    func testListStopsPerMessageReadsWhenTimeoutFiresMidPage() throws {
        // The first row's attachment read crosses the limit, so the second row is metadata only.
        let opts = "{materialized: function(msgs) { msgs.forEach(function(m) { var a = m.mailAttachments; m.mailAttachments = function() { __clock += 20000; return a(); }; }); return msgs; }}"
        let run = try execute(listScript(), accounts: oneAccount("__rows", opts: opts))
        XCTAssertEqual(run.results.count, 2)
        XCTAssertEqual(run.results[0]["hasAttachment"] as? Bool, false)
        XCTAssertTrue(run.results[1]["hasAttachment"] is NSNull)
        XCTAssertEqual(run.meta["timedOut"] as? Bool, true)
    }

    // MARK: - Search filters

    func testSearchToFilterExcludesNonRecipientsWithoutSpendingThePage() throws {
        let rows = """
        [{id: 1, received: '2026-01-01T00:00:00Z', to: ['Bob@Example.com']},
         {id: 2, received: '2026-01-02T00:00:00Z', to: ['alice@example.com']}]
        """
        let run = try execute(searchScript(limit: 1, to: "bob@"), accounts: oneAccount(rows))
        XCTAssertEqual(run.ids, ["A||INBOX||1"])
        XCTAssertEqual(run.results[0]["to"] as? [String], ["Bob@Example.com"])
    }

    func testSearchToFilterReturnsNothingUnverifiedAfterSoftTimeout() throws {
        let rows = "[{id: 1, received: '2026-01-01T00:00:00Z', to: ['bob@example.com']}]"
        let run = try execute(searchScript(to: "bob@"), accounts: oneAccount(rows, opts: pastSoftTimeout))
        XCTAssertEqual(run.results.count, 0, "a recipient filter cannot be honored without reading recipients")
        XCTAssertEqual(run.meta["timedOut"] as? Bool, true)
    }

    func testSearchBodyFetchesOnlyUnmatchedInRangeMessagesAndCapturesPreview() throws {
        let rows = """
        [{id: 1, received: '2025-01-01T00:00:00Z', subject: 'old', body: 'needle'},
         {id: 2, received: '2026-01-02T00:00:00Z', subject: 'needle in subject'},
         {id: 3, received: '2026-01-03T00:00:00Z', subject: 'plain', body: 'has needle inside'},
         {id: 4, received: '2026-01-04T00:00:00Z', subject: 'plain', body: 'nothing'},
         {id: 5, received: '2026-01-05T00:00:00Z', subject: 'plain', body: 'needle', sender: 'other@example.com'}]
        """
        let run = try execute(
            searchScript(query: "needle", searchBody: true, after: "2026-01-01", from: "sender@"),
            accounts: oneAccount(rows)
        )
        XCTAssertEqual(run.ids, ["A||INBOX||3", "A||INBOX||2"])
        XCTAssertEqual(try run.readIds("content"), [4, 3], "date and sender filters and subject hits avoid content()")
        XCTAssertEqual(run.results[0]["bodyPreview"] as? String, "has needle inside")
        XCTAssertTrue(run.results[1]["bodyPreview"] is NSNull)
    }

    func testSearchBoundsBodyFetchesButNotMetadataMatches() throws {
        let rows = """
        (function() {
            var rows = [{id: 1, received: '2020-01-01T00:00:00Z', subject: 'needle'}];
            for (var i = 2; i <= 600; i++) rows.push({id: i, received: new Date(1767225600000 + i * 1000).toISOString(), subject: 'plain', body: 'nope'});
            return rows;
        })()
        """
        let run = try execute(searchScript(query: "needle", searchBody: true), accounts: oneAccount(rows))
        XCTAssertEqual(run.ids, ["A||INBOX||1"], "metadata match in the oldest row is still reachable")
        XCTAssertEqual(try run.readIds("content").count, 500)
    }

    // MARK: - Dedupe

    private let duplicated = """
    [fakeAccount('A', [fakeMailbox('INBOX', [{id: 1, received: '2026-01-01T00:00:00Z', messageId: 'same'}]),
                       fakeMailbox('All Mail', [{id: 2, received: '2026-01-02T00:00:00Z', messageId: 'same'}])])]
    """

    func testSearchAndActivityDedupeByMessageId() throws {
        for script in [searchScript(), activityScript(mailboxes: ["INBOX", "All Mail"])] {
            let run = try execute(script, accounts: duplicated)
            XCTAssertEqual(run.ids, ["A||All Mail||2"], "newest copy wins")
        }
    }

    func testSearchAndActivityDedupeHeaderlessMailByOperationalTimestamp() throws {
        let accounts = """
        [fakeAccount('A', [fakeMailbox('INBOX', [{id: 1, received: '2026-01-01T00:00:00Z', subject: 's', messageId: null}]),
                           fakeMailbox('All Mail', [{id: 2, received: '2026-01-01T00:00:00Z', subject: 's', messageId: null}])])]
        """
        for script in [searchScript(query: "s"), activityScript(mailboxes: ["INBOX", "All Mail"])] {
            let run = try execute(script, accounts: accounts)
            XCTAssertEqual(run.results.count, 1)
        }
    }

    // MARK: - Failures stay partial, never silently empty

    func testMailboxDriftKeepsBulkRowsAndMarksPartial() throws {
        let drifted = "{materialized: function(all) { return all.concat(all[0]); }}"
        let rows = "__rows"
        for script in [listScript(), activityScript(), searchScript()] {
            let run = try execute(script, accounts: oneAccount(rows, opts: drifted))
            XCTAssertEqual(run.results.count, 2)
            XCTAssertEqual(run.meta["timedOut"] as? Bool, true)
            XCTAssertTrue(run.results.allSatisfy { $0["hasAttachment"] is NSNull || $0["hasAttachment"] == nil })
        }
    }

    func testRecipientFilterCannotPassUnverifiedRowsWhenMailboxDrifts() throws {
        let drifted = "{materialized: function(all) { return all.concat(all[0]); }}"
        let run = try execute(searchScript(to: "x@example.com"), accounts: oneAccount("__rows", opts: drifted))
        XCTAssertEqual(run.results.count, 0)
        XCTAssertEqual(run.meta["timedOut"] as? Bool, true)
    }

    func testUnreadableMailboxOnlySkipsItself() throws {
        let accounts = """
        [fakeAccount('A', [
            fakeMailbox('Broken', __rows, {overrides: {subject: function() { throw new Error('boom'); }}}),
            fakeMailbox('Good', __rows)
        ])]
        """
        let run = try execute(searchScript(), accounts: accounts)
        XCTAssertEqual(run.results.count, 2)
        XCTAssertTrue(run.ids.allSatisfy { $0.contains("||Good||") })
        XCTAssertEqual(run.meta["timedOut"] as? Bool, true)
    }

    func testBodyReadFailureDoesNotAbortTheScan() throws {
        let rows = "[{id: 1, received: '2026-01-02T00:00:00Z', body: 'needle'}, {id: 2, received: '2026-01-01T00:00:00Z', body: 'needle'}]"
        let throwing = "{materialized: function(all) { all[0].content = function() { throw new Error('imap'); }; return all; }}"
        let run = try execute(searchScript(query: "needle", searchBody: true), accounts: oneAccount(rows, opts: throwing))
        XCTAssertEqual(run.results.count, 1)
        XCTAssertEqual(run.meta["timedOut"] as? Bool, true)
    }

    func testMissingSubjectOrSenderStillDecodes() throws {
        let rows = "[{id: 1, received: '2026-01-02T00:00:00Z', subject: null, sender: null}]"
        let run = try execute(listScript(), accounts: oneAccount(rows))
        XCTAssertEqual(run.results.first?["subject"] as? String, "")
        XCTAssertEqual(run.results.first?["from"] as? String, "")
    }

    func testEmptyMailboxIsNotUnreadable() throws {
        let empty = "{overrides: {id: function() { throw new Error('-1728'); }}}"
        let accounts = "[fakeAccount('A', [fakeMailbox('Empty', [], \(empty)), fakeMailbox('Good', __rows)])]"
        let run = try execute(searchScript(), accounts: accounts)
        XCTAssertEqual(run.results.count, 2)
        XCTAssertEqual(run.meta["timedOut"] as? Bool, false)
    }
}
