import Foundation
import GRDB

public struct VoiceMemo: Codable, FetchableRecord, Sendable {
    public let id: String
    public let title: String
    public let durationSeconds: Double
    public let createdAt: Date
    /// Absolute path to the audio file. The DB stores only the bare `ZPATH`
    /// filename; `VoiceMemosDB` resolves it against the recordings directory
    /// before rows leave the bridge. Empty when the recording has no local
    /// file (NULL ZPATH — e.g. not yet downloaded from iCloud).
    public var filePath: String
    /// Full transcript text — populated only by `memos info` from the
    /// transcript cache (list stays lightweight via `hasTranscript`).
    public var transcription: String?
    /// Whether a cached transcript exists for this memo (transcripts.db).
    public var hasTranscript: Bool
    /// Whether the audio has been evicted to iCloud (not available locally) —
    /// transcribe/export will fail until the recording is re-downloaded.
    public let isEvicted: Bool

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
        hasTranscript = false
        isEvicted = (row["ZEVICTIONDATE"] as Double?) != nil
    }

    /// Standard init for testing and export results
    public init(
        id: String,
        title: String,
        durationSeconds: Double,
        createdAt: Date,
        filePath: String,
        transcription: String? = nil,
        hasTranscript: Bool = false,
        isEvicted: Bool = false
    ) {
        self.id = id
        self.title = title
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
        self.filePath = filePath
        self.transcription = transcription
        self.hasTranscript = hasTranscript
        self.isEvicted = isEvicted
    }

    /// Custom Codable encoding with camelCase and ISO 8601 date
    enum CodingKeys: String, CodingKey {
        case id, title, durationSeconds, createdAt, filePath, transcription, hasTranscript, isEvicted
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        let formatter = ISO8601DateFormatter()
        // Fractional seconds for cross-module consistency (mail/calendar emit ".000Z").
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try container.encode(formatter.string(from: createdAt), forKey: .createdAt)
        try container.encode(filePath, forKey: .filePath)
        try container.encode(transcription, forKey: .transcription)
        try container.encode(hasTranscript, forKey: .hasTranscript)
        try container.encode(isEvicted, forKey: .isEvicted)
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
