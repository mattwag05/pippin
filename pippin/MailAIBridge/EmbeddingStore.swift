import Accelerate
import Foundation
import GRDB

public struct EmbeddingRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "email_embeddings"

    public let compoundId: String
    public let embedding: Data
    public let bodyHash: String
    public let model: String
    public let indexedAt: String

    public init(compoundId: String, embedding: Data, bodyHash: String, model: String, indexedAt: String) {
        self.compoundId = compoundId
        self.embedding = embedding
        self.bodyHash = bodyHash
        self.model = model
        self.indexedAt = indexedAt
    }

    enum CodingKeys: String, CodingKey {
        case compoundId = "compound_id"
        case embedding
        case bodyHash = "body_hash"
        case model
        case indexedAt = "indexed_at"
    }
}

public final class EmbeddingStore: Sendable {
    public static func defaultStorePath() -> String {
        let home = NSHomeDirectory()
        return "\(home)/.config/pippin/mail-embeddings.db"
    }

    private let dbQueue: DatabaseQueue

    public init(dbPath: String? = nil) throws {
        let path = dbPath ?? EmbeddingStore.defaultStorePath()
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        dbQueue = try DatabaseQueue(path: path)
        try migrate()
    }

    // MARK: - Migration

    private func migrate() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS email_embeddings (
                compound_id  TEXT PRIMARY KEY,
                embedding    BLOB NOT NULL,
                body_hash    TEXT NOT NULL,
                model        TEXT NOT NULL,
                indexed_at   TEXT NOT NULL
            )
            """)
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_embeddings_indexed_at ON email_embeddings(indexed_at)
            """)
        }
    }

    // MARK: - Public API

    public func exists(compoundId: String) -> Bool {
        (try? dbQueue.read { db in
            try EmbeddingRecord.fetchOne(db, key: compoundId)
        }) != nil
    }

    public func needsReindex(compoundId: String, bodyHash: String) throws -> Bool {
        try dbQueue.read { db in
            guard let record = try EmbeddingRecord.fetchOne(
                db,
                sql: "SELECT * FROM email_embeddings WHERE compound_id = ?",
                arguments: [compoundId]
            ) else {
                return true
            }
            return record.bodyHash != bodyHash
        }
    }

    public func upsert(_ record: EmbeddingRecord) throws {
        try dbQueue.write { db in
            try record.save(db)
        }
    }

    public func get(compoundId: String) throws -> EmbeddingRecord? {
        try dbQueue.read { db in
            try EmbeddingRecord.fetchOne(
                db,
                sql: "SELECT * FROM email_embeddings WHERE compound_id = ?",
                arguments: [compoundId]
            )
        }
    }

    public func allEmbeddings() throws -> [EmbeddingRecord] {
        try dbQueue.read { db in
            try EmbeddingRecord.fetchAll(db, sql: "SELECT * FROM email_embeddings")
        }
    }

    public func count() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM email_embeddings") ?? 0
        }
    }

    public func isEmpty() throws -> Bool {
        try count() == 0
    }
}

// MARK: - Free functions

public func serializeEmbedding(_ floats: [Float]) -> Data {
    floats.withUnsafeBufferPointer { ptr in
        Data(buffer: ptr)
    }
}

public func deserializeEmbedding(_ data: Data) -> [Float] {
    data.withUnsafeBytes { rawPtr in
        Array(rawPtr.bindMemory(to: Float.self))
    }
}

public func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Float = 0
    var magA: Float = 0
    var magB: Float = 0
    vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
    vDSP_dotpr(a, 1, a, 1, &magA, vDSP_Length(a.count))
    vDSP_dotpr(b, 1, b, 1, &magB, vDSP_Length(b.count))
    guard magA > 0, magB > 0 else { return 0 }
    return dot / (sqrtf(magA) * sqrtf(magB))
}
