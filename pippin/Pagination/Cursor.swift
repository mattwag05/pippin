import ArgumentParser
import CryptoKit
import Foundation

// MARK: - Cursor

/// Opaque pagination state. Encoded as base64url(JSON) for `--cursor` tokens.
public struct Cursor: Codable, Equatable, Sendable {
    public let offset: Int
    public let filterHash: String
    /// Position of the last row served, for sources that can seek by sort key.
    /// An offset into a newest-first list repeats or skips rows once new rows
    /// arrive between calls; the anchor does not. Absent on cursors issued
    /// before this field existed, which keep their offset meaning.
    public let anchor: Anchor?

    /// Sort key and tiebreak id of a row in an `ORDER BY key DESC, id ASC` list.
    public struct Anchor: Codable, Equatable, Sendable {
        public let epoch: Int64
        public let rowid: Int64
        /// Tiebreak for sources whose ids are strings (rowid is 0 then).
        public let id: String?

        public init(epoch: Int64, rowid: Int64 = 0, id: String? = nil) {
            self.epoch = epoch
            self.rowid = rowid
            self.id = id
        }
    }

    enum CodingKeys: String, CodingKey {
        case offset
        case filterHash = "filter_hash"
        case anchor
    }

    public init(offset: Int, filterHash: String, anchor: Anchor? = nil) {
        self.offset = offset
        self.filterHash = filterHash
        self.anchor = anchor
    }
}

// MARK: - Page<T>

/// Wrapped list response when pagination is active.
/// Shape: `{"items": [...], "next_cursor": "..."}` (next_cursor omitted when exhausted).
public struct Page<T: Encodable & Sendable>: Encodable, Sendable {
    public let items: [T]
    public let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
    }

    public init(items: [T], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
        try container.encodeIfPresent(nextCursor, forKey: .nextCursor)
    }
}

// MARK: - Errors

public enum CursorError: LocalizedError, Sendable {
    case cursorMismatch
    case invalidCursor
    case invalidPageSize
    case invalidPage

    public var errorDescription: String? {
        switch self {
        case .cursorMismatch:
            return "Cursor was issued for a different query (filter_hash does not match current arguments)."
        case .invalidCursor:
            return "Cursor token is malformed or unreadable."
        case .invalidPageSize:
            return "--page-size must be a positive integer."
        case .invalidPage:
            return "--page must be 1 or greater."
        }
    }
}

extension CursorError: RemediableError {
    public var agentCode: String {
        switch self {
        case .cursorMismatch: return "cursor_mismatch"
        case .invalidCursor: return "invalid_cursor"
        case .invalidPageSize: return "invalid_page_size"
        case .invalidPage: return "invalid_page"
        }
    }

    public var nextStep: NextStep {
        switch self {
        case .cursorMismatch, .invalidCursor, .invalidPageSize, .invalidPage: return .none
        }
    }
}

// MARK: - PaginationOptions

/// Shared `--cursor` / `--page-size` flag pair. Mix into any list command via
/// `@OptionGroup`.
public struct PaginationOptions: ParsableArguments {
    @Option(name: .long, help: "Opaque pagination cursor from a previous response's next_cursor.")
    public var cursor: String?

    @Option(name: .long, help: "Page size when paginating (default: command's existing --limit).")
    public var pageSize: Int?

    @Option(name: .long, help: "Page number (1-based; page size is --page-size or --limit). Ignored when --cursor is set.")
    public var page: Int?

    public init() {}

    /// True if any pagination flag was passed. `data` stays the item array either way;
    /// the cursor for the next page goes in the envelope's top-level `next_cursor`.
    public var isActive: Bool {
        cursor != nil || pageSize != nil || page != nil
    }
}

// MARK: - Pagination helpers

public enum Pagination {
    /// Encode a cursor into the opaque base64url token.
    public static func encode(_ cursor: Cursor) throws -> String {
        let data = try JSONEncoder().encode(cursor)
        return base64URLEncode(data)
    }

    /// Decode an opaque token back to a Cursor. Throws CursorError.invalidCursor.
    public static func decode(_ token: String) throws -> Cursor {
        guard let data = base64URLDecode(token) else { throw CursorError.invalidCursor }
        do {
            return try JSONDecoder().decode(Cursor.self, from: data)
        } catch {
            throw CursorError.invalidCursor
        }
    }

