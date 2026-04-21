import ArgumentParser
import CryptoKit
import Foundation

// MARK: - Cursor

/// Opaque pagination state. Encoded as base64url(JSON) for `--cursor` tokens.
public struct Cursor: Codable, Equatable {
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
public struct Page<T: Encodable>: Encodable {
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

public enum CursorError: LocalizedError {
    case cursorMismatch
    case invalidCursor
    case invalidPageSize

    public var errorDescription: String? {
        switch self {
        case .cursorMismatch:
            return "Cursor was issued for a different query (filter_hash does not match current arguments)."
        case .invalidCursor:
            return "Cursor token is malformed or unreadable."
        case .invalidPageSize:
            return "--page-size must be a positive integer."
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

    public init() {}

    /// True if either flag was passed — switch the response shape to {items, next_cursor}.
    public var isActive: Bool {
        cursor != nil || pageSize != nil
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
        var offset = 0
        if let token = opts.cursor {
            let parsed = try decode(token)
            guard parsed.filterHash == filterHash else { throw CursorError.cursorMismatch }
            offset = max(0, parsed.offset)
        }
        let pageSize = opts.pageSize ?? defaultPageSize
        guard pageSize > 0 else { throw CursorError.invalidPageSize }
        return (offset, pageSize)
    }

    /// Slice an in-memory array into a Page<T>.
    public static func paginate<T: Encodable>(
        all: [T],
        offset: Int,
        pageSize: Int,
        filterHash: String
    ) throws -> Page<T> {
        let safeOffset = max(0, offset)
        guard safeOffset < all.count else {
            return Page(items: [], nextCursor: nil)
        }
        let end = min(all.count, safeOffset + pageSize)
        let items = Array(all[safeOffset ..< end])
        let nextCursor: String? = end < all.count
            ? try encode(Cursor(offset: end, filterHash: filterHash))
            : nil
        return Page(items: items, nextCursor: nextCursor)
    }

    /// Build a Page<T> when the bridge already pushed offset/limit down.
    /// Caller fetched `pageSize + 1` items at `offset`; the +1 sentinel signals
    /// whether more pages exist.
    public static func pageFromPushdown<T: Encodable>(
        fetched: [T],
        offset: Int,
        pageSize: Int,
        filterHash: String
    ) throws -> Page<T> {
        let hasMore = fetched.count > pageSize
        let items = Array(fetched.prefix(pageSize))
        let nextCursor: String? = hasMore
            ? try encode(Cursor(offset: offset + pageSize, filterHash: filterHash))
            : nil
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
