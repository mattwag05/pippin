import Foundation
import GRDB
@testable import PippinLib
import XCTest

/// Shared chat.db stand-in for the Messages tests. Never the live database.
enum MessagesFixture {
    /// An empty chat.db schema, in memory or at `path`.
    static func emptySchema(path: String? = nil) throws -> DatabaseQueue {
        let db = try path.map { try DatabaseQueue(path: $0) } ?? DatabaseQueue()
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

    /// A 1:1 chat (`iMessage;-;+15551234567`, one unread inbound message) and a
    /// group chat (`iMessage;-;groupA`, identifier `chat123`) whose newest row
    /// is an unread tapback.
    static func standard(path: String? = nil) throws -> DatabaseQueue {
        let db = try emptySchema(path: path)
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
}

/// Points the `messages` commands at a fixture chat.db, a temp config and a temp
/// audit log for the life of one test, then restores the environment.
final class MessagesCommandSandbox {
    let dir: String
    var dbPath: String { dir + "/chat.db" }
    var configPath: String { dir + "/config.json" }
    var auditPath: String { dir + "/audit.jsonl" }

    private static let keys = ["PIPPIN_MESSAGES_DB", "PIPPIN_CONFIG", "PIPPIN_MESSAGES_AUDIT_PATH"]
    private var saved: [String: String?] = [:]

    init() throws {
        dir = NSTemporaryDirectory() + "pippin-messages-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for key in Self.keys {
            saved[key] = ProcessInfo.processInfo.environment[key]
        }
        setenv("PIPPIN_MESSAGES_DB", dbPath, 1)
        setenv("PIPPIN_CONFIG", configPath, 1)
        setenv("PIPPIN_MESSAGES_AUDIT_PATH", auditPath, 1)
        _ = try MessagesFixture.standard(path: dbPath)
    }

    func writeConfig(_ json: String) throws {
        try json.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    func auditEntries() throws -> [[String: Any]] {
        guard let text = try? String(contentsOfFile: auditPath, encoding: .utf8) else { return [] }
        return try text.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func tearDown() {
        for (key, value) in saved {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        try? FileManager.default.removeItem(atPath: dir)
    }
}
