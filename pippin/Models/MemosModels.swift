import Foundation
import GRDB

public struct VoiceMemo: Codable, FetchableRecord, Sendable {
    public let id: String
    public let title: String
    public let durationSeconds: Double
    public let createdAt: Date
    public let filePath: String
    public let transcription: String?

    /// Custom FetchableRecord init mapping Core Data columns.
    ///
    /// Every column is decoded *optionally* with a fallback: GRDB traps
    /// (fatalError) when a non-optional `row["COL"]` hits a NULL or absent
    /// value, and Apple's Voice Memos DB legitimately stores NULLs — e.g.
    /// `ZPATH`/`ZDURATION` are null for an iCloud recording not yet downloaded
    /// or a capture still in progress. A single such row must not crash the
    /// whole `memos list`; it degrades to empty/zero fields instead.
    public init(row: Row) {
        id = (row["ZUNIQUEID"] as String?) ?? ""
        title = (row["ZCUSTOMLABELFORSORTING"] as String?) ?? "Untitled"
        durationSeconds = (row["ZDURATION"] as Double?) ?? 0
        // Core Data epoch: seconds since 2001-01-01 UTC
        let coreDataTimestamp = (row["ZDATE"] as Double?) ?? 0
        createdAt = Date(timeIntervalSinceReferenceDate: coreDataTimestamp)
        filePath = (row["ZPATH"] as String?) ?? ""
        transcription = nil
    }

    /// Standard init for testing and export results
    public init(
        id: String,
        title: String,
        durationSeconds: Double,
        createdAt: Date,
        filePath: String,
        transcription: String? = nil
    ) {
        self.id = id
        self.title = title
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
        self.filePath = filePath
        self.transcription = transcription
    }

    /// Custom Codable encoding with camelCase and ISO 8601 date
    enum CodingKeys: String, CodingKey {
        case id, title, durationSeconds, createdAt, filePath, transcription
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        try container.encode(formatter.string(from: createdAt), forKey: .createdAt)
        try container.encode(filePath, forKey: .filePath)
        try container.encode(transcription, forKey: .transcription)
    }
}

public struct ExportResult: Codable, Sendable {
    public let id: String
    public let title: String
    public let exportedTo: String
    public let transcription: String?
    public let transcriptionFile: String?
}

public struct TranscribeResult: Codable, Sendable {
    public let id: String
    public let title: String
    public let transcription: String
    public let outputFile: String?
}
