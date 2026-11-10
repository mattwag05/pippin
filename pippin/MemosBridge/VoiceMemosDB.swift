import AppKit
import Foundation
import GRDB

// MARK: - Sidecar format

public enum ExportSidecarFormat: String, Sendable, CaseIterable {
    case txt
    case srt
    case markdown
    case rtf

    public var fileExtension: String {
        switch self {
        case .txt: return "txt"
        case .srt: return "srt"
        case .markdown: return "md"
        case .rtf: return "rtf"
        }
    }
}

public enum VoiceMemosError: LocalizedError, Sendable {
    case databaseNotFound(String)
    case unsupportedSchemaVersion(Int)
    case memoNotFound(String)
    case memoEvicted(String)
    case fileNotFound(String)
    case exportFailed(String)
    case ambiguousId(String, [String])
    /// macOS denied read/write access to the Voice Memos DB.
    /// Almost always means Full Disk Access is not granted to the terminal
    /// that launched pippin. The raw SQLite/GRDB message is carried in the
    /// associated value for display; remediation text is attached by the
    /// remediation catalog at the CLI boundary.
    case accessDenied(String)
    /// `memos delete` edits Voice Memos' own store, which is only safe while
    /// the app is not running against it.
    case voiceMemosRunning
    /// A delete stopped partway. The associated value says what state the
    /// recording was left in.
    case deleteFailed(String)

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
        case let .accessDenied(detail):
            return "Voice Memos database access denied (\(detail)). See `pippin doctor` for remediation."
        case .voiceMemosRunning:
            return "Voice Memos is running. Quit the app before deleting a recording; nothing was changed."
        case let .deleteFailed(detail):
            return "Delete failed: \(detail)"
        }
    }
}

extension VoiceMemosError: RemediableError {
    public var agentCode: String {
        switch self {
        case .databaseNotFound: return "database_not_found"
        case .unsupportedSchemaVersion: return "unsupported_schema_version"
        case .memoNotFound: return "memo_not_found"
        case .memoEvicted: return "memo_evicted"
        case .fileNotFound: return "file_not_found"
        case .exportFailed: return "export_failed"
        case .ambiguousId: return "ambiguous_id"
        case .accessDenied: return "access_denied"
        case .voiceMemosRunning: return "voice_memos_running"
        case .deleteFailed: return "delete_failed"
        }
    }

    public var nextStep: NextStep {
        switch self {
        case .databaseNotFound: return .human("Open the Voice Memos app once to create its database, then retry.")
        case .unsupportedSchemaVersion, .fileNotFound, .exportFailed, .deleteFailed: return .none
        case .voiceMemosRunning: return .human("Quit the Voice Memos app, then retry the delete.")
        case .memoNotFound, .ambiguousId: return .call(tool: "memos_list", argv: ["memos", "list"])
        case .memoEvicted: return .human("Download this recording from iCloud in the Voice Memos app, then retry.")
        case .accessDenied:
            return .human("Enable Full Disk Access for pippin and the app that launches it in System Settings > Privacy & Security > Full Disk Access, then relaunch that app.")
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

    // MARK: - Init

    /// Open the Voice Memos database at the given path.
    /// Validates schema version on open.
    ///
    /// Errors:
    /// - `VoiceMemosError.databaseNotFound` — file does not exist at `dbPath`.
    /// - `VoiceMemosError.accessDenied` — macOS TCC (Full Disk Access) or
    ///   another OS-level permission blocked the read. The raw GRDB/SQLite
    ///   message is attached for display.
    /// - `VoiceMemosError.unsupportedSchemaVersion` — the `Z_VERSION` on
    ///   disk isn't one this build knows about (post macOS upgrade).
    public init(dbPath: String) throws {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw VoiceMemosError.databaseNotFound(dbPath)
        }
        dbQueue = try Self.openQueue(path: dbPath, readonly: true)
        recordingsDir = (dbPath as NSString).deletingLastPathComponent
        try validateSchema()
    }

    /// Open a GRDB queue and convert any failure into `VoiceMemosError.accessDenied`.
    /// The typical failure mode here is macOS TCC denying Full Disk Access, which
    /// GRDB surfaces as "SQLite error 23: authorization denied" before any SQL
    /// runs. Other SQLite errors (locked, malformed, I/O) also route through
    /// this case — the raw GRDB message is preserved for support.
    private static func openQueue(path: String, readonly: Bool) throws -> DatabaseQueue {
        var config = Configuration()
        config.readonly = readonly
        // Voice Memos or a parallel pippin can hold the lock briefly; wait instead of failing (as CacheDB does).
        config.busyMode = .timeout(5)
        do {
            return try DatabaseQueue(path: path, configuration: config)
        } catch {
            throw VoiceMemosError.accessDenied(error.localizedDescription)
        }
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
        // A file with no Z_METADATA (zero-byte, or some other SQLite database) is
        // an unsupported schema, not a raw SQLite error.
        let version = (try? dbQueue.read { db -> Int in
            try Int.fetchOne(db, sql: "SELECT Z_VERSION FROM Z_METADATA") ?? 0
        }) ?? 0
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
            SELECT ZUNIQUEID, ZCUSTOMLABELFORSORTING, ZDURATION, ZDATE, ZPATH, ZEVICTIONDATE
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
        }.map(withAbsolutePath)
    }

