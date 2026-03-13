import GRDB
@testable import PippinLib
import XCTest

final class VoiceMemosDBTests: XCTestCase {
    // MARK: - Test helpers

    /// Create an in-memory database with the Voice Memos schema and known version.
    private func makeTestDB(schemaVersion: Int = 1) throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE Z_METADATA (Z_VERSION INTEGER);
                INSERT INTO Z_METADATA VALUES (\(schemaVersion));
                CREATE TABLE ZCLOUDRECORDING (
                    ZUNIQUEID TEXT,
                    ZCUSTOMLABELFORSORTING TEXT,
                    ZDURATION REAL,
                    ZDATE REAL,
                    ZPATH TEXT,
                    ZEVICTIONDATE REAL
                );
            """)
        }
        return db
    }

    /// Insert a recording into the test database.
    private func insertMemo(
        db: DatabaseQueue,
        id: String = "test-uuid",
        title: String? = "Test Recording",
        duration: Double = 60.0,
        coreDataDate: Double = 725_846_400.0, // Jan 1 2024 00:00:00 UTC
        path: String = "recording.m4a",
        evictionDate: Double? = nil
    ) throws {
        try db.write { dbConn in
            try dbConn.execute(
                sql: """
                INSERT INTO ZCLOUDRECORDING
                (ZUNIQUEID, ZCUSTOMLABELFORSORTING, ZDURATION, ZDATE, ZPATH, ZEVICTIONDATE)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [id, title, duration, coreDataDate, path, evictionDate]
            )
        }
    }

    // MARK: - Schema version guard

    func testKnownSchemaVersionPasses() throws {
        let dbQueue = try makeTestDB(schemaVersion: 1)
        XCTAssertNoThrow(try VoiceMemosDB(dbQueue: dbQueue))
    }

    func testUnknownSchemaVersionThrows() throws {
        let dbQueue = try makeTestDB(schemaVersion: 99)
        XCTAssertThrowsError(try VoiceMemosDB(dbQueue: dbQueue)) { error in
            guard let vmError = error as? VoiceMemosError else {
                XCTFail("Expected VoiceMemosError, got \(type(of: error))")
                return
            }
            if case let .unsupportedSchemaVersion(version) = vmError {
                XCTAssertEqual(version, 99)
            } else {
                XCTFail("Expected unsupportedSchemaVersion, got \(vmError)")
            }
        }
    }

    func testSchemaVersionZeroThrows() throws {
        let dbQueue = try makeTestDB(schemaVersion: 0)
        XCTAssertThrowsError(try VoiceMemosDB(dbQueue: dbQueue))
    }

    // MARK: - Core Data epoch conversion

    func testCoreDataEpochConversion() throws {
        // Core Data epoch: seconds since 2001-01-01 00:00:00 UTC
        // Jan 1 2024 00:00:00 UTC = 725760000.0 in Core Data epoch
        let dbQueue = try makeTestDB()
        try insertMemo(db: dbQueue, id: "epoch-test", coreDataDate: 725_760_000.0)
        let db = try VoiceMemosDB(dbQueue: dbQueue)

        let memo = try db.getMemo(id: "epoch-test")
        XCTAssertNotNil(memo)

        let cal = Calendar(identifier: .gregorian)
        let comps = try cal.dateComponents(in: XCTUnwrap(TimeZone(identifier: "UTC")), from: XCTUnwrap(memo?.createdAt))
        XCTAssertEqual(comps.year, 2024)
        XCTAssertEqual(comps.month, 1)
        XCTAssertEqual(comps.day, 1)
    }

    func testCoreDataEpochZero() throws {
        // Zero = 2001-01-01 00:00:00 UTC (the reference date)
        let dbQueue = try makeTestDB()
        try insertMemo(db: dbQueue, id: "zero-epoch", coreDataDate: 0.0)
        let db = try VoiceMemosDB(dbQueue: dbQueue)

        let memo = try db.getMemo(id: "zero-epoch")
        XCTAssertNotNil(memo)

        let cal = Calendar(identifier: .gregorian)
        let comps = try cal.dateComponents(in: XCTUnwrap(TimeZone(identifier: "UTC")), from: XCTUnwrap(memo?.createdAt))
        XCTAssertEqual(comps.year, 2001)
        XCTAssertEqual(comps.month, 1)
        XCTAssertEqual(comps.day, 1)
    }

    func testCoreDataEpochNegative() throws {
        // Negative = before 2001-01-01 (e.g., 2000-12-31)
        let dbQueue = try makeTestDB()
        try insertMemo(db: dbQueue, id: "neg-epoch", coreDataDate: -86400.0)
        let db = try VoiceMemosDB(dbQueue: dbQueue)

        let memo = try db.getMemo(id: "neg-epoch")
        XCTAssertNotNil(memo)

        let cal = Calendar(identifier: .gregorian)
        let comps = try cal.dateComponents(in: XCTUnwrap(TimeZone(identifier: "UTC")), from: XCTUnwrap(memo?.createdAt))
        XCTAssertEqual(comps.year, 2000)
        XCTAssertEqual(comps.month, 12)
        XCTAssertEqual(comps.day, 31)
    }

    // MARK: - List queries

    func testListOrderedByDateDesc() throws {
        let dbQueue = try makeTestDB()
        // Insert memos with different dates — oldest first, newest last
        try insertMemo(db: dbQueue, id: "old", coreDataDate: 700_000_000.0)
        try insertMemo(db: dbQueue, id: "mid", coreDataDate: 710_000_000.0)
        try insertMemo(db: dbQueue, id: "new", coreDataDate: 720_000_000.0)
        let db = try VoiceMemosDB(dbQueue: dbQueue)

        let memos = try db.listMemos()
        XCTAssertEqual(memos.count, 3)
        XCTAssertEqual(memos[0].id, "new")
        XCTAssertEqual(memos[1].id, "mid")
        XCTAssertEqual(memos[2].id, "old")
    }

    func testListLimit() throws {
        let dbQueue = try makeTestDB()
        for i in 0 ..< 10 {
            try insertMemo(
                db: dbQueue,
                id: "memo-\(i)",
                coreDataDate: Double(700_000_000 + i * 1000)
            )
        }
        let db = try VoiceMemosDB(dbQueue: dbQueue)

        let memos = try db.listMemos(limit: 3)
        XCTAssertEqual(memos.count, 3)
    }

    func testListSinceFilter() throws {
        let dbQueue = try makeTestDB()
        // Jan 1 2023 (Core Data epoch: 694224000)
        try insertMemo(db: dbQueue, id: "before", coreDataDate: 694_224_000.0)
        // Jan 1 2024 (Core Data epoch: 725846400)
        try insertMemo(db: dbQueue, id: "after", coreDataDate: 725_846_400.0)
        let db = try VoiceMemosDB(dbQueue: dbQueue)

        // Filter since Jul 1 2023 (Core Data epoch ~709776000)
        let sinceDate = Date(timeIntervalSinceReferenceDate: 709_776_000.0)
        let memos = try db.listMemos(since: sinceDate)
        XCTAssertEqual(memos.count, 1)
        XCTAssertEqual(memos[0].id, "after")
    }

    func testListEmpty() throws {
        let dbQueue = try makeTestDB()
        let db = try VoiceMemosDB(dbQueue: dbQueue)

        let memos = try db.listMemos()
        XCTAssertTrue(memos.isEmpty)
    }

    // MARK: - getMemo

    func testGetMemoExisting() throws {
        let dbQueue = try makeTestDB()
        try insertMemo(db: dbQueue, id: "found-me", title: "My Recording")
        let db = try VoiceMemosDB(dbQueue: dbQueue)

        let memo = try db.getMemo(id: "found-me")
        XCTAssertNotNil(memo)
        XCTAssertEqual(memo?.title, "My Recording")
    }

    func testGetMemoMissing() throws {
        let dbQueue = try makeTestDB()
        let db = try VoiceMemosDB(dbQueue: dbQueue)

        let memo = try db.getMemo(id: "nonexistent")
        XCTAssertNil(memo)
    }

    func testGetMemoUntitledFallback() throws {
        let dbQueue = try makeTestDB()
        try insertMemo(db: dbQueue, id: "untitled-test", title: nil)
        let db = try VoiceMemosDB(dbQueue: dbQueue)

        let memo = try db.getMemo(id: "untitled-test")
        XCTAssertEqual(memo?.title, "Untitled")
    }

    // MARK: - Eviction detection

    func testNotEvicted() throws {
        let dbQueue = try makeTestDB()
        try insertMemo(db: dbQueue, id: "local", evictionDate: nil)
        let db = try VoiceMemosDB(dbQueue: dbQueue)

        let evicted = try db.isEvicted(id: "local")
        XCTAssertFalse(evicted)
    }

    func testEvicted() throws {
        let dbQueue = try makeTestDB()
        try insertMemo(db: dbQueue, id: "cloud", evictionDate: 725_846_400.0)
        let db = try VoiceMemosDB(dbQueue: dbQueue)

        let evicted = try db.isEvicted(id: "cloud")
        XCTAssertTrue(evicted)
    }

    // MARK: - Export filename helpers

    func testSanitizeFilenameBasic() {
        XCTAssertEqual(VoiceMemosDB.sanitizeFilename("Hello World"), "Hello-World")
    }

    func testSanitizeFilenameSpecialChars() {
        XCTAssertEqual(
            VoiceMemosDB.sanitizeFilename("Meeting @ 3pm!!! (notes)"),
            "Meeting-3pm-notes"
        )
    }

    func testSanitizeFilenameAllSpecial() {
        XCTAssertEqual(VoiceMemosDB.sanitizeFilename("!!!"), "untitled")
    }

    func testSanitizeFilenameEmpty() {
        XCTAssertEqual(VoiceMemosDB.sanitizeFilename(""), "untitled")
    }

    func testSanitizeFilenameAlphanumericOnly() {
        XCTAssertEqual(VoiceMemosDB.sanitizeFilename("abc123"), "abc123")
    }

    func testExportDatePrefix() {
        // Jan 15, 2024 at midnight UTC
        let date = Date(timeIntervalSinceReferenceDate: 726_969_600.0)
        let prefix = VoiceMemosDB.exportDatePrefix(date)
        // The exact date depends on local timezone for the Calendar call,
        // but the format should be YYYY-MM-DD
        XCTAssertTrue(prefix.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
                      "Expected YYYY-MM-DD format, got: \(prefix)")
    }

    func testResolveCollisionNoConflict() {
        let tmpDir = NSTemporaryDirectory() + "pippin-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let result = VoiceMemosDB.resolveCollision(dir: tmpDir, baseName: "test", ext: "m4a")
        XCTAssertEqual((result as NSString).lastPathComponent, "test.m4a")
    }

    func testResolveCollisionWithConflict() throws {
        let tmpDir = NSTemporaryDirectory() + "pippin-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        // Create conflicting file
        let conflictPath = (tmpDir as NSString).appendingPathComponent("test.m4a")
        FileManager.default.createFile(atPath: conflictPath, contents: nil)

        let result = VoiceMemosDB.resolveCollision(dir: tmpDir, baseName: "test", ext: "m4a")
        XCTAssertTrue(result.hasSuffix("test-2.m4a"), "Expected -2 suffix, got: \(result)")
    }

    func testResolveCollisionMultipleConflicts() throws {
        let tmpDir = NSTemporaryDirectory() + "pippin-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        // Create conflicting files for both base and -2
        FileManager.default.createFile(
            atPath: (tmpDir as NSString).appendingPathComponent("test.m4a"),
            contents: nil
        )
        FileManager.default.createFile(
            atPath: (tmpDir as NSString).appendingPathComponent("test-2.m4a"),
            contents: nil
        )

        let result = VoiceMemosDB.resolveCollision(dir: tmpDir, baseName: "test", ext: "m4a")
        XCTAssertTrue(result.hasSuffix("test-3.m4a"), "Expected -3 suffix, got: \(result)")
    }

    // MARK: - VoiceMemo encoding

    func testVoiceMemoJSONEncoding() throws {
        // 725760000.0 = Jan 1 2024 00:00:00 UTC in Core Data epoch
        let memo = VoiceMemo(
            id: "abc-123",
            title: "Test",
            durationSeconds: 90.5,
            createdAt: Date(timeIntervalSinceReferenceDate: 725_760_000.0),
            filePath: "recording.m4a",
            transcription: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(memo)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["id"] as? String, "abc-123")
        XCTAssertEqual(json["title"] as? String, "Test")
        XCTAssertEqual(json["durationSeconds"] as? Double, 90.5)
        XCTAssertEqual(json["filePath"] as? String, "recording.m4a")
        // createdAt should be ISO 8601 string
        let createdAt = json["createdAt"] as? String
        XCTAssertNotNil(createdAt)
        XCTAssertTrue(createdAt?.contains("2024-01-01T") == true,
                      "Expected ISO 8601 date containing 2024-01-01T, got: \(createdAt ?? "nil")")
        // transcription should be null
        XCTAssertTrue(json["transcription"] is NSNull)
    }

    func testVoiceMemoWithTranscription() throws {
        let memo = VoiceMemo(
            id: "def-456",
            title: "Transcribed",
            durationSeconds: 30.0,
            createdAt: Date(timeIntervalSinceReferenceDate: 725_760_000.0),
            filePath: "recording.qta",
            transcription: "Hello world"
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(memo)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["transcription"] as? String, "Hello world")
    }

    // MARK: - Export with real filesystem

    func testExportMemoCopiesFile() throws {
        let tmpDir = NSTemporaryDirectory() + "pippin-export-\(UUID().uuidString)"
        let recordingsDir = tmpDir + "/recordings"
        let outputDir = tmpDir + "/output"
        try FileManager.default.createDirectory(atPath: recordingsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        // Create a fake audio file
        let testAudioData = "fake audio data".data(using: .utf8)!
        let audioPath = (recordingsDir as NSString).appendingPathComponent("test.m4a")
        try testAudioData.write(to: URL(fileURLWithPath: audioPath))

        // Create test DB
        let dbQueue = try makeTestDB()
        try insertMemo(
            db: dbQueue,
            id: "export-test",
            title: "My Export Test",
            coreDataDate: 725_846_400.0,
            path: "test.m4a"
        )
        let db = try VoiceMemosDB(dbQueue: dbQueue, recordingsDir: recordingsDir)

        let result = try db.exportMemo(id: "export-test", outputDir: outputDir)
        XCTAssertEqual(result.id, "export-test")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.exportedTo))
        XCTAssertNil(result.transcription)
        XCTAssertNil(result.transcriptionFile)

        // Verify exported file content matches
        let exportedData = try Data(contentsOf: URL(fileURLWithPath: result.exportedTo))
        XCTAssertEqual(exportedData, testAudioData)
    }

    func testExportEvictedMemoThrows() throws {
        let dbQueue = try makeTestDB()
        try insertMemo(db: dbQueue, id: "evicted", evictionDate: 725_846_400.0)
        let db = try VoiceMemosDB(dbQueue: dbQueue)

        XCTAssertThrowsError(try db.exportMemo(id: "evicted", outputDir: "/tmp")) { error in
            guard let vmError = error as? VoiceMemosError else {
                XCTFail("Expected VoiceMemosError")
                return
            }
            if case .memoEvicted = vmError {
                // Expected
            } else {
                XCTFail("Expected memoEvicted, got \(vmError)")
            }
        }
    }

    func testExportMissingMemoThrows() throws {
        let dbQueue = try makeTestDB()
        let db = try VoiceMemosDB(dbQueue: dbQueue)

        XCTAssertThrowsError(try db.exportMemo(id: "missing", outputDir: "/tmp")) { error in
            guard let vmError = error as? VoiceMemosError else {
                XCTFail("Expected VoiceMemosError")
                return
            }
            if case .memoNotFound = vmError {
                // Expected
            } else {
                XCTFail("Expected memoNotFound, got \(vmError)")
            }
        }
    }

    // MARK: - transcribeMemo

    func testTranscribeMemoReturnsText() throws {
        let tmpDir = NSTemporaryDirectory() + "pippin-transcribe-\(UUID().uuidString)"
        let recordingsDir = tmpDir + "/recordings"
        try FileManager.default.createDirectory(atPath: recordingsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let audioPath = (recordingsDir as NSString).appendingPathComponent("memo.m4a")
        FileManager.default.createFile(atPath: audioPath, contents: Data())

        let dbQueue = try makeTestDB()
        try insertMemo(db: dbQueue, id: "transcribe-test", title: "My Memo", path: "memo.m4a")
        let db = try VoiceMemosDB(dbQueue: dbQueue, recordingsDir: recordingsDir)

        let result = try db.transcribeMemo(
            id: "transcribe-test",
            transcriber: MockTranscriber(text: "Hello world"),
            outputDir: nil
        )
        XCTAssertEqual(result.id, "transcribe-test")
        XCTAssertEqual(result.title, "My Memo")
        XCTAssertEqual(result.transcription, "Hello world")
        XCTAssertNil(result.outputFile)
    }

    func testTranscribeMemoNotFound() throws {
        let dbQueue = try makeTestDB()
        let db = try VoiceMemosDB(dbQueue: dbQueue)

        XCTAssertThrowsError(
            try db.transcribeMemo(id: "missing", transcriber: MockTranscriber(text: "x"))
        ) { error in
            guard let vmError = error as? VoiceMemosError,
                  case .memoNotFound = vmError
            else {
                XCTFail("Expected memoNotFound, got \(error)")
                return
            }
        }
    }

    func testTranscribeMemoEvicted() throws {
        let dbQueue = try makeTestDB()
        try insertMemo(db: dbQueue, id: "evicted-t", evictionDate: 725_846_400.0)
        let db = try VoiceMemosDB(dbQueue: dbQueue)

        XCTAssertThrowsError(
            try db.transcribeMemo(id: "evicted-t", transcriber: MockTranscriber(text: "x"))
        ) { error in
            guard let vmError = error as? VoiceMemosError,
                  case .memoEvicted = vmError
            else {
                XCTFail("Expected memoEvicted, got \(error)")
                return
            }
        }
    }

    func testTranscribeMemoFileNotFound() throws {
        let dbQueue = try makeTestDB()
        // Insert memo with a path that doesn't exist on disk
        try insertMemo(db: dbQueue, id: "no-file", path: "nonexistent.m4a")
        let db = try VoiceMemosDB(dbQueue: dbQueue, recordingsDir: "/tmp/pippin-empty-\(UUID().uuidString)")

        XCTAssertThrowsError(
            try db.transcribeMemo(id: "no-file", transcriber: MockTranscriber(text: "x"))
        ) { error in
            guard let vmError = error as? VoiceMemosError,
                  case .fileNotFound = vmError
            else {
                XCTFail("Expected fileNotFound, got \(error)")
                return
            }
        }
    }

    func testTranscribeMemoWritesFile() throws {
        let tmpDir = NSTemporaryDirectory() + "pippin-transcribe-\(UUID().uuidString)"
        let recordingsDir = tmpDir + "/recordings"
        let outputDir = tmpDir + "/output"
        try FileManager.default.createDirectory(atPath: recordingsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let audioPath = (recordingsDir as NSString).appendingPathComponent("memo.m4a")
        FileManager.default.createFile(atPath: audioPath, contents: Data())

        let dbQueue = try makeTestDB()
        try insertMemo(
            db: dbQueue,
            id: "write-file",
            title: "Note",
            coreDataDate: 725_846_400.0,
            path: "memo.m4a"
        )
        let db = try VoiceMemosDB(dbQueue: dbQueue, recordingsDir: recordingsDir)

        let result = try db.transcribeMemo(
            id: "write-file",
            transcriber: MockTranscriber(text: "Test text"),
            outputDir: outputDir
        )
        XCTAssertNotNil(result.outputFile)
        let written = try XCTUnwrap(result.outputFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: written))
        XCTAssertEqual((written as NSString).lastPathComponent.hasSuffix(".txt"), true)
        let contents = try String(contentsOfFile: written, encoding: .utf8)
        XCTAssertEqual(contents, "Test text")
    }

    func testTranscribeResultJSONEncoding() throws {
        let result = TranscribeResult(
            id: "enc-test",
            title: "My Memo",
            transcription: "Hello",
            outputFile: "/tmp/output.txt"
        )
        let data = try JSONEncoder().encode(result)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["id"] as? String, "enc-test")
        XCTAssertEqual(json["title"] as? String, "My Memo")
        XCTAssertEqual(json["transcription"] as? String, "Hello")
        XCTAssertEqual(json["outputFile"] as? String, "/tmp/output.txt")
    }

    // MARK: - getMemoByPrefix

    func testGetMemoByPrefixExactMatch() throws {
        let dbQueue = try makeTestDB()
        try insertMemo(db: dbQueue, id: "ABCD1234-5678-90EF-ABCD-1234567890EF", title: "Exact Match")
        let db = try VoiceMemosDB(dbQueue: dbQueue)

        let memo = try db.getMemoByPrefix(id: "ABCD1234-5678-90EF-ABCD-1234567890EF")
        XCTAssertNotNil(memo)
        XCTAssertEqual(memo?.title, "Exact Match")
    }

    func testGetMemoByPrefixEightChars() throws {
        let dbQueue = try makeTestDB()
        try insertMemo(db: dbQueue, id: "ABCD1234-5678-90EF-ABCD-1234567890EF", title: "Short Prefix")
        let db = try VoiceMemosDB(dbQueue: dbQueue)

        let memo = try db.getMemoByPrefix(id: "ABCD1234")
        XCTAssertNotNil(memo)
        XCTAssertEqual(memo?.title, "Short Prefix")
    }

    func testGetMemoByPrefixCaseInsensitive() throws {
        let dbQueue = try makeTestDB()
        try insertMemo(db: dbQueue, id: "abcd1234-5678-90ef-abcd-1234567890ef", title: "Lower Case")
        let db = try VoiceMemosDB(dbQueue: dbQueue)

        // SQLite LIKE is case-insensitive for ASCII — uppercase prefix matches lowercase ID
        let memo = try db.getMemoByPrefix(id: "ABCD1234")
        XCTAssertNotNil(memo)
    }

    func testGetMemoByPrefixNoMatchReturnsNil() throws {
        let dbQueue = try makeTestDB()
        let db = try VoiceMemosDB(dbQueue: dbQueue)

        let memo = try db.getMemoByPrefix(id: "NOTFOUND")
        XCTAssertNil(memo)
    }

    func testGetMemoByPrefixAmbiguousThrows() throws {
        let dbQueue = try makeTestDB()
        try insertMemo(db: dbQueue, id: "AAAA1111-0000-0000-0000-000000000001", title: "First")
        try insertMemo(db: dbQueue, id: "AAAA1111-0000-0000-0000-000000000002", title: "Second")
        let db = try VoiceMemosDB(dbQueue: dbQueue)

        XCTAssertThrowsError(try db.getMemoByPrefix(id: "AAAA1111")) { error in
            guard let vmError = error as? VoiceMemosError,
                  case let .ambiguousId(prefix, matches) = vmError
            else {
                XCTFail("Expected ambiguousId, got \(error)")
                return
            }
            XCTAssertEqual(prefix, "AAAA1111")
            XCTAssertEqual(matches.count, 2)
        }
    }

    func testGetMemoByPrefixSingleCharUnambiguous() throws {
        let dbQueue = try makeTestDB()
        try insertMemo(db: dbQueue, id: "ZZZZ1234-0000-0000-0000-000000000001", title: "Only One")
        let db = try VoiceMemosDB(dbQueue: dbQueue)

        let memo = try db.getMemoByPrefix(id: "Z")
        XCTAssertNotNil(memo)
        XCTAssertEqual(memo?.title, "Only One")
    }
}

