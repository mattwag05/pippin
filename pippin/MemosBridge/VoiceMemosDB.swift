import Foundation
import GRDB

public enum VoiceMemosError: LocalizedError, Sendable {
    case databaseNotFound(String)
    case unsupportedSchemaVersion(Int)
    case memoNotFound(String)
    case memoEvicted(String)
    case fileNotFound(String)
    case exportFailed(String)
    case ambiguousId(String, [String])

    public var errorDescription: String? {
        switch self {
        case let .databaseNotFound(path):
            return "Voice Memos database not found at: \(path)"
        case let .unsupportedSchemaVersion(version):
            return "Unsupported Voice Memos schema version: \(version). Known versions: \(VoiceMemosDB.knownSchemaVersions)"
        case let .memoNotFound(id):
            return "No recording found with ID: \(id)"
        case let .memoEvicted(id):
            return "Recording \(id) is iCloud-evicted (not downloaded locally)"
        case let .fileNotFound(path):
            return "Recording file not found: \(path)"
        case let .exportFailed(detail):
            return "Export failed: \(detail)"
        case let .ambiguousId(prefix, matches):
            return "Ambiguous ID prefix '\(prefix)' matches \(matches.count) recordings: \(matches.joined(separator: ", "))"
        }
    }
}

public final class VoiceMemosDB: Sendable {
    /// Schema versions confirmed to work with this code.
    /// Update after macOS upgrades if Z_VERSION changes.
    static let knownSchemaVersions: Set<Int> = [1]

    private let dbQueue: DatabaseQueue
    private let recordingsDir: String

    // MARK: - Default DB path

    /// Default Voice Memos database path on macOS 14+.
    public static func defaultDBPath() -> String {
        let home = NSHomeDirectory()
        return "\(home)/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db"
    }

    /// Default recordings directory (parent of the DB file).
    public static func defaultRecordingsDir() -> String {
        let home = NSHomeDirectory()
        return "\(home)/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"
    }

    // MARK: - Init

