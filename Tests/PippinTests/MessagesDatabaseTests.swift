import GRDB
@testable import PippinLib
import XCTest

final class MessagesDatabaseTests: XCTestCase {
    private func makeFixtureDB() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try db.write { db in
            try db.execute(sql: """
            CREATE TABLE chat (
                ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
                guid TEXT UNIQUE,
                chat_identifier TEXT,
                service_name TEXT,
                display_name TEXT,
                room_name TEXT,
                style INTEGER DEFAULT 0,
                is_archived INTEGER DEFAULT 0
            );
            CREATE TABLE handle (
                ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
                id TEXT,
                service TEXT
            );
            CREATE TABLE message (
                ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
                guid TEXT UNIQUE,
                text TEXT,
                date INTEGER,
                handle_id INTEGER DEFAULT 0,
                is_from_me INTEGER DEFAULT 0,
                is_read INTEGER DEFAULT 0,
                service TEXT
            );
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            """)
            try db.execute(sql: """
            INSERT INTO chat (guid, chat_identifier, service_name, display_name, style)
                VALUES ('iMessage;-;+15551234567', '+15551234567', 'iMessage', NULL, 0);
            INSERT INTO chat (guid, chat_identifier, service_name, display_name, style)
                VALUES ('iMessage;-;groupA', 'chat123', 'iMessage', 'Team Group', 43);
            INSERT INTO handle (id, service) VALUES ('+15551234567', 'iMessage');
            INSERT INTO handle (id, service) VALUES ('alice@example.com', 'iMessage');
            INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 1);
            INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (2, 1);
            INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (2, 2);
            """)
            let recent = Date(timeIntervalSince1970: 1_750_000_000) // mid-2025
            let older = recent.addingTimeInterval(-86400 * 30) // 30 days prior
            let recentNs = MessagesDatabase.appleNanos(from: recent)
            let olderNs = MessagesDatabase.appleNanos(from: older)
            try db.execute(
                sql: """
                INSERT INTO message (guid, text, date, handle_id, is_from_me, is_read, service)
                    VALUES ('msg-1', 'Hey, can you call me back?', ?, 1, 0, 0, 'iMessage');
                INSERT INTO message (guid, text, date, handle_id, is_from_me, is_read, service)
                    VALUES ('msg-2', 'Sure thing', ?, 0, 1, 1, 'iMessage');
                INSERT INTO message (guid, text, date, handle_id, is_from_me, is_read, service)
                    VALUES ('msg-3', 'Team lunch Friday?', ?, 2, 0, 1, 'iMessage');
                INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 1);
                INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 2);
                INSERT INTO chat_message_join (chat_id, message_id) VALUES (2, 3);
                """,
                arguments: [recentNs, recentNs - 1_000_000_000, olderNs]
            )
        }
        return db
    }

    // MARK: - List

    func testListConversationsReturnsAllByDefault() throws {
        let db = try MessagesDatabase(dbQueue: makeFixtureDB())
        let (conversations, excluded) = try db.listConversations(limit: 50)
        XCTAssertEqual(conversations.count, 2)
        XCTAssertEqual(excluded, 0)
    }

    func testListConversationsOrdersByLastMessageDesc() throws {
        let db = try MessagesDatabase(dbQueue: makeFixtureDB())
        let (conversations, _) = try db.listConversations(limit: 50)
        XCTAssertEqual(conversations.first?.id, "iMessage;-;+15551234567")
    }

    func testListConversationsFiltersExclude() throws {
        let db = try MessagesDatabase(dbQueue: makeFixtureDB())
        let (conversations, excluded) = try db.listConversations(
            limit: 50,
            excluded: ["iMessage;-;groupA"]
        )
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(excluded, 1)
        XCTAssertEqual(conversations.first?.id, "iMessage;-;+15551234567")
    }

    func testListConversationsMarksGroupChat() throws {
        let db = try MessagesDatabase(dbQueue: makeFixtureDB())
        let (conversations, _) = try db.listConversations(limit: 50)
        let groupChat = conversations.first { $0.id == "iMessage;-;groupA" }
        XCTAssertEqual(groupChat?.isGroup, true)
        XCTAssertEqual(groupChat?.displayName, "Team Group")
        XCTAssertEqual(groupChat?.participants.count, 2)
    }

    func testListConversationsCountsUnread() throws {
        let db = try MessagesDatabase(dbQueue: makeFixtureDB())
        let (conversations, _) = try db.listConversations(limit: 50)
        let dm = conversations.first { $0.id == "iMessage;-;+15551234567" }
        XCTAssertEqual(dm?.unreadCount, 1)
    }

    // MARK: - Search

    func testSearchMatchesSubstring() throws {
        let db = try MessagesDatabase(dbQueue: makeFixtureDB())
        let (matches, excluded) = try db.searchMessages(query: "lunch", limit: 50)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(excluded, 0)
        XCTAssertEqual(matches.first?.text, "Team lunch Friday?")
    }

    func testSearchFiltersExclude() throws {
        let db = try MessagesDatabase(dbQueue: makeFixtureDB())
        let (matches, excluded) = try db.searchMessages(
            query: "lunch",
            limit: 50,
            excluded: ["iMessage;-;groupA"]
        )
        XCTAssertEqual(matches.count, 0)
        XCTAssertEqual(excluded, 1)
    }

    func testSearchEscapesLikeMetachars() throws {
        // A query containing `%` must be treated as a literal character, not
        // as a LIKE wildcard — otherwise "100%" would match everything.
        let fixture = try DatabaseQueue()
        try fixture.write { db in
            try db.execute(sql: """
            CREATE TABLE chat (
                ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
                guid TEXT UNIQUE,
                service_name TEXT,
                display_name TEXT,
                room_name TEXT,
                style INTEGER DEFAULT 0,
                is_archived INTEGER DEFAULT 0
            );
            CREATE TABLE message (
                ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
                guid TEXT UNIQUE,
                text TEXT,
                date INTEGER,
                handle_id INTEGER DEFAULT 0,
                is_from_me INTEGER DEFAULT 0,
                is_read INTEGER DEFAULT 0,
                service TEXT
            );
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT, service TEXT);
            """)
            let ns = MessagesDatabase.appleNanos(from: Date())
            try db.execute(sql: """
            INSERT INTO chat (guid, service_name, display_name, style)
                VALUES ('chat-1', 'iMessage', 'Test', 0);
            INSERT INTO message (guid, text, date, is_from_me, is_read, service)
                VALUES ('m1', '100% complete', ?, 0, 1, 'iMessage');
            INSERT INTO message (guid, text, date, is_from_me, is_read, service)
                VALUES ('m2', 'no match here', ?, 0, 1, 'iMessage');
            INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 1);
            INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 2);
            """, arguments: [ns, ns - 1])
        }
        let db = try MessagesDatabase(dbQueue: fixture)
        let (matches, _) = try db.searchMessages(query: "100%", limit: 50)
        // Must match exactly the message whose text contains the literal "100%"
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.text, "100% complete")
    }

    func testSearchExcludesArchivedChats() throws {
        // Messages in archived conversations must not surface in search results.
        let fixture = try DatabaseQueue()
        try fixture.write { db in
            try db.execute(sql: """
            CREATE TABLE chat (
                ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
                guid TEXT UNIQUE,
                service_name TEXT,
                display_name TEXT,
                room_name TEXT,
                style INTEGER DEFAULT 0,
                is_archived INTEGER DEFAULT 0
            );
            CREATE TABLE message (
                ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
                guid TEXT UNIQUE,
                text TEXT,
                date INTEGER,
                handle_id INTEGER DEFAULT 0,
                is_from_me INTEGER DEFAULT 0,
                is_read INTEGER DEFAULT 0,
                service TEXT
            );
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT, service TEXT);
            """)
            let ns = MessagesDatabase.appleNanos(from: Date())
            try db.execute(sql: """
            INSERT INTO chat (guid, service_name, display_name, style, is_archived)
                VALUES ('active-chat', 'iMessage', 'Active', 0, 0);
            INSERT INTO chat (guid, service_name, display_name, style, is_archived)
                VALUES ('archived-chat', 'iMessage', 'Archived', 0, 1);
            INSERT INTO message (guid, text, date, is_from_me, is_read, service)
                VALUES ('m-active', 'hello world from active', ?, 0, 1, 'iMessage');
            INSERT INTO message (guid, text, date, is_from_me, is_read, service)
                VALUES ('m-archived', 'hello world from archived', ?, 0, 1, 'iMessage');
            INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 1);
            INSERT INTO chat_message_join (chat_id, message_id) VALUES (2, 2);
            """, arguments: [ns, ns - 1])
        }
        let db = try MessagesDatabase(dbQueue: fixture)
        let (matches, _) = try db.searchMessages(query: "hello world", limit: 50)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.id, "m-active")
    }

    // MARK: - Show

    func testShowReturnsThreadMessages() throws {
        let db = try MessagesDatabase(dbQueue: makeFixtureDB())
        let (conversation, messages, truncated) = try db.showConversation(
            conversationId: "iMessage;-;+15551234567",
            limit: 50
        )
        XCTAssertEqual(conversation.id, "iMessage;-;+15551234567")
        XCTAssertEqual(messages.count, 2)
        XCTAssertFalse(truncated)
    }

    func testShowThrowsForUnknownConversation() {
        XCTAssertThrowsError(try MessagesDatabase(dbQueue: makeFixtureDB())
            .showConversation(conversationId: "nonexistent", limit: 10))
        { error in
            if case let MessagesError.conversationNotFound(id) = error {
                XCTAssertEqual(id, "nonexistent")
            } else {
                XCTFail("expected conversationNotFound, got \(error)")
            }
        }
    }

    // MARK: - Epoch conversion

    func testAppleNanosRoundTripsDate() {
        let date = Date(timeIntervalSince1970: 1_700_000_000) // Nov 2023
        let nanos = MessagesDatabase.appleNanos(from: date)
        let roundTripped = MessagesDatabase.date(fromAppleNanos: nanos)
        XCTAssertEqual(roundTripped.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1)
    }

    func testLegacySecondsEpochDecodes() {
        // Pre-macOS-10.13 rows stored seconds, not nanoseconds. Magnitude < 10^12.
        let secondsValue: Int64 = 500_000_000 // roughly 2016
        let date = MessagesDatabase.date(fromAppleNanos: secondsValue)
        let year = Calendar(identifier: .gregorian).dateComponents([.year], from: date).year
        XCTAssertNotNil(year)
        XCTAssertGreaterThan(year ?? 0, 2010)
    }

    // MARK: - Preview

    func testPreviewTruncatesLongText() {
        let long = String(repeating: "x", count: 500)
        let result = MessagesDatabase.preview(long, limit: 50)
        XCTAssertEqual(result.count, 50) // limit-1 chars + ellipsis
        XCTAssertTrue(result.hasSuffix("…"))
    }

    func testPreviewCollapsesNewlines() {
        let result = MessagesDatabase.preview("line1\nline2\nline3")
        XCTAssertFalse(result.contains("\n"))
    }

    // MARK: - escapeLike

    func testEscapeLikeEscapesPercent() {
        XCTAssertEqual(MessagesDatabase.escapeLike("100%"), "100\\%")
    }

    func testEscapeLikeEscapesUnderscore() {
        XCTAssertEqual(MessagesDatabase.escapeLike("file_name"), "file\\_name")
    }

    func testEscapeLikeEscapesBackslash() {
        XCTAssertEqual(MessagesDatabase.escapeLike("path\\to"), "path\\\\to")
    }

    func testEscapeLikePassesThroughNormalText() {
        XCTAssertEqual(MessagesDatabase.escapeLike("hello world"), "hello world")
    }
}