    /// Get a single memo by its UUID.
    public func getMemo(id: String) throws -> VoiceMemo? {
        try dbQueue.read { db in
            try VoiceMemo.fetchOne(
                db,
                sql: """
                SELECT ZUNIQUEID, ZCUSTOMLABELFORSORTING, ZDURATION, ZDATE, ZPATH, ZEVICTIONDATE
                FROM ZCLOUDRECORDING
                WHERE ZUNIQUEID = ?
                """,
                arguments: [id]
            )
        }.map(withAbsolutePath)
    }

    /// Resolve the bare `ZPATH` filename to an absolute path under the
    /// recordings directory. An empty path (NULL ZPATH — not downloaded)
    /// stays empty rather than pointing at the directory itself.
    private func withAbsolutePath(_ memo: VoiceMemo) -> VoiceMemo {
        guard !memo.filePath.isEmpty, !memo.filePath.hasPrefix("/") else { return memo }
        var resolved = memo
        resolved.filePath = (recordingsDir as NSString).appendingPathComponent(memo.filePath)
        return resolved
    }

    /// Get a single memo by ID prefix (case-insensitive). Returns nil if no match.
    /// Throws `VoiceMemosError.ambiguousId` if the prefix matches more than one recording.
    public func getMemoByPrefix(id: String) throws -> VoiceMemo? {
        // Try exact match first
        if let memo = try getMemo(id: id) { return memo }
        // An empty prefix is a prefix of every id, so it names nothing.
        guard !id.isEmpty else { return nil }
        // Fall back to prefix scan using SQLite LIKE (case-insensitive for ASCII/hex).
        // The id is user input: escape LIKE's wildcards so `%` or `_` cannot
        // match rows the caller did not name (RC-05).
        let matches = try dbQueue.read { db in
            try VoiceMemo.fetchAll(
                db,
                sql: """
                SELECT ZUNIQUEID, ZCUSTOMLABELFORSORTING, ZDURATION, ZDATE, ZPATH, ZEVICTIONDATE
                FROM ZCLOUDRECORDING WHERE ZUNIQUEID LIKE ? || '%' ESCAPE '\\'
                """,
                arguments: [Self.escapeLike(id)]
            )
        }
        switch matches.count {
        case 0: return nil
        case 1: return withAbsolutePath(matches[0])
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
        transcriber: Transcriber? = nil,
        sidecarFormat: ExportSidecarFormat = .txt,
        cache: TranscriptCache? = nil, // swiftlint:disable:this identifier_name
        forceTranscribe: Bool = false
    ) throws -> ExportResult {
        guard let memo = try getMemo(id: id) else {
            throw VoiceMemosError.memoNotFound(id)
        }

        // Check eviction before export
        if try isEvicted(id: id) {
            throw VoiceMemosError.memoEvicted(id)
        }

        // getMemo already resolved filePath to an absolute path
        let sourcePath = memo.filePath
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
            // Check cache first (unless force)
            let text: String
            if !forceTranscribe, let cached = try cache?.get(memoId: memo.id) {
                text = cached.transcript
            } else {
                let result = try transcriber.transcribe(audioPath: sourcePath)
                text = result.text
                try cache?.set(memoId: memo.id, transcript: text, provider: transcriber.cacheProvider)
            }
            transcriptionText = text

            // Write sidecar next to the exported audio in the requested format
            let sidecarPath = (destPath as NSString).deletingPathExtension + ".\(sidecarFormat.fileExtension)"
            try Self.writeSidecar(
                text: text,
                format: sidecarFormat,
                path: sidecarPath,
                memo: memo
            )
            transcriptionFilePath = sidecarPath
        }

        return ExportResult(
            id: memo.id,
            title: memo.title,
            exportedTo: destPath,
            transcription: transcriptionText,
            transcriptionFile: transcriptionFilePath
        )
    }

