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
}
