import GRDB
@testable import PippinLib
import XCTest

final class MessagesDatabaseTests: XCTestCase {
    private func makeEmptySchemaDB() throws -> DatabaseQueue {
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
                attributedBody BLOB,
                date INTEGER,
                handle_id INTEGER DEFAULT 0,
                is_from_me INTEGER DEFAULT 0,
                is_read INTEGER DEFAULT 0,
                service TEXT,
                associated_message_type INTEGER DEFAULT 0
            );
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE attachment (
                ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
                filename TEXT,
                transfer_name TEXT,
                mime_type TEXT
            );
            CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
            """)
        }
        return db
    }

    private func makeFixtureDB() throws -> DatabaseQueue {
        let db = try makeEmptySchemaDB()
        try db.write { db in
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
            // Tapback (reaction) on msg-3, newest row overall and unread. If
            // tapback filtering regresses, this row flips list ordering (group
            // chat jumps first), inflates the group's unread count, leaks into
            // its preview, and matches searches for "lunch"/"Loved".
            try db.execute(
                sql: """
                INSERT INTO message (guid, text, date, handle_id, is_from_me, is_read, service, associated_message_type)
                    VALUES ('msg-tapback', 'Loved "Team lunch Friday?"', ?, 2, 0, 0, 'iMessage', 2000);
                INSERT INTO chat_message_join (chat_id, message_id) VALUES (2, 4);
                """,
                arguments: [recentNs + 2_000_000_000]
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

    // MARK: - Tapback filtering

    func testListSkipsTapbackInPreviewUnreadAndOrdering() throws {
        // The fixture's tapback row is the newest message overall, unread, in
        // the group chat. It must not surface anywhere.
        let db = try MessagesDatabase(dbQueue: makeFixtureDB())
        let (conversations, _) = try db.listConversations(limit: 50)
        XCTAssertEqual(conversations.first?.id, "iMessage;-;+15551234567", "tapback must not bump the group chat's last-message date")
        let group = conversations.first { $0.id == "iMessage;-;groupA" }
        XCTAssertEqual(group?.lastMessagePreview, "Team lunch Friday?", "preview shows the real message, not the tapback")
        XCTAssertEqual(group?.unreadCount, 0, "unread tapback doesn't count as an unread message")
    }

    func testShowExcludesTapbackRows() throws {
        let db = try MessagesDatabase(dbQueue: makeFixtureDB())
        let (_, messages, _) = try db.showConversation(conversationId: "iMessage;-;groupA", limit: 50)
        XCTAssertEqual(messages.map(\.id), ["msg-3"], "tapback row filtered from the thread")
    }

    func testSearchExcludesTapbacks() throws {
        let db = try MessagesDatabase(dbQueue: makeFixtureDB())
        let (matches, _, _) = try db.searchMessages(query: "Loved", limit: 50)
        XCTAssertTrue(matches.isEmpty, "tapback text must not match searches")
    }

    func testRemoveTapbackRowsAlsoExcluded() throws {
        // 3000-range = tapback removal rows.
        let fixture = try makeFixtureDB()
        try fixture.write { db in
            let ns = MessagesDatabase.appleNanos(from: Date(timeIntervalSince1970: 1_750_000_100))
            try db.execute(sql: """
            INSERT INTO message (guid, text, date, is_from_me, is_read, service, associated_message_type)
                VALUES ('msg-untapback', 'Removed a heart from "Team lunch Friday?"', ?, 0, 0, 'iMessage', 3000);
            INSERT INTO chat_message_join (chat_id, message_id) VALUES (2, last_insert_rowid());
            """, arguments: [ns])
        }
        let db = try MessagesDatabase(dbQueue: fixture)
        let (_, messages, _) = try db.showConversation(conversationId: "iMessage;-;groupA", limit: 50)
        XCTAssertEqual(messages.map(\.id), ["msg-3"])
        let (matches, _, _) = try db.searchMessages(query: "Removed a heart", limit: 50)
        XCTAssertTrue(matches.isEmpty)
    }

    // MARK: - Limit clamping (overflow / unbounded-fetch guard)

    //
    // `--limit` is an unbounded CLI option. A negative value makes SQLite treat
    // `LIMIT -1` as *unbounded* (whole-DB fetch into memory); a value near
    // Int.max overflow-traps `limit + 1` (showConversation) and `limit +
    // excluded.count` (list/search). clampLimit normalizes to [0, 100_000].

    func testClampLimitNormalizesExtremes() {
        XCTAssertEqual(MessagesDatabase.clampLimit(50), 50, "normal value passes through")
        XCTAssertEqual(MessagesDatabase.clampLimit(0), 0)
        XCTAssertEqual(MessagesDatabase.clampLimit(-1), 0, "negative clamps to 0, not unbounded")
        XCTAssertEqual(MessagesDatabase.clampLimit(Int.min), 0)
        XCTAssertEqual(MessagesDatabase.clampLimit(Int.max), 100_000, "huge clamps below overflow range")
    }

    func testListConversationsWithIntMaxLimitDoesNotTrap() throws {
        // Regression: `limit + excluded.count` overflow-trapped at Int.max.
        let db = try MessagesDatabase(dbQueue: makeFixtureDB())
        let (conversations, _) = try db.listConversations(limit: Int.max, excluded: ["x"])
        XCTAssertEqual(conversations.count, 2, "huge limit returns all rows, no crash")
    }

    func testSearchMessagesWithIntMaxLimitDoesNotTrap() throws {
        let db = try MessagesDatabase(dbQueue: makeFixtureDB())
        let (matches, _, _) = try db.searchMessages(query: "call", limit: Int.max, excluded: ["x"])
        XCTAssertEqual(matches.count, 1, "huge limit returns matches, no crash")
    }

    func testShowConversationWithIntMaxLimitDoesNotTrap() throws {
        // Regression: showConversation built `arguments: [chatRowId, limit + 1]`,
        // which traps at Int.max.
        let db = try MessagesDatabase(dbQueue: makeFixtureDB())
        let (_, messages, truncated) = try db.showConversation(
            conversationId: "iMessage;-;+15551234567", limit: Int.max
        )
        XCTAssertEqual(messages.count, 2, "both DM messages returned")
        XCTAssertFalse(truncated, "not truncated when limit exceeds message count")
    }

    func testListConversationsWithNegativeLimitReturnsNoneNotUnbounded() throws {
        let db = try MessagesDatabase(dbQueue: makeFixtureDB())
        let (conversations, _) = try db.listConversations(limit: -1)
        XCTAssertEqual(conversations.count, 0, "negative limit → 0 rows (clamped), not an unbounded scan")
    }

    // MARK: - Search

    func testSearchMatchesSubstring() throws {
        let db = try MessagesDatabase(dbQueue: makeFixtureDB())
        let (matches, excluded, scanTruncated) = try db.searchMessages(query: "lunch", limit: 50)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(excluded, 0)
        XCTAssertFalse(scanTruncated, "small fixture is well under the scan cap")
        XCTAssertEqual(matches.first?.text, "Team lunch Friday?")
    }

    func testSearchFiltersExclude() throws {
        let db = try MessagesDatabase(dbQueue: makeFixtureDB())
        let (matches, excluded, _) = try db.searchMessages(
            query: "lunch",
            limit: 50,
            excluded: ["iMessage;-;groupA"]
        )
        XCTAssertEqual(matches.count, 0)
        XCTAssertEqual(excluded, 1)
    }

    func testSearchEscapesLikeMetachars() throws {
        // A query containing `%` must be treated as a literal character, not
        // a LIKE wildcard — otherwise "100%" would match every row.
        let fixture = try makeEmptySchemaDB()
        try fixture.write { db in
            let ns = MessagesDatabase.appleNanos(from: Date())
            try db.execute(sql: """
            INSERT INTO chat (guid, chat_identifier, service_name, display_name, style)
                VALUES ('chat-1', '+15550001111', 'iMessage', 'Test', 0);
            INSERT INTO message (guid, text, date, is_from_me, is_read, service)
                VALUES ('m1', '100% complete', ?, 0, 1, 'iMessage');
            INSERT INTO message (guid, text, date, is_from_me, is_read, service)
                VALUES ('m2', 'no match here', ?, 0, 1, 'iMessage');
            INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 1);
            INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 2);
            """, arguments: [ns, ns - 1])
        }
        let db = try MessagesDatabase(dbQueue: fixture)
        let (matches, _, _) = try db.searchMessages(query: "100%", limit: 50)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.text, "100% complete")
    }

    func testSearchExcludesArchivedChats() throws {
        let fixture = try makeEmptySchemaDB()
        try fixture.write { db in
            let ns = MessagesDatabase.appleNanos(from: Date())
            try db.execute(sql: """
            INSERT INTO chat (guid, chat_identifier, service_name, display_name, style, is_archived)
                VALUES ('active-chat', '+15550002222', 'iMessage', 'Active', 0, 0);
            INSERT INTO chat (guid, chat_identifier, service_name, display_name, style, is_archived)
                VALUES ('archived-chat', '+15550003333', 'iMessage', 'Archived', 0, 1);
            INSERT INTO message (guid, text, date, is_from_me, is_read, service)
                VALUES ('m-active', 'hello world from active', ?, 0, 1, 'iMessage');
            INSERT INTO message (guid, text, date, is_from_me, is_read, service)
                VALUES ('m-archived', 'hello world from archived', ?, 0, 1, 'iMessage');
            INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 1);
            INSERT INTO chat_message_join (chat_id, message_id) VALUES (2, 2);
            """, arguments: [ns, ns - 1])
        }
        let db = try MessagesDatabase(dbQueue: fixture)
        let (matches, _, _) = try db.searchMessages(query: "hello world", limit: 50)
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

    func testShowReportsRealUnreadCount() throws {
        // Regression: show hardcoded unreadCount: 0 while list computed it.
        let db = try MessagesDatabase(dbQueue: makeFixtureDB())
        let (conversation, _, _) = try db.showConversation(
            conversationId: "iMessage;-;+15551234567", limit: 50
        )
        XCTAssertEqual(conversation.unreadCount, 1, "msg-1 is inbound and unread")
        // Group chat's only unread row is the tapback → 0.
        let (group, _, _) = try db.showConversation(conversationId: "iMessage;-;groupA", limit: 50)
        XCTAssertEqual(group.unreadCount, 0)
    }

    // MARK: - Attachments

    /// Chat with one attachment-only message (two attachments: transfer_name
    /// set on one; the other only has a full filename path) and one plain-text
    /// message with no attachments.
    private func makeAttachmentFixtureDB() throws -> DatabaseQueue {
        let queue = try makeEmptySchemaDB()
        try queue.write { db in
            let ns = MessagesDatabase.appleNanos(from: Date(timeIntervalSince1970: 1_750_000_000))
            try db.execute(sql: """
            INSERT INTO chat (guid, chat_identifier, service_name, style, is_archived)
                VALUES ('att-chat', 'att-chat', 'iMessage', 45, 0);
            INSERT INTO message (guid, text, date, is_from_me, is_read, service)
                VALUES ('msg-att', NULL, \(ns), 0, 1, 'iMessage');
            INSERT INTO message (guid, text, date, is_from_me, is_read, service)
                VALUES ('msg-plain', 'see the attached photo', \(ns - 1_000_000_000), 0, 1, 'iMessage');
            INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 1);
            INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 2);
            INSERT INTO attachment (filename, transfer_name, mime_type)
                VALUES ('~/Library/Messages/Attachments/ab/cd/IMG_1234.HEIC', 'IMG_1234.HEIC', 'image/heic');
            INSERT INTO attachment (filename, transfer_name, mime_type)
                VALUES ('~/Library/Messages/Attachments/ef/gh/video-clip.mov', NULL, 'video/quicktime');
            INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (1, 1);
            INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (1, 2);
            """)
        }
        return queue
    }

    func testShowSurfacesAttachmentMetadata() throws {
        let db = try MessagesDatabase(dbQueue: makeAttachmentFixtureDB())
        let (_, messages, _) = try db.showConversation(conversationId: "att-chat", limit: 50)
        XCTAssertEqual(messages.count, 2)
        let attachmentMsg = try XCTUnwrap(messages.first { $0.id == "msg-att" })
        XCTAssertNil(attachmentMsg.text, "attachment-only message has no text")
        XCTAssertEqual(attachmentMsg.attachments, [
            MessageAttachment(filename: "IMG_1234.HEIC", mimeType: "image/heic"),
            MessageAttachment(filename: "video-clip.mov", mimeType: "video/quicktime"),
        ], "transfer_name preferred; filename path falls back to its last component")
        let plainMsg = try XCTUnwrap(messages.first { $0.id == "msg-plain" })
        XCTAssertNil(plainMsg.attachments, "no attachments → nil (omitted in JSON)")
    }

    func testSearchSurfacesAttachmentMetadata() throws {
        let fixture = try makeAttachmentFixtureDB()
        try fixture.write { db in
            // Give the searchable text message an attachment too.
            try db.execute(sql: "INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (2, 1)")
        }
        let db = try MessagesDatabase(dbQueue: fixture)
        let (matches, _, _) = try db.searchMessages(query: "attached photo", limit: 50)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.attachments, [MessageAttachment(filename: "IMG_1234.HEIC", mimeType: "image/heic")])
    }

    func testMessageItemJSONOmitsNilAttachments() throws {
        let db = try MessagesDatabase(dbQueue: makeAttachmentFixtureDB())
        let (_, messages, _) = try db.showConversation(conversationId: "att-chat", limit: 50)
        let plain = try XCTUnwrap(messages.first { $0.id == "msg-plain" })
        let json = try String(decoding: JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(json.contains("\"attachments\""), "nil attachments must omit the key, not emit null")
        let withAtt = try XCTUnwrap(messages.first { $0.id == "msg-att" })
        let jsonWith = try String(decoding: JSONEncoder().encode(withAtt), as: UTF8.self)
        XCTAssertTrue(jsonWith.contains("\"mime_type\":\"image\\/heic\"") || jsonWith.contains("\"mime_type\":\"image/heic\""))
    }

    func testShowThrowsForUnknownConversation() {
        XCTAssertThrowsError(try MessagesDatabase(dbQueue: makeFixtureDB())
            .showConversation(conversationId: "nonexistent", limit: 10)) { error in
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

    // MARK: - attributedBody decode through the query paths (pippin-cc1)

    /// A real typedstream archive of a synthetic NSAttributedString
    /// "Hello, typedstream world! 🌍" — chat.db's attributedBody format, no real data.
    private static let goldenAttributedBody =
        "BAtzdHJlYW10eXBlZIHoA4QBQISEhBJOU0F0dHJpYnV0ZWRTdHJpbmcAhIQITlNPYmplY3QAhZKEhIQI" +
        "TlNTdHJpbmcBlIQBKx5IZWxsbywgdHlwZWRzdHJlYW0gd29ybGQhIPCfjI2GhAJpSQEckoSEhAxOU0Rp" +
        "Y3Rpb25hcnkAlIQBaQCGhg=="

    // MARK: - Contact name resolution (handle → Apple Contacts)

    private func contactFixtureIndex() -> ContactIndex {
        var idx = ContactIndex()
        idx.add(name: "Bob Caller", phones: ["+15551234567"], emails: [])
        idx.add(name: "Alice Example", phones: [], emails: ["alice@example.com"])
        return idx
    }

    func testShowResolvesSenderAndOneToOneConversationName() throws {
        let db = try MessagesDatabase(dbQueue: makeFixtureDB())
        let (conv, messages, _) = try db.showConversation(
            conversationId: "iMessage;-;+15551234567", contactIndex: contactFixtureIndex()
        )
        // 1:1 thread has no chat name → falls back to the resolved participant.
        XCTAssertEqual(conv.displayName, "Bob Caller")
        // Inbound message's sender handle resolves; outbound (from me) stays nil.
        XCTAssertEqual(messages.first(where: { !$0.isFromMe })?.fromDisplayName, "Bob Caller")
        XCTAssertNil(messages.first(where: { $0.isFromMe })?.fromDisplayName)
    }

    func testListResolvesParticipantsButKeepsGroupName() throws {
        let db = try MessagesDatabase(dbQueue: makeFixtureDB())
        let (convs, _) = try db.listConversations(limit: 50, contactIndex: contactFixtureIndex())
        let dm = convs.first { $0.id == "iMessage;-;+15551234567" }
        let group = convs.first { $0.id == "iMessage;-;groupA" }
        XCTAssertEqual(dm?.displayName, "Bob Caller") // 1:1 → contact name
        XCTAssertEqual(group?.displayName, "Team Group") // explicit group name wins
        XCTAssertEqual(group?.participants.first { $0.handle == "alice@example.com" }?.displayName, "Alice Example")
    }

    func testSearchResolvesSenderName() throws {
        let db = try MessagesDatabase(dbQueue: makeFixtureDB())
        let (matches, _, _) = try db.searchMessages(query: "lunch", contactIndex: contactFixtureIndex())
        XCTAssertEqual(matches.first?.fromDisplayName, "Alice Example")
    }

    func testNoContactIndexLeavesNamesNil() throws {
        let db = try MessagesDatabase(dbQueue: makeFixtureDB())
        let (_, messages, _) = try db.showConversation(conversationId: "iMessage;-;+15551234567")
        XCTAssertNil(messages.first?.fromDisplayName)
    }

    func testShowAndSearchDecodeAttributedBodyWhenTextNull() throws {
        let blob = try XCTUnwrap(Data(base64Encoded: Self.goldenAttributedBody))
        let queue = try makeEmptySchemaDB()
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO chat (guid, chat_identifier, service_name, style, is_archived)
                VALUES ('blob-chat', 'blob-chat', 'iMessage', 45, 0);
            INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 1);
            """)
            let ns = MessagesDatabase.appleNanos(from: Date(timeIntervalSince1970: 1_750_000_000))
            // text NULL, body only in attributedBody — the modern-macOS shape.
            try db.execute(
                sql: """
                INSERT INTO message (guid, text, attributedBody, date, is_from_me, is_read, service)
                    VALUES ('blob-msg', NULL, ?, ?, 0, 1, 'iMessage')
                """,
                arguments: [blob, ns]
            )
        }
        let mdb = try MessagesDatabase(dbQueue: queue)

        let (_, messages, _) = try mdb.showConversation(conversationId: "blob-chat", limit: 10)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.text, "Hello, typedstream world! 🌍")

        // search must find attributedBody-only messages via the decode-scan path.
        let (matches, _, scanTruncated) = try mdb.searchMessages(query: "typedstream", limit: 10)
        XCTAssertEqual(matches.first?.text, "Hello, typedstream world! 🌍")
        XCTAssertFalse(scanTruncated, "one blob-only row is well under the scan cap")
    }

    // MARK: - Consolidated last-message join (pippin-77t)

    func testListConversationsPreviewDecodesAttributedBodyWhenTextNull() throws {
        // The single last-message join must still expose attributedBody for the
        // preview when the last message's text column is NULL (modern-macOS shape).
        let blob = try XCTUnwrap(Data(base64Encoded: Self.goldenAttributedBody))
        let queue = try makeEmptySchemaDB()
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO chat (guid, chat_identifier, service_name, style, is_archived)
                VALUES ('blob-chat', 'blob-chat', 'iMessage', 45, 0);
            INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 1);
            """)
            let ns = MessagesDatabase.appleNanos(from: Date(timeIntervalSince1970: 1_750_000_000))
            try db.execute(
                sql: "INSERT INTO message (guid, text, attributedBody, date, is_from_me, is_read, service) VALUES ('blob-msg', NULL, ?, ?, 0, 1, 'iMessage')",
                arguments: [blob, ns]
            )
        }
        let mdb = try MessagesDatabase(dbQueue: queue)
        let (convs, _) = try mdb.listConversations(limit: 10)
        XCTAssertEqual(convs.first?.lastMessagePreview, "Hello, typedstream world! 🌍")
    }

    func testListConversationsSinceCutoffFiltersByLastMessage() throws {
        // The since cutoff filters on each chat's last non-tapback message date.
        // Fixture: DM's last message is `recent`; the group's is 30 days prior.
        // A cutoff between them keeps only the DM.
        let db = try MessagesDatabase(dbQueue: makeFixtureDB())
        let cutoff = Date(timeIntervalSince1970: 1_750_000_000).addingTimeInterval(-86400 * 5)
        let (convs, _) = try db.listConversations(since: cutoff, limit: 50)
        XCTAssertEqual(convs.map(\.id), ["iMessage;-;+15551234567"])
    }

    // MARK: - Scan-cap truncation visibility (pippin-wve)

    /// Seed `count` attributedBody-only messages (text NULL) into a single chat
    /// so the search decode-scan path (Q2) has more than the scan cap to chew on.
    private func makeBlobOnlyFixtureDB(count: Int) throws -> DatabaseQueue {
        let blob = try XCTUnwrap(Data(base64Encoded: Self.goldenAttributedBody))
        let queue = try makeEmptySchemaDB()
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO chat (guid, chat_identifier, service_name, style, is_archived)
                VALUES ('blob-chat', 'blob-chat', 'iMessage', 45, 0);
            """)
            let base = MessagesDatabase.appleNanos(from: Date(timeIntervalSince1970: 1_750_000_000))
            for i in 0 ..< count {
                // Descending dates so row 0 is the most recent. text NULL → blob-only.
                try db.execute(
                    sql: """
                    INSERT INTO message (guid, text, attributedBody, date, is_from_me, is_read, service)
                        VALUES (?, NULL, ?, ?, 0, 1, 'iMessage');
                    INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, last_insert_rowid());
                    """,
                    arguments: ["blob-\(i)", blob, base - Int64(i) * 1_000_000_000]
                )
            }
        }
        return queue
    }

    func testSearchSetsScanTruncatedWhenBlobScanHitsCap() throws {
        // One more blob-only row than the cap → the most-recent `cap` are scanned,
        // the oldest goes unscanned, so the result must flag the truncation.
        let cap = MessagesDatabase.searchAttributedScanCap
        let db = try MessagesDatabase(dbQueue: makeBlobOnlyFixtureDB(count: cap + 1))
        let (_, _, scanTruncated) = try db.searchMessages(query: "typedstream", limit: 50)
        XCTAssertTrue(scanTruncated, "more blob-only rows than the cap → scan truncated")
    }

    func testSearchDoesNotSetScanTruncatedUnderCap() throws {
        // Exactly cap-1 blob-only rows: all of them are scanned, nothing left out.
        let cap = MessagesDatabase.searchAttributedScanCap
        let db = try MessagesDatabase(dbQueue: makeBlobOnlyFixtureDB(count: cap - 1))
        let (_, _, scanTruncated) = try db.searchMessages(query: "typedstream", limit: 50)
        XCTAssertFalse(scanTruncated, "blob-only rows under the cap → no truncation")
    }
}