    /// Open the Voice Memos database at the given path.
    /// Validates schema version on open.
    public init(dbPath: String) throws {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw VoiceMemosError.databaseNotFound(dbPath)
        }
        var config = Configuration()
        config.readonly = true
        dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
        recordingsDir = (dbPath as NSString).deletingLastPathComponent
        try validateSchema()
    }

    /// Init with a pre-created DatabaseQueue (for testing with in-memory databases).
    /// `recordingsDir` defaults to a temporary directory.
    public init(dbQueue: DatabaseQueue, recordingsDir: String? = nil) throws {
        self.dbQueue = dbQueue
        self.recordingsDir = recordingsDir ?? NSTemporaryDirectory()
        try validateSchema()
    }

    // MARK: - Schema validation

    private func validateSchema() throws {
        let version = try dbQueue.read { db -> Int in
            try Int.fetchOne(db, sql: "SELECT Z_VERSION FROM Z_METADATA") ?? 0
        }
        guard VoiceMemosDB.knownSchemaVersions.contains(version) else {
            throw VoiceMemosError.unsupportedSchemaVersion(version)
        }
    }

    // MARK: - Queries

    /// List voice memos ordered by creation date (newest first).
    /// - Parameters:
    ///   - since: If provided, only return memos created on or after this date.
    ///   - limit: Maximum number of results (default 20).
    public func listMemos(since: Date? = nil, limit: Int = 20) throws -> [VoiceMemo] {
        try dbQueue.read { db in
            var sql = """
            SELECT ZUNIQUEID, ZCUSTOMLABELFORSORTING, ZDURATION, ZDATE, ZPATH
            FROM ZCLOUDRECORDING
            """
            var arguments: StatementArguments = []

            if let since {
                // Convert Date to Core Data epoch
                let coreDataTimestamp = since.timeIntervalSinceReferenceDate
                sql += " WHERE ZDATE >= ?"
                arguments = [coreDataTimestamp]
            }

            sql += " ORDER BY ZDATE DESC LIMIT ?"
            arguments += [limit]

            return try VoiceMemo.fetchAll(db, sql: sql, arguments: arguments)
        }
    }

    /// Get a single memo by its UUID.
    public func getMemo(id: String) throws -> VoiceMemo? {
        try dbQueue.read { db in
            try VoiceMemo.fetchOne(
                db,
                sql: """
                SELECT ZUNIQUEID, ZCUSTOMLABELFORSORTING, ZDURATION, ZDATE, ZPATH
                FROM ZCLOUDRECORDING
                WHERE ZUNIQUEID = ?
                """,
                arguments: [id]
            )
        }
    }

    /// Get a single memo by ID prefix (case-insensitive). Returns nil if no match.
    /// Throws `VoiceMemosError.ambiguousId` if the prefix matches more than one recording.
    public func getMemoByPrefix(id: String) throws -> VoiceMemo? {
        // Try exact match first
        if let memo = try getMemo(id: id) { return memo }
        // Fall back to prefix scan using SQLite LIKE (case-insensitive for ASCII/hex)
        let matches = try dbQueue.read { db in
            try VoiceMemo.fetchAll(
                db,
                sql: """
                SELECT ZUNIQUEID, ZCUSTOMLABELFORSORTING, ZDURATION, ZDATE, ZPATH
                FROM ZCLOUDRECORDING WHERE ZUNIQUEID LIKE ? || '%'
                """,
                arguments: [id]
            )
        }
        switch matches.count {
        case 0: return nil
        case 1: return matches[0]
        default: throw VoiceMemosError.ambiguousId(id, matches.map(\.id))
        }
    }

    /// Check if a memo's audio file has been evicted to iCloud (not available locally).
    public func isEvicted(id: String) throws -> Bool {
        try dbQueue.read { db in
            // Count rows where ZEVICTIONDATE is not null for the given ID.
            // This avoids the Optional<Optional<Double>> ambiguity of fetchOne
            // when differentiating SQL NULL from "no row found".
            let count = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM ZCLOUDRECORDING
                WHERE ZUNIQUEID = ? AND ZEVICTIONDATE IS NOT NULL
                """,
                arguments: [id]
            ) ?? 0
            return count > 0
        }
    }

    /// Export a memo's audio file to the given output directory.
    /// Returns an `ExportResult` with the destination path and optional transcription.
    public func exportMemo(
        id: String,
        outputDir: String,
        transcriber: Transcriber? = nil
    ) throws -> ExportResult {
        guard let memo = try getMemo(id: id) else {
            throw VoiceMemosError.memoNotFound(id)
        }

        // Check eviction before export
        if try isEvicted(id: id) {
            throw VoiceMemosError.memoEvicted(id)
        }

        // Resolve full source path
        let sourcePath = (recordingsDir as NSString).appendingPathComponent(memo.filePath)
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            throw VoiceMemosError.fileNotFound(sourcePath)
        }

        // Create output directory if needed
        try FileManager.default.createDirectory(
            atPath: outputDir,
            withIntermediateDirectories: true
        )

        // Build export filename: YYYY-MM-DD_sanitized-title.<ext>
        let datePrefix = Self.exportDatePrefix(memo.createdAt)
        let sanitizedTitle = Self.sanitizeFilename(memo.title)
        let ext = (memo.filePath as NSString).pathExtension
        let baseName = "\(datePrefix)_\(sanitizedTitle)"

        // Handle collision: append -2, -3, etc.
        let destPath = Self.resolveCollision(
            dir: outputDir,
            baseName: baseName,
            ext: ext
        )

        try FileManager.default.copyItem(atPath: sourcePath, toPath: destPath)

        // Optional transcription
        var transcriptionText: String?
        var transcriptionFilePath: String?
        if let transcriber {
            let text = try transcriber.transcribe(audioPath: sourcePath)
            transcriptionText = text

            // Write .txt sidecar next to the exported audio
            let txtPath = (destPath as NSString).deletingPathExtension + ".txt"
            try text.write(toFile: txtPath, atomically: true, encoding: .utf8)
            transcriptionFilePath = txtPath
        }

        return ExportResult(
            id: memo.id,
            title: memo.title,
            exportedTo: destPath,
            transcription: transcriptionText,
            transcriptionFile: transcriptionFilePath
        )
    }

    /// Transcribe a memo's audio to text without copying the audio file.
    /// - Parameters:
    ///   - id: The memo UUID.
    ///   - transcriber: The transcription backend to use.
    ///   - outputDir: If provided, write a `.txt` file here and return the path in the result.
    public func transcribeMemo(
        id: String,
        transcriber: Transcriber,
        outputDir: String? = nil
    ) throws -> TranscribeResult {
        guard let memo = try getMemo(id: id) else {
            throw VoiceMemosError.memoNotFound(id)
        }

        if try isEvicted(id: id) {
            throw VoiceMemosError.memoEvicted(id)
        }

        let sourcePath = (recordingsDir as NSString).appendingPathComponent(memo.filePath)
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            throw VoiceMemosError.fileNotFound(sourcePath)
        }

        let text = try transcriber.transcribe(audioPath: sourcePath)

        var outputFile: String?
        if let outputDir {
            try FileManager.default.createDirectory(
                atPath: outputDir,
                withIntermediateDirectories: true
            )
            let datePrefix = Self.exportDatePrefix(memo.createdAt)
            let sanitizedTitle = Self.sanitizeFilename(memo.title)
            let baseName = "\(datePrefix)_\(sanitizedTitle)"
            let txtPath = Self.resolveCollision(dir: outputDir, baseName: baseName, ext: "txt")
            try text.write(toFile: txtPath, atomically: true, encoding: .utf8)
            outputFile = txtPath
        }

        return TranscribeResult(
            id: memo.id,
            title: memo.title,
            transcription: text,
            outputFile: outputFile
        )
    }

    // MARK: - Filename helpers

    /// Format a date as YYYY-MM-DD for export filenames.
    static func exportDatePrefix(_ date: Date) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            comps.year ?? 0, comps.month ?? 0, comps.day ?? 0
        )
    }

    /// Replace non-alphanumeric characters with hyphens, collapse runs, trim edges.
    static func sanitizeFilename(_ name: String) -> String {
        let cleaned = name.unicodeScalars.map { char -> Character in
            if CharacterSet.alphanumerics.contains(char) {
                return Character(char)
            }
            return "-"
        }
        // Collapse consecutive hyphens and trim leading/trailing hyphens
        let result = String(cleaned)
            .replacingOccurrences(
                of: "-{2,}",
                with: "-",
                options: .regularExpression
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return result.isEmpty ? "untitled" : result
    }

    /// Find a non-colliding filename in the directory.
    /// If `baseName.ext` exists, tries `baseName-2.ext`, `baseName-3.ext`, etc.
    static func resolveCollision(dir: String, baseName: String, ext: String) -> String {
        let fm = FileManager.default
        let extSuffix = ext.isEmpty ? "" : ".\(ext)"
        let first = (dir as NSString).appendingPathComponent("\(baseName)\(extSuffix)")
        if !fm.fileExists(atPath: first) {
            return first
        }
        var counter = 2
        while true {
            let candidate = (dir as NSString).appendingPathComponent(
                "\(baseName)-\(counter)\(extSuffix)"
            )
            if !fm.fileExists(atPath: candidate) {
                return candidate
            }
            counter += 1
        }
    }
}