// MARK: - Cache integration tests

extension VoiceMemosDBTests {
    // Helper: set up DB + filesystem with one memo file
    private func makeDBWithFile() throws -> (db: VoiceMemosDB, recordingsDir: String, tmpDir: String) {
        let tmpDir = NSTemporaryDirectory() + "pippin-cache-\(UUID().uuidString)"
        let recordingsDir = tmpDir + "/recordings"
        try FileManager.default.createDirectory(atPath: recordingsDir, withIntermediateDirectories: true)
        let audioPath = (recordingsDir as NSString).appendingPathComponent("memo.m4a")
        FileManager.default.createFile(atPath: audioPath, contents: Data())
        let dbQueue = try makeTestDB()
        try insertMemo(db: dbQueue, id: "cache-memo", title: "Cache Test", path: "memo.m4a")
        let db = try VoiceMemosDB(dbQueue: dbQueue, recordingsDir: recordingsDir)
        return (db, recordingsDir, tmpDir)
    }

    func testExportMemoWithCacheHit() throws {
        let (db, _, tmpDir) = try makeDBWithFile()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        let outputDir = tmpDir + "/output"
        let cache = try TranscriptCache(dbPath: tmpDir + "/cache.db")
        try cache.set(memoId: "cache-memo", transcript: "cached text", provider: "mlx-audio")

        let spy = SpyTranscriber(text: "live text")
        let result = try db.exportMemo(
            id: "cache-memo", outputDir: outputDir, transcriber: spy,
            cache: cache, forceTranscribe: false
        )
        XCTAssertFalse(spy.wasCalled, "Transcriber must not be called on cache hit")
        XCTAssertEqual(result.transcription, "cached text")
    }

