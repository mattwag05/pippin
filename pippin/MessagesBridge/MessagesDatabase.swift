import Foundation
import GRDB

public enum MessagesError: LocalizedError, Sendable {
    case databaseNotFound(String)
    case accessDenied(String)
    case conversationNotFound(String)
    case databaseError(String)

    public var errorDescription: String? {
        switch self {
        case let .databaseNotFound(path):
            return "Messages database not found at: \(path)"
        case let .accessDenied(detail):
            return "Messages database access denied (\(detail)). Grant Full Disk Access to your terminal in System Settings → Privacy & Security."
        case let .conversationNotFound(id):
            return "Conversation not found: \(id)"
        case let .databaseError(detail):
            return "Messages database error: \(detail)"
        }
    }
}

/// Read-only access to `~/Library/Messages/chat.db`.
///
/// Apple's Messages epoch is 2001-01-01 UTC — the same as Foundation's
/// `timeIntervalSinceReferenceDate`. Post-macOS-10.13 the `date` column is
/// nanoseconds since that epoch; older rows are seconds. The conversion below
/// distinguishes by magnitude (> 10^12 → nanoseconds).
public final class MessagesDatabase: Sendable {
    /// chat.style == 43 marks a multi-party (group) thread in chat.db.
    private static let groupChatStyle: Int = 43

    private let dbQueue: DatabaseQueue

    public static func defaultDBPath() -> String {
        let home = NSHomeDirectory()
        return "\(home)/Library/Messages/chat.db"
    }

    public init(dbPath: String) throws {
        var config = Configuration()
        config.readonly = true
        do {
            dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
        } catch {
            let ns = error as NSError
            // Check for permission errors first — on macOS TCC, fileExists(atPath:)
            // can return false even when the file exists, so we must inspect the
            // NSError before falling back to a filesystem existence check.
            if ns.domain == NSPOSIXErrorDomain {
                switch ns.code {
                case Int(EACCES), Int(EPERM):
                    throw MessagesError.accessDenied(ns.localizedDescription)
                case Int(ENOENT):
                    throw MessagesError.databaseNotFound(dbPath)
                default:
                    break
                }
            }
            // Fallback existence check for non-POSIX "not found" scenarios.
            if !FileManager.default.fileExists(atPath: dbPath) {
                throw MessagesError.databaseNotFound(dbPath)
            }
            throw MessagesError.databaseError(error.localizedDescription)
        }
    }

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Queries