    /// Escape `%`, `_` and the escape character itself for a `LIKE ... ESCAPE '\\'`.
    static func escapeLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    public static func voiceMemosIsRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.VoiceMemos").isEmpty
    }

    /// Move a file to the user's Trash and return where it landed.
    public static func moveToUserTrash(_ url: URL) throws -> URL {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        return (trashed as URL?) ?? url
    }

    /// Delete a memo: move its audio to the Trash, then remove its DB row.
    ///
    /// The row is removed with raw SQL from a store Voice Memos owns, so this
    /// refuses while the app is running. The audio goes to the Trash FIRST, so
    /// the recording stays recoverable, and each failure leaves a consistent
    /// state: if the move fails nothing has changed, and if the row delete
    /// fails the audio is moved back before the error is thrown.
    /// `isAppRunning` and `trash` are parameters so tests never touch the real
    /// app state or the real Trash.
    /// - Parameters:
    ///   - id: Full UUID of the memo to delete.
    ///   - dbPath: Path to CloudRecordings.db (defaults to system path).
    /// - Returns: The audio file's original path and where it was trashed
    ///   (`audioPath` empty when the row has no path; `trashedTo` nil when no
    ///   local file existed).
    @discardableResult
    public static func deleteMemo(
        id: String,
        dbPath: String? = nil,
        isAppRunning: () -> Bool = voiceMemosIsRunning,
        trash: (URL) throws -> URL = moveToUserTrash
    ) throws -> (audioPath: String, trashedTo: String?) {
        let path = dbPath ?? defaultDBPath()
        let dbURL = URL(fileURLWithPath: path)
        let dir = dbURL.deletingLastPathComponent().path

        // Ensure the database exists before opening a writable connection,
        // to avoid creating a new empty database at an incorrect path.
        guard FileManager.default.fileExists(atPath: path) else {
            throw VoiceMemosError.databaseNotFound(path)
        }
        guard !isAppRunning() else { throw VoiceMemosError.voiceMemosRunning }
        let writableQueue = try openQueue(path: path, readonly: false)

        // Fetch the file path before deleting
        let filePath: String = try writableQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT ZPATH FROM ZCLOUDRECORDING WHERE ZUNIQUEID = ?",
                arguments: [id]
            ) else {
                throw VoiceMemosError.memoNotFound(id)
            }
            // ZPATH can be NULL (e.g. an iCloud recording not yet downloaded).
            // Decode optionally so a NULL doesn't trap; the empty-path guard
            // below then skips the file rather than targeting `dir` itself.
            return (row["ZPATH"] as String?) ?? ""
        }

        // Guard against an empty path: appendingPathComponent("") returns
        // `dir`, so an unguarded move would trash the entire memos directory.
        let audioPath = filePath.isEmpty ? "" : (dir as NSString).appendingPathComponent(filePath)
        var trashedTo: URL?
        if !audioPath.isEmpty, FileManager.default.fileExists(atPath: audioPath) {
            do {
                trashedTo = try trash(URL(fileURLWithPath: audioPath))
            } catch {
                throw VoiceMemosError.deleteFailed(
                    "could not move \(audioPath) to the Trash (\(error.localizedDescription)); nothing was changed."
                )
            }
        }

        do {
            try writableQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM ZCLOUDRECORDING WHERE ZUNIQUEID = ?",
                    arguments: [id]
                )
            }
        } catch {
            guard let trashedTo else {
                throw VoiceMemosError.deleteFailed("could not remove the recording's row (\(error.localizedDescription)); nothing was changed.")
            }
            do {
                try FileManager.default.moveItem(at: trashedTo, to: URL(fileURLWithPath: audioPath))
            } catch {
                throw VoiceMemosError.deleteFailed(
                    "could not remove the recording's row, and its audio could not be moved back: it is at \(trashedTo.path)."
                )
            }
            throw VoiceMemosError.deleteFailed(
                "could not remove the recording's row (\(error.localizedDescription)); the audio was moved back and nothing was changed."
            )
        }

        return (audioPath, trashedTo?.path)
    }

    /// Transcribe a memo's audio to text without copying the audio file.
    /// - Parameters:
    ///   - id: The memo UUID.
    ///   - transcriber: The transcription backend to use.
    ///   - outputDir: If provided, write a `.txt` file here and return the path in the result.
    ///   - keepConverted: If `true`, preserve any temp WAV produced by
    ///     `AudioConverter` (debugging). Default `false` cleans up.
    ///   - onConvertedPath: Invoked with the temp path when a conversion runs.
    ///     Lets the CLI print the path to stderr without coupling to output modes.
    public func transcribeMemo(
        id: String,
        transcriber: Transcriber,
        outputDir: String? = nil,
        keepConverted: Bool = false,
        onConvertedPath: ((String) -> Void)? = nil
    ) throws -> TranscribeResult {
        guard let memo = try getMemo(id: id) else {
            throw VoiceMemosError.memoNotFound(id)
        }

        if try isEvicted(id: id) {
            throw VoiceMemosError.memoEvicted(id)
        }

        // getMemo already resolved filePath to an absolute path
        let sourcePath = memo.filePath
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            throw VoiceMemosError.fileNotFound(sourcePath)
        }

        // Non-native formats get normalized to 16 kHz mono WAV before the STT
        // backend sees them. Voice Memos' native `.m4a` skips this entirely.
        var audioPathForTranscribe = sourcePath
        var convertedURL: URL?
        if AudioConverter.needsConversion(path: sourcePath) {
            let tempURL = try AudioConverter.convertToWAV16kMono(
                sourcePath: sourcePath,
                keepOutput: keepConverted
            )
            convertedURL = tempURL
            audioPathForTranscribe = tempURL.path
            onConvertedPath?(tempURL.path)
        }
        defer {
            if let url = convertedURL, !keepConverted {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let transcribeResult = try transcriber.transcribe(audioPath: audioPathForTranscribe)
        let text = transcribeResult.text

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

    // MARK: - Sidecar format writers

    static func writeSidecar(text: String, format: ExportSidecarFormat, path: String, memo: VoiceMemo) throws {
        switch format {
        case .txt:
            try text.write(toFile: path, atomically: true, encoding: .utf8)

        case .markdown:
            let dateStr = exportDatePrefix(memo.createdAt)
            let duration = TextFormatter.duration(memo.durationSeconds)
            let md = """
            # \(memo.title)

            **Date:** \(dateStr)
            **Duration:** \(duration)
            **ID:** \(memo.id)

            ---

            \(text)
            """
            try md.write(toFile: path, atomically: true, encoding: .utf8)

        case .srt:
            // Generate a best-effort SRT with the full transcript as one block.
            // True per-word timestamps require parakeet-mlx --timestamps output.
            let durationInt = Int(memo.durationSeconds)
            let endH = durationInt / 3600
            let endM = (durationInt % 3600) / 60
            let endS = durationInt % 60
            let srt = """
            1
            00:00:00,000 --> \(String(format: "%02d:%02d:%02d,000", endH, endM, endS))
            \(text)
            """
            try srt.write(toFile: path, atomically: true, encoding: .utf8)

        case .rtf:
            // Minimal RTF: plain text wrapped in basic RTF envelope (no AppKit dependency)
            let escaped = text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "{", with: "\\{")
                .replacingOccurrences(of: "}", with: "\\}")
                .replacingOccurrences(of: "\n", with: " \\par\n")
            let rtf = "{\\rtf1\\ansi\\deff0 {\\fonttbl {\\f0 Helvetica;}} \\f0\\fs24 \(escaped)}"
            guard let rtfData = rtf.data(using: .ascii, allowLossyConversion: true) else {
                throw VoiceMemosError.exportFailed("Failed to encode RTF output")
            }
            try rtfData.write(to: URL(fileURLWithPath: path))
        }
    }
}
