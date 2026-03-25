import Foundation

public struct IndexResult: Codable, Sendable {
    public let indexed: Int
    public let skipped: Int
    public let total: Int

    public init(indexed: Int, skipped: Int, total: Int) {
        self.indexed = indexed
        self.skipped = skipped
        self.total = total
    }
}