    func testExportMemoWithCacheMiss() throws {
        let (db, _, tmpDir) = try makeDBWithFile()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        let outputDir = tmpDir + "/output"
        let cache = try TranscriptCache(dbPath: tmpDir + "/cache.db")

        let spy = SpyTranscriber(text: "live text")
        _ = try db.exportMemo(
            id: "cache-memo", outputDir: outputDir, transcriber: spy,
            cache: cache, forceTranscribe: false
        )
        XCTAssertTrue(spy.wasCalled, "Transcriber must be called on cache miss")
        let stored = try cache.get(memoId: "cache-memo")
        XCTAssertEqual(stored?.transcript, "live text", "Cache must store transcription result")
        XCTAssertEqual(stored?.provider, "mlx-audio")
    }

    func testExportMemoForceTranscribeBypassesCache() throws {
        let (db, _, tmpDir) = try makeDBWithFile()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        let outputDir = tmpDir + "/output"
        let cache = try TranscriptCache(dbPath: tmpDir + "/cache.db")
        try cache.set(memoId: "cache-memo", transcript: "old text", provider: "mlx-audio")

        let spy = SpyTranscriber(text: "fresh text")
        let result = try db.exportMemo(
            id: "cache-memo", outputDir: outputDir, transcriber: spy,
            cache: cache, forceTranscribe: true
        )
        XCTAssertTrue(spy.wasCalled, "Transcriber must be called when force=true")
        XCTAssertEqual(result.transcription, "fresh text")
    }