    /// Stable hash over normalized filter args (sorted, lowercased, nils/empties
    /// dropped). Truncated to 16 hex chars — change-detection only, no security
    /// surface, so a partial digest is sufficient.
    public static func filterHash(_ args: [String: String?]) -> String {
        let normalized = args
            .compactMapValues { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .map { key, value in (key.lowercased(), value.lowercased()) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    /// Resolve PaginationOptions to a concrete (offset, pageSize) pair.
    /// Validates the cursor's filter_hash matches the supplied hash.
    public static func resolve(
        _ opts: PaginationOptions,
        defaultPageSize: Int,
        filterHash: String
    ) throws -> (offset: Int, pageSize: Int) {
        let requested = opts.pageSize ?? defaultPageSize
        guard requested > 0 else { throw CursorError.invalidPageSize }
        // Cap the page size at a sane ceiling. `--page-size` is an unbounded
        // user option, and an enormous value would otherwise (a) overflow-trap
        // `pageSize + 1` fetches and `offset + pageSize` cursor math, and
        // (b) ask a bridge to materialize an absurd number of rows. The cap is
        // far beyond any real page; deep pagination still walks via the cursor.
        let pageSize = min(requested, maxPageSize)

        var offset = 0
        if let token = opts.cursor {
            let parsed = try decode(token)
            guard parsed.filterHash == filterHash else { throw CursorError.cursorMismatch }
            offset = max(0, parsed.offset)
        } else if let page = opts.page {
            // Numbered pages are sugar over the cursor offset: page N starts at
            // (N-1)*pageSize. A --cursor, when present, wins over --page.
            guard page >= 1 else { throw CursorError.invalidPage }
            let (product, overflow) = (page - 1).multipliedReportingOverflow(by: pageSize)
            guard !overflow else { throw CursorError.invalidPage } // unchecked, this traps
            offset = product
        }
        return (offset, pageSize)
    }

    /// The keyset anchor carried by `--cursor`, if any. Call after `resolve`,
    /// which has already validated the token and its filter hash.
    public static func anchor(of opts: PaginationOptions) -> Cursor.Anchor? {
        opts.cursor.flatMap { try? decode($0) }?.anchor
    }

    /// Upper bound for a single page (see `resolve`). Generous — real pages are
    /// tens to low-hundreds of items; this only fences off pathological input.
    static let maxPageSize = 100_000

    /// Slice an in-memory array into a Page<T>.
    public static func paginate<T: Encodable & Sendable>(
        all: [T],
        offset: Int,
        pageSize: Int,
        filterHash: String,
        anchor: (T) -> Cursor.Anchor? = { _ in nil }
    ) throws -> Page<T> {
        let safeOffset = max(0, offset)
        guard safeOffset < all.count else {
            return Page(items: [], nextCursor: nil)
        }
        // Compute `end` without `safeOffset + pageSize`, which overflow-traps for
        // a huge pageSize. `take` is bounded by the remaining count, so the sum
        // can never exceed all.count.
        let remaining = all.count - safeOffset
        let take = max(0, min(pageSize, remaining))
        let end = safeOffset + take
        let items = Array(all[safeOffset ..< end])
        let nextCursor: String? = end < all.count
            ? try encode(Cursor(offset: end, filterHash: filterHash, anchor: items.last.flatMap(anchor)))
            : nil
        return Page(items: items, nextCursor: nextCursor)
    }

    /// Index of the first row after `anchor` in a (key, id)-ordered list; `offset`
    /// when the anchor carries no id. See `paginateKeyset`.
    public static func keysetStart<T>(
        in all: [T], offset: Int, anchor: Cursor.Anchor?,
        key: (T) -> Int64, id: (T) -> String, descending: Bool = false
    ) -> Int {
        guard let anchor, let anchorId = anchor.id else { return offset }
        return all.firstIndex { id($0) == anchorId }.map { $0 + 1 }
            ?? all.firstIndex { row in
                let k = key(row)
                return (descending ? k < anchor.epoch : k > anchor.epoch) || (k == anchor.epoch && id(row) > anchorId)
            } ?? all.count
    }

    /// In-memory keyset page over a list ordered by `key` (ascending, or
    /// descending when `descending`), ties by `id` ascending. Resumes after the
    /// anchor row; when that row is gone, at the first row sorting after the
    /// anchor, so rows added or removed between calls cannot repeat or skip one.
    /// Without an id anchor (first page, legacy cursor) `offset` applies.
    public static func paginateKeyset<T: Encodable & Sendable>(
        all: [T],
        offset: Int,
        pageSize: Int,
        filterHash: String,
        anchor: Cursor.Anchor?,
        key: (T) -> Int64,
        id: (T) -> String,
        descending: Bool = false
    ) throws -> Page<T> {
        let start = keysetStart(in: all, offset: offset, anchor: anchor, key: key, id: id, descending: descending)
        return try paginate(
            all: all, offset: start, pageSize: pageSize, filterHash: filterHash,
            anchor: { Cursor.Anchor(epoch: key($0), id: id($0)) }
        )
    }

    /// Build a Page<T> when the bridge already pushed offset/limit down.
    /// Caller fetched `pageSize + 1` items at `offset`; the +1 sentinel signals
    /// whether more pages exist.
    public static func pageFromPushdown<T: Encodable & Sendable>(
        fetched: [T],
        offset: Int,
        pageSize: Int,
        filterHash: String,
        anchor: (T) -> Cursor.Anchor? = { _ in nil }
    ) throws -> Page<T> {
        let take = max(0, pageSize)
        let hasMore = fetched.count > take
        let items = Array(fetched.prefix(take))
        // `offset + pageSize` can overflow when a crafted cursor carries a huge
        // offset; report-overflow and drop the next cursor rather than trap.
        var nextCursor: String?
        if hasMore {
            let (nextOffset, overflowed) = offset.addingReportingOverflow(take)
            nextCursor = overflowed ? nil : try encode(
                Cursor(offset: nextOffset, filterHash: filterHash, anchor: items.last.flatMap(anchor))
            )
        }
        return Page(items: items, nextCursor: nextCursor)
    }
}

// MARK: - base64url

private func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func base64URLDecode(_ token: String) -> Data? {
    var s = token
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let pad = (4 - s.count % 4) % 4
    if pad > 0 { s.append(String(repeating: "=", count: pad)) }
    return Data(base64Encoded: s)
}
