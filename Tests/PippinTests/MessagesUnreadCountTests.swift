import GRDB
@testable import PippinLib
import XCTest

/// `unread_count` must equal the unread inbound messages a reader can find in
/// the thread (pippin-lzuv). chat.db leaves `is_read = 0` forever on rows that
/// are not messages: group renames, system rows, unsent messages, empty rows.
final class MessagesUnreadCountTests: XCTestCase {
    private static let chat = "iMessage;-;unread-chat"
    private static let base = MessagesDatabase.appleNanos(from: Date(timeIntervalSince1970: 1_750_000_000))

    /// Appends one message to chat 1. `seconds` orders rows: larger is newer.
    private func insert(
        _ db: Database, _ guid: String, seconds: Int64, text: String? = nil, blob: Data? = nil,
        fromMe: Bool = false, read: Bool = false, extra: [String: Int] = [:]
    ) throws {
        let columns = extra.keys.sorted()
        try db.execute(
            sql: """
            INSERT INTO message (guid, text, attributedBody, date, is_from_me, is_read, service\(columns.map { ", \($0)" }.joined()))
                VALUES (?, ?, ?, ?, ?, ?, 'iMessage'\(columns.map { ", \(extra[$0] ?? 0)" }.joined()));
            INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, last_insert_rowid());
            """,
            arguments: [guid, text, blob, Self.base + seconds * 1_000_000_000, fromMe ? 1 : 0, read ? 1 : 0]
        )
    }

    /// Three real unread inbound messages (text, attachment only, attributedBody
    /// only), one read, one sent, and unread rows no reader can see. The newest
    /// row of all is a group rename when `legacy` is false.
    private func makeDB(legacy: Bool = false) throws -> MessagesDatabase {
        let queue = try MessagesFixture.emptySchema(legacy: legacy)
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO chat (guid, chat_identifier, service_name, style) VALUES ('\(Self.chat)', 'unread-chat', 'iMessage', 43);
            """)
            try insert(db, "read-text", seconds: 1, text: "old news", read: true)
            try insert(db, "unread-attachment", seconds: 2)
            try db.execute(sql: """
            INSERT INTO attachment (filename, transfer_name, mime_type) VALUES ('a.heic', 'a.heic', 'image/heic');
            INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (2, 1);
            """)
            try insert(db, "unread-blob", seconds: 3, blob: Data([0x04, 0x0B]))
            try insert(db, "sent", seconds: 4, text: "on my way", fromMe: true)
            try insert(db, "empty-row", seconds: 5)
            try insert(db, "unread-text", seconds: 6, text: "are you there?")
            if !legacy {
                try insert(db, "system-row", seconds: 7, text: "system notice", extra: ["is_system_message": 1])
                try insert(db, "retracted", seconds: 8, extra: ["date_retracted": 777])
                try insert(db, "group-rename", seconds: 9, extra: ["item_type": 2])
            }
        }
        return MessagesDatabase(dbQueue: queue)
    }

    private static let unread: Set = ["unread-text", "unread-attachment", "unread-blob"]

    func testUnreadCountEqualsUnreadInboundMessagesReturnedByShow() throws {
        let db = try makeDB()
        let (conversation, messages, truncated) = try db.showConversation(conversationId: Self.chat, limit: 1000)
        XCTAssertFalse(truncated)
        let unreadInbound = messages.filter { !$0.isRead && !$0.isFromMe }
        XCTAssertEqual(Set(unreadInbound.map(\.id)), Self.unread)
        XCTAssertEqual(conversation.unreadCount, unreadInbound.count)
    }

    func testListUnreadCountMatchesShow() throws {
        let db = try makeDB()
        let listed = try XCTUnwrap(db.listConversations(limit: 50).conversations.first)
        XCTAssertEqual(listed.unreadCount, 3)
        XCTAssertEqual(listed.unreadCount, try db.showConversation(conversationId: Self.chat).conversation.unreadCount)
    }

    func testShowOmitsRowsThatAreNotMessages() throws {
        let (_, messages, _) = try makeDB().showConversation(conversationId: Self.chat, limit: 1000)
        XCTAssertEqual(
            messages.map(\.id), ["read-text", "unread-attachment", "unread-blob", "sent", "unread-text"],
            "no group rename, system, unsent or empty rows"
        )
    }

    func testListPreviewAndOrderingIgnoreRowsThatAreNotMessages() throws {
        // The newest row is a group rename; the thread's last message is still the newest real one.
        let listed = try XCTUnwrap(makeDB().listConversations(limit: 50).conversations.first)
        XCTAssertEqual(listed.lastMessagePreview, "are you there?")
        XCTAssertEqual(listed.lastMessageAt, MessagesDatabase.iso8601(fromAppleNanos: Self.base + 6_000_000_000))
    }

    func testSearchSkipsSystemRows() throws {
        let db = try makeDB()
        XCTAssertTrue(try db.searchMessages(query: "system notice").matches.isEmpty)
        XCTAssertEqual(try db.searchMessages(query: "are you there").matches.map(\.id), ["unread-text"])
    }

    func testOlderSchemaWithoutTheNewColumnsStillWorks() throws {
        let db = try makeDB(legacy: true)
        let (conversation, messages, _) = try db.showConversation(conversationId: Self.chat, limit: 1000)
        XCTAssertEqual(conversation.unreadCount, 3)
        XCTAssertEqual(Set(messages.filter { !$0.isRead && !$0.isFromMe }.map(\.id)), Self.unread)
        XCTAssertEqual(try db.listConversations(limit: 50).conversations.first?.unreadCount, 3)
        XCTAssertEqual(try db.searchMessages(query: "are you there").matches.count, 1)
    }
}