    func testParallelTranscribeMemosReturnAllResults() async throws {
        let tmpDir = NSTemporaryDirectory() + "pippin-parallel-\(UUID().uuidString)"
        let recordingsDir = tmpDir + "/recordings"
        try FileManager.default.createDirectory(atPath: recordingsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let dbQueue = try makeTestDB()
        for i in 0 ..< 5 {
            let audioPath = (recordingsDir as NSString).appendingPathComponent("memo\(i).m4a")
            FileManager.default.createFile(atPath: audioPath, contents: Data())
            try insertMemo(db: dbQueue, id: "parallel-\(i)", title: "Memo \(i)", path: "memo\(i).m4a")
        }
        let db = try VoiceMemosDB(dbQueue: dbQueue, recordingsDir: recordingsDir)
        let memos = try db.listMemos(limit: 10)
        XCTAssertEqual(memos.count, 5)

        // Simulate the parallel batch with jobs=2
        let jobs = 2
        let transcriber = MockTranscriber(text: "hello")
        var results: [TranscribeResult] = []
        let chunks = stride(from: 0, to: memos.count, by: jobs).map { i in
            Array(memos[i ..< min(i + jobs, memos.count)])
        }
        for chunk in chunks {
            let chunkResults: [(Int, Result<TranscribeResult, Error>)] = await withTaskGroup(
                of: (Int, Result<TranscribeResult, Error>).self
            ) { group in
                for (i, memo) in chunk.enumerated() {
                    let memoId = memo.id
                    group.addTask {
                        do {
                            let r = try db.transcribeMemo(id: memoId, transcriber: transcriber)
                            return (i, .success(r))
                        } catch {
                            return (i, .failure(error))
                        }
                    }
                }
                var out: [(Int, Result<TranscribeResult, Error>)] = []
                for await result in group {
                    out.append(result)
                }
                return out.sorted { $0.0 < $1.0 }
            }
            for (_, result) in chunkResults {
                if case let .success(r) = result { results.append(r) }
            }
        }

        XCTAssertEqual(results.count, 5, "All 5 memos must be transcribed")
        // Results should be in chunk order (each chunk sorted by index within chunk)
        for result in results {
            XCTAssertEqual(result.transcription, "hello")
        }
    }
}

// MARK: - Test helpers

private struct MockTranscriber: Transcriber {
    let text: String
    func transcribe(audioPath _: String) throws -> TranscriptionResult {
        TranscriptionResult(text: text)
    }
}

private final class SpyTranscriber: Transcriber, @unchecked Sendable {
    let text: String
    private(set) var wasCalled = false

    init(text: String) {
        self.text = text
    }

    func transcribe(audioPath _: String) throws -> TranscriptionResult {
        wasCalled = true
        return TranscriptionResult(text: text)
    }
}
