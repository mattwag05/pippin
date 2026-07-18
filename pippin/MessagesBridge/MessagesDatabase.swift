import CTypedStreamDecode
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

    /// SQL predicate excluding tapback (reaction) rows for the given message
    /// alias. Apple's `associated_message_type`: 0/NULL = normal, 2000–2005 =
    /// add tapback, 3000–3005 = remove, with 2006/3006+ custom-emoji variants
    /// on newer macOS. ponytail: blanket 2000–3999 exclusion covers future
    /// tapback subtypes; stickers (1000s) and edits stay visible.
    static func excludeTapbacks(_ alias: String) -> String {
        "COALESCE(\(alias).associated_message_type, 0) NOT BETWEEN 2000 AND 3999"
    }

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
            // Check for POSIX errors first — on macOS TCC, fileExists(atPath:)
            // can return false even when the file exists, so we inspect the
            // NSError before falling back to a filesystem existence check.
            let ns = error as NSError
            if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) {
                throw MessagesError.databaseNotFound(dbPath)
            }
            if Self.isAccessDeniedOpenError(error) {
                throw MessagesError.accessDenied(error.localizedDescription)
            }
            if !FileManager.default.fileExists(atPath: dbPath) {
                throw MessagesError.databaseNotFound(dbPath)
            }
            throw MessagesError.databaseError(error.localizedDescription)
        }
    }

    private static func isAccessDeniedOpenError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain,
           ns.code == Int(EACCES) || ns.code == Int(EPERM) {
            return true
        }
        if let dbError = error as? DatabaseError,
           [.SQLITE_AUTH, .SQLITE_PERM].contains(dbError.resultCode) {
            return true
        }
        return false
    }

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Queries

    /// List conversations with a message in the given window, most-recent first.
    public func listConversations(
        since: Date? = nil,
        limit: Int = 50,
        excluded: Set<String> = [],
        contactIndex: ContactIndex = ContactIndex()
    ) throws -> (conversations: [MessageConversation], excludedCount: Int) {
        let limit = Self.clampLimit(limit)
        let cutoffNs = since.map(Self.appleNanos(from:))
        return try readWrapping { db in
            // Resolve each chat's last non-tapback message ROWID once, then JOIN
            // it for date + both preview columns (pippin-77t). Previously two
            // separate correlated subqueries re-seeked that same row to pull
            // `text` and `attributedBody` independently; the single seek + PK
            // join replaces both and drops the MAX/GROUP BY (last_date is just
            // that row's date). A chat with no non-tapback message yields a NULL
            // subquery → the INNER JOIN drops it, matching the old behavior.
            var sql = """
            SELECT
                c.ROWID AS chat_rowid,
                c.guid AS chat_guid,
                c.service_name,
                c.display_name,
                c.room_name,
                c.style,
                lm.date AS last_date,
                lm.text AS last_text,
                lm.attributedBody AS last_attributedbody,
                (SELECT COUNT(*) FROM message m3
                 JOIN chat_message_join cmj3 ON cmj3.message_id = m3.ROWID
                 WHERE cmj3.chat_id = c.ROWID
                   AND m3.is_from_me = 0
                   AND m3.is_read = 0
                   AND \(Self.excludeTapbacks("m3"))) AS unread_count
            FROM chat c
            JOIN message lm ON lm.ROWID = (
                SELECT m2.ROWID FROM message m2
                JOIN chat_message_join cmj2 ON cmj2.message_id = m2.ROWID
                WHERE cmj2.chat_id = c.ROWID AND \(Self.excludeTapbacks("m2"))
                ORDER BY m2.date DESC LIMIT 1)
            WHERE c.is_archived = 0
            """
            var args: [any DatabaseValueConvertible] = []
            if let cutoffNs {
                // "last message on/after cutoff" ≡ the old "any non-tapback
                // message ≥ cutoff" (the last IS the max), so the filtered set
                // is identical.
                sql += " AND lm.date >= ?"
                args.append(cutoffNs)
            }
            // Overshoot by the exclude-set size so we still return `limit`
            // after post-filtering. Cheaper than a `NOT IN (?,?,…)` bind for
            // an exclude list that's typically small.
            sql += " ORDER BY last_date DESC LIMIT ?"
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
            let participantsByRowId = try Self.fetchParticipants(
                db: db, chatRowIds: chatRowIds, contactIndex: contactIndex
            )

            return (kept.map { row in
                let rowId: Int64 = row["chat_rowid"] ?? 0
                let style: Int = row["style"] ?? 0
                let lastDateNs: Int64? = row["last_date"]
                let participants = participantsByRowId[rowId] ?? []
                return MessageConversation(
                    id: row["chat_guid"] ?? "",
                    service: row["service_name"] ?? "",
                    displayName: Self.conversationDisplayName(
                        explicit: row["display_name"] ?? row["room_name"], participants: participants
                    ),
                    participants: participants,
                    isGroup: style == Self.groupChatStyle,
                    lastMessageAt: lastDateNs.map(Self.iso8601(fromAppleNanos:)),
                    lastMessagePreview: Self.resolveBody(text: row["last_text"], attributedBody: row["last_attributedbody"]).map { Self.preview($0) },
                    unreadCount: row["unread_count"] ?? 0
                )
            }, excludedCount)
        }
    }

    /// How many recent attributedBody-only messages a search will decode-scan.
    /// Their body lives in a typedstream blob SQLite can't LIKE into, so they're
    /// filtered in Swift; this cap bounds that work. The text-column path is
    /// unbounded by recency, so older messages that still populate `text` are
    /// matched regardless. (pippin-cc1)
    static let searchAttributedScanCap = 1500

    public func searchMessages(
        query: String,
        since: Date? = nil,
        limit: Int = 50,
        excluded: Set<String> = [],
        contactIndex: ContactIndex = ContactIndex()
    ) throws -> (matches: [MessageItem], excludedCount: Int, scanTruncated: Bool) {
        let limit = Self.clampLimit(limit)
        let cutoffNs = since.map(Self.appleNanos(from:))
        let needle = query.lowercased()
        return try readWrapping { db in
            // Shared column list + joins. Includes attributedBody so bodies that
            // live only in the blob can be decoded.
            let base = """
            m.ROWID AS msg_rowid, m.guid AS msg_guid, m.text, m.attributedBody, m.date, m.is_from_me,
                   m.is_read, m.service, c.guid AS chat_guid, h.id AS handle_id
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            """
            let sinceClause = cutoffNs != nil ? " AND m.date >= ?" : ""
            let notTapback: String = Self.excludeTapbacks("m")

            // Q1 — text-column matches across all history (SQLite LIKE; preserves
            // the prior behavior for messages that still populate `m.text`).
            var q1args: [any DatabaseValueConvertible] = ["%\(Self.escapeLike(query))%"]
            if let cutoffNs { q1args.append(cutoffNs) }
            q1args.append(limit + excluded.count)
            let q1 = try Row.fetchAll(db, sql: """
            SELECT \(base)
            WHERE m.text LIKE ? ESCAPE '\\' AND c.is_archived = 0 AND \(notTapback)\(sinceClause)
            ORDER BY m.date DESC LIMIT ?
            """, arguments: StatementArguments(q1args))

            // Q2 — recent messages whose body is only in attributedBody. SQL can't
            // search the blob, so decode + substring-match in Swift, bounded by the
            // scan cap.
            var q2args: [any DatabaseValueConvertible] = []
            if let cutoffNs { q2args.append(cutoffNs) }
            q2args.append(Self.searchAttributedScanCap)
            let q2 = try Row.fetchAll(db, sql: """
            SELECT \(base)
            WHERE m.attributedBody IS NOT NULL AND (m.text IS NULL OR m.text = '')
              AND c.is_archived = 0 AND \(notTapback)\(sinceClause)
            ORDER BY m.date DESC LIMIT ?
            """, arguments: StatementArguments(q2args))

            // If Q2 returned a full cap's worth of blob-only rows, there may be
            // older blob-only messages that went unscanned — a "no match" here
            // is therefore not authoritative. (pippin-wve)
            let scanTruncated = q2.count >= Self.searchAttributedScanCap

            // Merge, dedup by guid. Q1 rows already matched via LIKE; Q2 rows are
            // confirmed with a Swift substring check on the decoded body.
            var byGuid: [String: (row: Row, body: String)] = [:]
            func consider(_ row: Row, requireMatch: Bool) {
                guard let body = Self.resolveBody(text: row["text"], attributedBody: row["attributedBody"])
                else { return }
                if requireMatch, !body.lowercased().contains(needle) { return }
                let guid: String = row["msg_guid"] ?? ""
                byGuid[guid] = (row, body)
            }
            for row in q1 {
                consider(row, requireMatch: false)
            }
            for row in q2 {
                consider(row, requireMatch: true)
            }

            var excludedCount = 0
            var kept: [(row: Row, body: String)] = []
            for candidate in byGuid.values.sorted(by: { ($0.row["date"] as Int64? ?? 0) > ($1.row["date"] as Int64? ?? 0) }) {
                let conversationId: String = candidate.row["chat_guid"] ?? ""
                if excluded.contains(conversationId) {
                    excludedCount += 1
                    continue
                }
                kept.append(candidate)
                if kept.count >= limit { break }
            }

            let attachmentsByRowId = try Self.fetchAttachments(
                db: db, messageRowIds: kept.compactMap { $0.row["msg_rowid"] as Int64? }
            )
            let results = kept.map { candidate -> MessageItem in
                let rowId: Int64 = candidate.row["msg_rowid"] ?? 0
                return Self.messageItem(
                    from: candidate.row,
                    conversationId: candidate.row["chat_guid"] ?? "",
                    body: candidate.body,
                    contactIndex: contactIndex,
                    attachments: attachmentsByRowId[rowId]
                )
            }
            return (results, excludedCount, scanTruncated)
        }
    }

    public func showConversation(
        conversationId: String,
        limit: Int = 50,
        contactIndex: ContactIndex = ContactIndex()
    ) throws -> (conversation: MessageConversation, messages: [MessageItem], truncated: Bool) {
        let limit = Self.clampLimit(limit)
        return try readWrapping { db in
            // TCC privacy masking: on newer macOS, phone numbers in the `guid`
            // column are returned with middle digits replaced by `*` (e.g.
            // `any;-;+151****2328` instead of `any;-;+151****2328`).  An exact
            // `guid = ?` match then fails because the stored value has real digits.
            // If the caller's ID contains `*`, try a LIKE match (mapping `*` → `_`).
            // Also fall back to `chat_identifier` (which holds the bare handle,
            // e.g. `+151****2328`) by stripping any `service;-;` prefix.
            func makeQuery() throws -> Row? {
                if conversationId.contains("*") {
                    let likePattern = conversationId.replacingOccurrences(of: "*", with: "_")
                    return try Row.fetchOne(
                        db,
                        sql: """
                        SELECT ROWID, guid, chat_identifier, service_name, display_name, room_name, style
                        FROM chat WHERE guid LIKE ? ESCAPE '\\'
                        """,
                        arguments: [likePattern]
                    )
                } else {
                    return try Row.fetchOne(
                        db,
                        sql: """
                        SELECT ROWID, guid, chat_identifier, service_name, display_name, room_name, style
                        FROM chat WHERE guid = ?
                        """,
                        arguments: [conversationId]
                    )
                }
            }
            // Fallback: if still not found, try chat_identifier by stripping the
            // `service;-;` prefix (e.g. `any;-;+151****2328` → `+151****2328`).
            guard let chatRow: Row = try (makeQuery() ?? Row.fetchOne(
                db,
                sql: """
                SELECT ROWID, guid, chat_identifier, service_name, display_name, room_name, style
                FROM chat WHERE chat_identifier = ?
                """,
                arguments: [conversationId.components(separatedBy: ";").last ?? conversationId]
            )) else {
                throw MessagesError.conversationNotFound(conversationId)
            }
            let chatRowId: Int64 = chatRow["ROWID"] ?? 0
            let chatGuid: String = chatRow["guid"] ?? conversationId

            let participants = try Self.fetchParticipants(
                db: db, chatRowIds: [chatRowId], contactIndex: contactIndex
            )[chatRowId] ?? []

            // Fetch limit + 1 rows so we know whether older messages exist
            // without a separate COUNT(*) round-trip.
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT m.ROWID AS msg_rowid, m.guid AS msg_guid, m.text, m.attributedBody, m.date,
                       m.is_from_me, m.is_read, m.service, h.id AS handle_id
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                LEFT JOIN handle h ON h.ROWID = m.handle_id
                WHERE cmj.chat_id = ? AND \(Self.excludeTapbacks("m"))
                ORDER BY m.date DESC LIMIT ?
                """,
                arguments: [chatRowId, limit + 1]
            )
            let truncated = rows.count > limit
            let trimmed = truncated ? Array(rows.prefix(limit)) : rows

            let attachmentsByRowId = try Self.fetchAttachments(
                db: db, messageRowIds: trimmed.compactMap { $0["msg_rowid"] as Int64? }
            )
            let messages: [MessageItem] = trimmed.reversed().map { row in
                let rowId: Int64 = row["msg_rowid"] ?? 0
                return Self.messageItem(
                    from: row,
                    conversationId: chatGuid,
                    body: Self.resolveBody(text: row["text"], attributedBody: row["attributedBody"]),
                    contactIndex: contactIndex,
                    attachments: attachmentsByRowId[rowId]
                )
            }

            // Same unread definition as listConversations' subquery: inbound,
            // unread, non-tapback.
            let unreadSQL = """
            SELECT COUNT(*) FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE cmj.chat_id = ? AND m.is_from_me = 0 AND m.is_read = 0
              AND \(Self.excludeTapbacks("m"))
            """
            let unreadCount = try Int.fetchOne(db, sql: unreadSQL, arguments: [chatRowId]) ?? 0

            let style: Int = chatRow["style"] ?? 0
            let conversation = MessageConversation(
                id: chatGuid,
                service: chatRow["service_name"] ?? "",
                displayName: Self.conversationDisplayName(
                    explicit: chatRow["display_name"] ?? chatRow["room_name"], participants: participants
                ),
                participants: participants,
                isGroup: style == Self.groupChatStyle,
                lastMessageAt: messages.last?.date,
                lastMessagePreview: messages.last?.text.map { Self.preview($0) },
                unreadCount: unreadCount
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
    /// Conversation title: the explicit chat name (group `display_name`/`room_name`)
    /// when set, else — for a 1:1 thread — the single participant's resolved
    /// contact name, so a DM shows "Alice" instead of a bare phone number.
    static func conversationDisplayName(explicit: String?, participants: [MessageParticipant]) -> String? {
        if let explicit, !explicit.isEmpty { return explicit }
        if participants.count == 1 { return participants[0].displayName }
        return nil
    }

    private static func fetchParticipants(
        db: Database,
        chatRowIds: [Int64],
        contactIndex: ContactIndex = ContactIndex()
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
            let handle: String = row["id"] ?? ""
            let participant = MessageParticipant(
                handle: handle,
                service: row["service"] ?? "",
                displayName: contactIndex.displayName(for: handle)
            )
            byChat[chatId, default: []].append(participant)
        }
        return byChat
    }

    /// Batch-fetch attachment metadata for the supplied message ROWIDs, grouped
    /// into `[messageRowId: [attachment]]`. Absent key = no attachments (so
    /// callers pass `map[rowId]` straight through as an optional). The display
    /// name prefers `transfer_name`; `filename` is often a full on-disk path,
    /// so fall back to its last path component.
    private static func fetchAttachments(
        db: Database,
        messageRowIds: [Int64]
    ) throws -> [Int64: [MessageAttachment]] {
        guard !messageRowIds.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: messageRowIds.count).joined(separator: ",")
        let sql = """
        SELECT maj.message_id, a.transfer_name, a.filename, a.mime_type
        FROM message_attachment_join maj
        JOIN attachment a ON a.ROWID = maj.attachment_id
        WHERE maj.message_id IN (\(placeholders))
        ORDER BY a.ROWID
        """
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(messageRowIds))
        var byMessage: [Int64: [MessageAttachment]] = [:]
        for row in rows {
            let messageId: Int64 = row["message_id"] ?? 0
            let transferName: String? = row["transfer_name"]
            let path: String? = row["filename"]
            let name = [transferName, path.map { ($0 as NSString).lastPathComponent }]
                .compactMap { $0 }
                .first { !$0.isEmpty }
            byMessage[messageId, default: []].append(
                MessageAttachment(filename: name, mimeType: row["mime_type"])
            )
        }
        return byMessage
    }

    static func date(fromAppleNanos nanos: Int64) -> Date {
        // Foundation's reference date IS 2001-01-01 UTC, same as Apple's
        // Messages epoch. Distinguish nanos from legacy seconds by magnitude.
        let seconds: TimeInterval = nanos > 1_000_000_000_000
            ? TimeInterval(nanos) / 1_000_000_000
            : TimeInterval(nanos)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Normalize a caller-supplied row limit before it reaches SQL or arithmetic.
    /// `--limit` is an unbounded CLI option, so two failure modes are possible:
    ///   - negative → SQLite treats `LIMIT -1` as *unbounded*, fetching the whole
    ///     (potentially huge) Messages DB into memory;
    ///   - near `Int.max` → `limit + 1` / `limit + excluded.count` overflow-trap.
    /// Clamp to `[0, maxLimit]` so every query method is safe regardless of input.
    static func clampLimit(_ limit: Int) -> Int {
        let maxLimit = 100_000 // far beyond any practical CLI/MCP request
        return max(0, min(limit, maxLimit))
    }

    static func appleNanos(from date: Date) -> Int64 {
        // `Int64(Double)` traps if the value is outside Int64's range (a date
        // beyond ~year 2293 overflows once multiplied by 1e9). Clamp instead of
        // crashing — the result is only ever used as a "since" cutoff bound.
        let nanos = date.timeIntervalSinceReferenceDate * 1_000_000_000
        if nanos >= Double(Int64.max) { return Int64.max }
        if nanos <= Double(Int64.min) { return Int64.min }
        return Int64(nanos)
    }

    static func iso8601(fromAppleNanos nanos: Int64) -> String {
        ISO8601DateFormatter().string(from: date(fromAppleNanos: nanos))
    }

    static func preview(_ text: String, limit: Int = 140) -> String {
        TextFormatter.truncate(text.replacingOccurrences(of: "\n", with: " "), to: limit)
    }

    /// Map a `message`-join row to a `MessageItem`. Shared by `showConversation`
    /// and `searchMessages` so the column→field mapping lives in one place. The
    /// caller supplies `conversationId` (the chat guid, which differs in scope
    /// between the two queries), the already-resolved `body`, and a `contactIndex`
    /// to tie the sender handle to an Apple Contacts name.
    static func messageItem(
        from row: Row,
        conversationId: String,
        body: String?,
        contactIndex: ContactIndex = ContactIndex(),
        attachments: [MessageAttachment]? = nil
    ) -> MessageItem {
        let handle: String? = row["handle_id"]
        return MessageItem(
            id: row["msg_guid"] ?? "",
            conversationId: conversationId,
            date: iso8601(fromAppleNanos: row["date"] ?? 0),
            text: body,
            fromHandle: handle,
            fromDisplayName: handle.flatMap { contactIndex.displayName(for: $0) },
            isFromMe: (row["is_from_me"] ?? 0) == 1,
            isRead: (row["is_read"] ?? 0) == 1,
            service: row["service"] ?? "",
            attachments: attachments
        )
    }

    /// Object-replacement character that marks an inline attachment in a decoded
    /// `attributedBody`. Stripped so attachment-only messages read as "no text".
    private static let objectReplacement = "\u{FFFC}"

    /// Resolve a message's body text. Modern macOS leaves `message.text` NULL and
    /// stores the body in `message.attributedBody` (a typedstream blob), so prefer
    /// a non-empty `text` column and otherwise decode the blob. Returns nil when
    /// there's no readable text (e.g. an attachment-only message). (pippin-cc1)
    static func resolveBody(text: String?, attributedBody: Data?) -> String? {
        if let text, !text.isEmpty { return text }
        guard let blob = attributedBody, !blob.isEmpty,
              let decoded = PippinDecodeAttributedBody(blob)
        else { return nil }
        return cleanDecodedBody(decoded)
    }

    /// Normalize a decoded `attributedBody` string: strip inline-attachment
    /// markers and surrounding whitespace; nil if nothing readable remains. Pure
    /// (no decode) so it's unit-testable.
    static func cleanDecodedBody(_ decoded: String) -> String? {
        let cleaned = decoded
            .replacingOccurrences(of: objectReplacement, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Escape SQLite LIKE metacharacters so a user query is treated as a
    /// literal substring. Uses `\` as the escape character; paired with
    /// `ESCAPE '\\'` in the SQL clause.
    static func escapeLike(_ pattern: String) -> String {
        pattern
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