    /// List conversations with a message in the given window, most-recent first.
    public func listConversations(
        since: Date? = nil,
        limit: Int = 50,
        excluded: Set<String> = []
    ) throws -> (conversations: [MessageConversation], excludedCount: Int) {
        let cutoffNs = since.map(Self.appleNanos(from:))
        return try readWrapping { db in
            var sql = """
            SELECT
                c.ROWID AS chat_rowid,
                c.guid AS chat_guid,
                c.service_name,
                c.display_name,
                c.room_name,
                c.style,
                MAX(m.date) AS last_date,
                (SELECT m2.text FROM message m2
                 JOIN chat_message_join cmj2 ON cmj2.message_id = m2.ROWID
                 WHERE cmj2.chat_id = c.ROWID
                 ORDER BY m2.date DESC LIMIT 1) AS last_text,
                (SELECT COUNT(*) FROM message m3
                 JOIN chat_message_join cmj3 ON cmj3.message_id = m3.ROWID
                 WHERE cmj3.chat_id = c.ROWID
                   AND m3.is_from_me = 0
                   AND m3.is_read = 0) AS unread_count
            FROM chat c
            JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            JOIN message m ON m.ROWID = cmj.message_id
            WHERE c.is_archived = 0
            """
            var args: [any DatabaseValueConvertible] = []
            if let cutoffNs {
                sql += " AND m.date >= ?"
                args.append(cutoffNs)
            }
            // Overshoot by the exclude-set size so we still return `limit`
            // after post-filtering. Cheaper than a `NOT IN (?,?,…)` bind for
            // an exclude list that's typically small.
            sql += " GROUP BY c.ROWID ORDER BY last_date DESC LIMIT ?"
            args.append(limit + excluded.count)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            var kept: [Row] = []
            var excludedCount = 0
            for row in rows {
                let guid: String = row["chat_guid"] ?? ""
                if excluded.contains(guid) {
                    excludedCount += 1
                    continue
                }
                kept.append(row)
                if kept.count >= limit { break }
            }

            let chatRowIds = kept.compactMap { $0["chat_rowid"] as Int64? }
            let participantsByRowId = try Self.fetchParticipants(db: db, chatRowIds: chatRowIds)

            return (kept.map { row in
                let rowId: Int64 = row["chat_rowid"] ?? 0
                let style: Int = row["style"] ?? 0
                let lastDateNs: Int64? = row["last_date"]
                return MessageConversation(
                    id: row["chat_guid"] ?? "",
                    service: row["service_name"] ?? "",
                    displayName: row["display_name"] ?? row["room_name"],
                    participants: participantsByRowId[rowId] ?? [],
                    isGroup: style == Self.groupChatStyle,
                    lastMessageAt: lastDateNs.map(Self.iso8601(fromAppleNanos:)),
                    lastMessagePreview: (row["last_text"] as String?).map { Self.preview($0) },
                    unreadCount: row["unread_count"] ?? 0
                )
            }, excludedCount)
        }
    }

    public func searchMessages(
        query: String,
        since: Date? = nil,
        limit: Int = 50,
        excluded: Set<String> = []
    ) throws -> (matches: [MessageItem], excludedCount: Int) {
        let cutoffNs = since.map(Self.appleNanos(from:))
        return try readWrapping { db in
            var sql = """
            SELECT
                m.guid AS msg_guid,
                m.text,
                m.date,
                m.is_from_me,
                m.is_read,
                m.service,
                c.guid AS chat_guid,
                h.id AS handle_id
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.text LIKE ?
            """
            var args: [any DatabaseValueConvertible] = ["%\(query)%"]
            if let cutoffNs {
                sql += " AND m.date >= ?"
                args.append(cutoffNs)
            }
            sql += " ORDER BY m.date DESC LIMIT ?"
            args.append(limit + excluded.count)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            var excludedCount = 0
            var results: [MessageItem] = []
            for row in rows {
                let chatGuid: String = row["chat_guid"] ?? ""
                if excluded.contains(chatGuid) {
                    excludedCount += 1
                    continue
                }
                let dateNs: Int64 = row["date"] ?? 0
                results.append(MessageItem(
                    id: row["msg_guid"] ?? "",
                    conversationId: chatGuid,
                    date: Self.iso8601(fromAppleNanos: dateNs),
                    text: row["text"],
                    fromHandle: row["handle_id"],
                    fromDisplayName: nil,
                    isFromMe: (row["is_from_me"] ?? 0) == 1,
                    isRead: (row["is_read"] ?? 0) == 1,
                    service: row["service"] ?? ""
                ))
                if results.count >= limit { break }
            }
            return (results, excludedCount)
        }
    }

