import ArgumentParser
import CryptoKit
import Foundation

// MARK: - Cursor

/// Opaque pagination state. Encoded as base64url(JSON) for `--cursor` tokens.
public struct Cursor: Codable, Equatable, Sendable {
    public let offset: Int
    public let filterHash: String

    enum CodingKeys: String, CodingKey {
        case offset
        case filterHash = "filter_hash"
    }

    public init(offset: Int, filterHash: String) {
        self.offset = offset
        self.filterHash = filterHash
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

    /// True if any pagination flag was passed — switch the response shape to {items, next_cursor}.
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
            offset = (page - 1) * pageSize
        }
        return (offset, pageSize)
    }

    /// Upper bound for a single page (see `resolve`). Generous — real pages are
    /// tens to low-hundreds of items; this only fences off pathological input.
    static let maxPageSize = 100_000

    /// Slice an in-memory array into a Page<T>.
    public static func paginate<T: Encodable & Sendable>(
        all: [T],
        offset: Int,
        pageSize: Int,
        filterHash: String
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
            ? try encode(Cursor(offset: end, filterHash: filterHash))
            : nil
        return Page(items: items, nextCursor: nextCursor)
    }

    /// Build a Page<T> when the bridge already pushed offset/limit down.
    /// Caller fetched `pageSize + 1` items at `offset`; the +1 sentinel signals
    /// whether more pages exist.
    public static func pageFromPushdown<T: Encodable & Sendable>(
        fetched: [T],
        offset: Int,
        pageSize: Int,
        filterHash: String
    ) throws -> Page<T> {
        let take = max(0, pageSize)
        let hasMore = fetched.count > take
        let items = Array(fetched.prefix(take))
        // `offset + pageSize` can overflow when a crafted cursor carries a huge
        // offset; report-overflow and drop the next cursor rather than trap.
        var nextCursor: String?
        if hasMore {
            let (nextOffset, overflowed) = offset.addingReportingOverflow(take)
            nextCursor = overflowed ? nil : try encode(Cursor(offset: nextOffset, filterHash: filterHash))
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
