import GRDB
@testable import PippinLib
import XCTest

/// The exclude list hides a thread from every read: list, search and show.
/// Runs the real commands against a fixture chat.db and a temp config.
final class MessagesExcludeEnforcementTests: XCTestCase {
    private var sandbox: MessagesCommandSandbox!

    private static let dm = "iMessage;-;+15551234567"
    private static let group = "iMessage;-;groupA"

    override func setUpWithError() throws {
        sandbox = try MessagesCommandSandbox()
    }

    override func tearDown() {
        sandbox.tearDown()
    }

    private func exclude(_ threads: [String]) throws {
        let list = threads.map { "\"\($0)\"" }.joined(separator: ",")
        try sandbox.writeConfig(#"{"messages":{"excludedThreads":[\#(list)]}}"#)
    }

    private func show(_ id: String) async throws -> MessagesShowResult {
        var cmd = try MessagesCommand.Show.parse([id, "--no-contacts"])
        let result = try await cmd.execute()
        return try XCTUnwrap(result.payload as? MessagesShowResult)
    }

    private func assertShowFails(
        _ id: String, code: String, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            let result = try await show(id)
            XCTFail("show \(id) returned \(result.messages.count) message(s)", file: file, line: line)
        } catch {
            XCTAssertEqual(agentErrorCode(for: error), code, "\(error)", file: file, line: line)
        }
    }

    // MARK: - Show

    func testShowReturnsThreadWhenNothingIsExcluded() async throws {
        let result = try await show(Self.group)
        XCTAssertEqual(result.messages.map(\.id), ["msg-3"])
    }

    func testShowRefusesExcludedGuid() async throws {
        try exclude([Self.group])
        await assertShowFails(Self.group, code: "conversation_excluded")
    }

    func testShowRefusesExcludedThreadReachedByBareHandle() async throws {
        // The bare number resolves through chat_identifier, not the guid.
        try exclude([Self.dm])
        await assertShowFails("+15551234567", code: "conversation_excluded")
    }

    func testShowRefusesExcludedThreadReachedByMaskedId() async throws {
        try exclude([Self.dm])
        await assertShowFails("iMessage;-;+1555***4567", code: "conversation_excluded")
    }

    func testShowRefusesWhenExcludeEntryNamesTheIdentifier() async throws {
        try exclude(["+15551234567"])
        await assertShowFails(Self.dm, code: "conversation_excluded")
    }

    func testShowRefusesWhenExcludeEntryUsesAnotherServicePrefix() async throws {
        // An entry saved as `iMessage;-;<handle>` still hides the thread after
        // macOS renames its guid to `any;-;<handle>`.
        try exclude(["any;-;+15551234567"])
        await assertShowFails(Self.dm, code: "conversation_excluded")
    }

    func testShowStillOpensOtherThreads() async throws {
        try exclude([Self.group])
        let result = try await show(Self.dm)
        XCTAssertEqual(result.conversation.id, Self.dm)
        XCTAssertEqual(result.messages.count, 2)
    }

    // MARK: - List and search

    private func listIds() async throws -> (ids: [String], warnings: [String]) {
        var cmd = try MessagesCommand.List.parse(["--since-hours", "1000000", "--no-contacts"])
        let result = try await cmd.execute()
        let rows = try XCTUnwrap(result.payload as? [MessageConversation])
        return (rows.map(\.id), result.warnings ?? [])
    }

    private func search(_ query: String) async throws -> MessagesSearchResult {
        var cmd = try MessagesCommand.Search.parse([query, "--since-hours", "1000000", "--no-contacts"])
        let result = try await cmd.execute()
        return try XCTUnwrap(result.payload as? MessagesSearchResult)
    }

    func testListHidesExcludedThread() async throws {
        let before = try await listIds()
        XCTAssertEqual(Set(before.ids), [Self.dm, Self.group], "fixture lists both threads")
        try exclude([Self.group])
        let after = try await listIds()
        XCTAssertEqual(after.ids, [Self.dm])
        XCTAssertEqual(after.warnings, ["1 conversation(s) filtered by exclude list"])
    }

    func testListHidesThreadExcludedByIdentifier() async throws {
        try exclude(["chat123"])
        let after = try await listIds()
        XCTAssertEqual(after.ids, [Self.dm])
    }

    func testSearchHidesExcludedThread() async throws {
        let before = try await search("lunch")
        XCTAssertEqual(before.matches.map(\.id), ["msg-3"], "fixture matches before excluding")
        try exclude([Self.group])
        let after = try await search("lunch")
        XCTAssertTrue(after.matches.isEmpty)
        XCTAssertEqual(after.excludedCount, 1)
    }

    func testSearchHidesThreadExcludedByIdentifier() async throws {
        try exclude(["chat123"])
        let after = try await search("lunch")
        XCTAssertTrue(after.matches.isEmpty)
        XCTAssertEqual(after.excludedCount, 1)
    }

    // MARK: - Id lookup (database layer)

    private func makeAmbiguousDB() throws -> MessagesDatabase {
        let queue = try MessagesFixture.emptySchema()
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO chat (guid, chat_identifier, service_name) VALUES ('any;-;+15551112328', '+15551112328', 'iMessage');
            INSERT INTO chat (guid, chat_identifier, service_name) VALUES ('any;-;+15559992328', '+15559992328', 'iMessage');
            INSERT INTO chat (guid, chat_identifier, service_name) VALUES ('iMessage;-;+15550001111', '+15550001111', 'iMessage');
            INSERT INTO chat (guid, chat_identifier, service_name) VALUES ('SMS;-;+15550001111', '+15550001111', 'SMS');
            """)
        }
        return MessagesDatabase(dbQueue: queue)
    }

    private func assertLookupFails(
        _ db: MessagesDatabase, _ id: String, code: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try db.showConversation(conversationId: id), file: file, line: line) { error in
            XCTAssertEqual(agentErrorCode(for: error), code, "\(error)", file: file, line: line)
        }
    }

    func testMaskedIdMatchingTwoThreadsIsAmbiguousNotFirstMatch() throws {
        try assertLookupFails(makeAmbiguousDB(), "any;-;+1555***2328", code: "ambiguous_conversation")
    }

    func testMaskedIdMatchingOneThreadResolves() throws {
        let (conversation, _, _) = try makeAmbiguousDB().showConversation(conversationId: "any;-;+1555111****")
        XCTAssertEqual(conversation.id, "any;-;+15551112328")
    }

    func testBareHandleSharedByTwoThreadsIsAmbiguous() throws {
        try assertLookupFails(makeAmbiguousDB(), "+15550001111", code: "ambiguous_conversation")
    }

    func testPercentAndUnderscoreInAnIdAreLiteral() throws {
        let db = try MessagesDatabase(dbQueue: MessagesFixture.standard())
        assertLookupFails(db, "%group*", code: "conversation_not_found")
        assertLookupFails(db, "iMessage;-;group_*", code: "conversation_not_found")
        // The same shapes with only `*` do resolve, so the lookups above failed on the metacharacter.
        let (conversation, _, _) = try db.showConversation(conversationId: "iMessage;-;group*")
        XCTAssertEqual(conversation.id, Self.group)
    }
}