    public func showConversation(
        conversationId: String,
        limit: Int = 50
    ) throws -> (conversation: MessageConversation, messages: [MessageItem], truncated: Bool) {
        try readWrapping { db in
            guard let chatRow = try Row.fetchOne(
                db,
                sql: """
                SELECT ROWID, guid, chat_identifier, service_name, display_name, room_name, style
                FROM chat WHERE guid = ?
                """,
                arguments: [conversationId]
            ) else {
                throw MessagesError.conversationNotFound(conversationId)
            }
            let chatRowId: Int64 = chatRow["ROWID"] ?? 0
            let chatGuid: String = chatRow["guid"] ?? conversationId

            let participants = try Self.fetchParticipants(db: db, chatRowIds: [chatRowId])[chatRowId] ?? []

            // Fetch limit + 1 rows so we know whether older messages exist
            // without a separate COUNT(*) round-trip.
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT m.guid AS msg_guid, m.text, m.date, m.is_from_me, m.is_read,
                       m.service, h.id AS handle_id
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                LEFT JOIN handle h ON h.ROWID = m.handle_id
                WHERE cmj.chat_id = ?
                ORDER BY m.date DESC LIMIT ?
                """,
                arguments: [chatRowId, limit + 1]
            )
            let truncated = rows.count > limit
            let trimmed = truncated ? Array(rows.prefix(limit)) : rows

            let messages: [MessageItem] = trimmed.reversed().map { row in
                let dateNs: Int64 = row["date"] ?? 0
                return MessageItem(
                    id: row["msg_guid"] ?? "",
                    conversationId: chatGuid,
                    date: Self.iso8601(fromAppleNanos: dateNs),
                    text: row["text"],
                    fromHandle: row["handle_id"],
                    fromDisplayName: nil,
                    isFromMe: (row["is_from_me"] ?? 0) == 1,
                    isRead: (row["is_read"] ?? 0) == 1,
                    service: row["service"] ?? ""
                )
            }

            let style: Int = chatRow["style"] ?? 0
            let conversation = MessageConversation(
                id: chatGuid,
                service: chatRow["service_name"] ?? "",
                displayName: chatRow["display_name"] ?? chatRow["room_name"],
                participants: participants,
                isGroup: style == Self.groupChatStyle,
                lastMessageAt: messages.last?.date,
                lastMessagePreview: messages.last?.text.map { Self.preview($0) },
                unreadCount: 0
            )
            return (conversation, messages, truncated)
        }
    }

    // MARK: - Helpers

    private func readWrapping<T>(_ block: @Sendable (Database) throws -> T) throws -> T {
        do {
            return try dbQueue.read(block)
        } catch let error as MessagesError {
            throw error
        } catch {
            throw MessagesError.databaseError(error.localizedDescription)
        }
    }

    /// Batch-fetch participants for every supplied chat ROWID in a single
    /// query, grouped back into `[chatRowId: [participant]]`. Replaces a
    /// per-conversation N+1 loop.
    private static func fetchParticipants(
        db: Database,
        chatRowIds: [Int64]
    ) throws -> [Int64: [MessageParticipant]] {
        guard !chatRowIds.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: chatRowIds.count).joined(separator: ",")
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT chj.chat_id, h.id, h.service
            FROM handle h
            JOIN chat_handle_join chj ON chj.handle_id = h.ROWID
            WHERE chj.chat_id IN (\(placeholders))
            """,
            arguments: StatementArguments(chatRowIds)
        )
        var byChat: [Int64: [MessageParticipant]] = [:]
        for row in rows {
            let chatId: Int64 = row["chat_id"] ?? 0
            let participant = MessageParticipant(
                handle: row["id"] ?? "",
                service: row["service"] ?? "",
                displayName: nil
            )
            byChat[chatId, default: []].append(participant)
        }
        return byChat
    }

    static func date(fromAppleNanos nanos: Int64) -> Date {
        // Foundation's reference date IS 2001-01-01 UTC, same as Apple's
        // Messages epoch. Distinguish nanos from legacy seconds by magnitude.
        let seconds: TimeInterval = nanos > 1_000_000_000_000
            ? TimeInterval(nanos) / 1_000_000_000
            : TimeInterval(nanos)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    static func appleNanos(from date: Date) -> Int64 {
        Int64(date.timeIntervalSinceReferenceDate * 1_000_000_000)
    }

    static func iso8601(fromAppleNanos nanos: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date(fromAppleNanos: nanos))
    }

    static func preview(_ text: String, limit: Int = 140) -> String {
        TextFormatter.truncate(text.replacingOccurrences(of: "\n", with: " "), to: limit)
    }
}
