import GRDB
@testable import PippinLib
import XCTest

/// RC-05: `memos delete` edits a store Voice Memos owns. Every test here runs
/// against a fixture database and a stand-in Trash inside a temp directory;
/// none touches the real store, the real app state, or the real Trash.
final class MemosDeleteTests: XCTestCase {
    private var workDir = ""
    private var dbPath: String {
        (workDir as NSString).appendingPathComponent("CloudRecordings.db")
    }

    private var trashDir: String {
        (workDir as NSString).appendingPathComponent("FakeTrash")
    }

    private let memoId = "ABCD1234-5678-90EF-ABCD-1234567890EF"
    private let otherId = "ABCD9999-0000-0000-0000-000000000002"

    override func setUpWithError() throws {
        workDir = NSTemporaryDirectory() + "pippin-memos-delete-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: trashDir, withIntermediateDirectories: true)
        let setup = try DatabaseQueue(path: dbPath)
        try setup.write { db in
            try db.execute(sql: """
            CREATE TABLE Z_METADATA (Z_VERSION INTEGER);
            INSERT INTO Z_METADATA VALUES (1);
            CREATE TABLE ZCLOUDRECORDING (
                ZUNIQUEID TEXT, ZCUSTOMLABELFORSORTING TEXT, ZDURATION REAL,
                ZDATE REAL, ZPATH TEXT, ZEVICTIONDATE REAL
            );
            """)
            for (id, file) in [(memoId, "one.m4a"), (otherId, "two.m4a")] {
                try db.execute(
                    sql: "INSERT INTO ZCLOUDRECORDING VALUES (?, 'Memo', 1.0, 725846400.0, ?, NULL)",
                    arguments: [id, file]
                )
            }
        }
        for file in ["one.m4a", "two.m4a"] {
            XCTAssertTrue(FileManager.default.createFile(atPath: audioPath(file), contents: Data(file.utf8)))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: workDir)
    }

    private func audioPath(_ file: String) -> String {
        (workDir as NSString).appendingPathComponent(file)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    private func rowIds() throws -> Set<String> {
        try Set(DatabaseQueue(path: dbPath).read { db in
            try String.fetchAll(db, sql: "SELECT ZUNIQUEID FROM ZCLOUDRECORDING")
        })
    }

    /// Stand-in for the user's Trash.
    private func fakeTrash(_ url: URL) throws -> URL {
        let dest = URL(fileURLWithPath: trashDir).appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }

    private struct Boom: Error {}

    // MARK: - Lookup

    func testWildcardIdsMatchNothing() throws {
        let db = try VoiceMemosDB(dbPath: dbPath)
        // `%` matched every row, so with one recording `memos delete %`
        // deleted it; `_` matched any single character.
        for id in ["%", "ABCD1234%", "_BCD1234", "ABCD____", ""] {
            XCTAssertNil(try db.getMemoByPrefix(id: id), "'\(id)' must not resolve")
        }
        try DatabaseQueue(path: dbPath).write { db in
            try db.execute(sql: "DELETE FROM ZCLOUDRECORDING WHERE ZUNIQUEID = ?", arguments: [otherId])
        }
        XCTAssertNil(try db.getMemoByPrefix(id: "%"), "a single recording must not be reachable by wildcard")
    }

    func testPrefixLookupStillWorksAndAmbiguityIsAnError() throws {
        let db = try VoiceMemosDB(dbPath: dbPath)
        XCTAssertEqual(try db.getMemoByPrefix(id: "ABCD1234")?.id, memoId)
        XCTAssertEqual(try db.getMemoByPrefix(id: "abcd1234")?.id, memoId, "hex case still folds")
        XCTAssertEqual(try db.getMemoByPrefix(id: memoId)?.id, memoId)
        XCTAssertThrowsError(try db.getMemoByPrefix(id: "ABCD")) { error in
            guard case let VoiceMemosError.ambiguousId(_, matches) = error else {
                return XCTFail("Expected ambiguousId, got \(error)")
            }
            XCTAssertEqual(matches.count, 2)
        }
    }

    func testEscapeLikeLeavesNoLiveWildcard() {
        XCTAssertEqual(VoiceMemosDB.escapeLike(#"a%b_c\d"#), #"a\%b\_c\\d"#)
    }

    // MARK: - Delete

    func testDeleteMovesAudioToTrashThenRemovesOnlyThatRow() throws {
        var rowsSeenAtTrashTime: Set<String> = []
        let result = try VoiceMemosDB.deleteMemo(id: memoId, dbPath: dbPath, isAppRunning: { false }, trash: { url in
            // The recoverable copy must exist BEFORE the row goes.
            rowsSeenAtTrashTime = try self.rowIds()
            return try self.fakeTrash(url)
        })
        XCTAssertEqual(rowsSeenAtTrashTime, [memoId, otherId], "the audio is trashed while the row still exists")
        XCTAssertEqual(try rowIds(), [otherId])
        XCTAssertEqual(result.audioPath, audioPath("one.m4a"))
        XCTAssertFalse(exists(audioPath("one.m4a")))
        let trashed = try XCTUnwrap(result.trashedTo)
        XCTAssertEqual(FileManager.default.contents(atPath: trashed), Data("one.m4a".utf8), "the recording is recoverable")
        XCTAssertTrue(exists(audioPath("two.m4a")), "the other recording is untouched")
    }

    /// The real store's derived-attribute triggers call a function only Core
    /// Data registers, so a plain DELETE of a recording in a folder failed with
    /// "no such function" (seen on a live store, pippin-3ljg).
    func testDeleteRunsTheStoresCoreDataTriggers() throws {
        try DatabaseQueue(path: dbPath).write { db in
            try db.execute(sql: """
            CREATE TABLE ZFOLDER (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZCOUNTOFRECORDINGS INTEGER);
            INSERT INTO ZFOLDER VALUES (1, 3, 2);
            CREATE TRIGGER Z_DA_DELETE AFTER DELETE ON ZCLOUDRECORDING FOR EACH ROW BEGIN
                UPDATE ZFOLDER SET ZCOUNTOFRECORDINGS = ZCOUNTOFRECORDINGS - 1 WHERE Z_PK = 1;
                SELECT NSCoreDataDATriggerUpdatedAffectedObjectValue('ZFOLDER', Z_ENT, Z_PK, 'countOfRecordings', ZCOUNTOFRECORDINGS)
                FROM ZFOLDER WHERE Z_PK = 1;
            END;
            """)
        }
        _ = try VoiceMemosDB.deleteMemo(id: memoId, dbPath: dbPath, isAppRunning: { false }, trash: fakeTrash)
        XCTAssertEqual(try rowIds(), [otherId])
        let count = try DatabaseQueue(path: dbPath).read { db in
            try Int.fetchOne(db, sql: "SELECT ZCOUNTOFRECORDINGS FROM ZFOLDER")
        }
        XCTAssertEqual(count, 1, "the trigger's own bookkeeping still runs")
    }

    func testDeleteRefusesWhileVoiceMemosIsRunning() throws {
        XCTAssertThrowsError(try VoiceMemosDB.deleteMemo(
            id: memoId, dbPath: dbPath, isAppRunning: { true },
            trash: { url in XCTFail("must not trash while the app runs"); return url }
        )) { error in
            guard case VoiceMemosError.voiceMemosRunning = error else {
                return XCTFail("Expected voiceMemosRunning, got \(error)")
            }
            XCTAssertEqual(agentErrorCode(for: error), "voice_memos_running")
            XCTAssertNotNil((error as? VoiceMemosError)?.nextStep.humanAction)
        }
        XCTAssertEqual(try rowIds(), [memoId, otherId])
        XCTAssertTrue(exists(audioPath("one.m4a")))
    }

    func testFailedTrashLeavesRowAndAudioInPlace() throws {
        XCTAssertThrowsError(try VoiceMemosDB.deleteMemo(
            id: memoId, dbPath: dbPath, isAppRunning: { false }, trash: { _ in throw Boom() }
        )) { error in
            guard case VoiceMemosError.deleteFailed = error else {
                return XCTFail("Expected deleteFailed, got \(error)")
            }
        }
        XCTAssertEqual(try rowIds(), [memoId, otherId], "no row may go when the audio could not be saved")
        XCTAssertTrue(exists(audioPath("one.m4a")))
    }

    func testFailedRowDeleteMovesTheAudioBack() throws {
        // A trigger makes the DELETE fail after the audio is already trashed.
        try DatabaseQueue(path: dbPath).write { db in
            try db.execute(sql: """
            CREATE TRIGGER block_delete BEFORE DELETE ON ZCLOUDRECORDING
            BEGIN SELECT RAISE(ABORT, 'blocked'); END;
            """)
        }
        var trashedURL: URL?
        XCTAssertThrowsError(try VoiceMemosDB.deleteMemo(id: memoId, dbPath: dbPath, isAppRunning: { false }, trash: { url in
            trashedURL = try self.fakeTrash(url)
            return trashedURL!
        })) { error in
            guard case VoiceMemosError.deleteFailed = error else {
                return XCTFail("Expected deleteFailed, got \(error)")
            }
        }
        XCTAssertNotNil(trashedURL, "the fault must be injected after the trash step")
        XCTAssertEqual(try rowIds(), [memoId, otherId])
        XCTAssertTrue(exists(audioPath("one.m4a")), "row kept, so the audio must be back in place")
        XCTAssertFalse(try exists(XCTUnwrap(trashedURL).path))
    }

    func testDeleteOfARowWhoseAudioIsNotLocalRemovesTheRowOnly() throws {
        try FileManager.default.removeItem(atPath: audioPath("one.m4a"))
        let result = try VoiceMemosDB.deleteMemo(
            id: memoId, dbPath: dbPath, isAppRunning: { false },
            trash: { url in XCTFail("no local file to trash"); return url }
        )
        XCTAssertNil(result.trashedTo)
        XCTAssertEqual(try rowIds(), [otherId])
    }

    func testDeleteOfAnUnknownIdChangesNothing() throws {
        XCTAssertThrowsError(try VoiceMemosDB.deleteMemo(id: "%", dbPath: dbPath, isAppRunning: { false }, trash: fakeTrash)) { error in
            guard case VoiceMemosError.memoNotFound = error else {
                return XCTFail("Expected memoNotFound, got \(error)")
            }
        }
        XCTAssertEqual(try rowIds(), [memoId, otherId])
    }

    // MARK: - CLI and MCP surface

    func testDryRunNeedsNoForceAndDeleteStillDoes() throws {
        XCTAssertTrue(try MemosCommand.Delete.parse([memoId, "--dry-run"]).dryRun)
        XCTAssertNoThrow(try MemosCommand.Delete.parse([memoId, "--force"]))
        XCTAssertThrowsError(try MemosCommand.Delete.parse([memoId]))
    }

    func testMCPDeleteGate() throws {
        let tool = try XCTUnwrap(MCPToolRegistry.tool(named: "memos_delete"))
        let dry = try tool.buildArgs(.object(["id": .string(memoId), "confirm": .bool(false), "dryRun": .bool(true)]))
        XCTAssertTrue(dry.contains("--dry-run"))
        XCTAssertFalse(dry.contains("--force"), "a dry run must never carry the delete confirmation")
        let real = try tool.buildArgs(.object(["id": .string(memoId), "confirm": .bool(true)]))
        XCTAssertTrue(real.contains("--force"))
        XCTAssertFalse(real.contains("--dry-run"))
        XCTAssertThrowsError(try tool.buildArgs(.object(["id": .string(memoId), "confirm": .bool(false)])))
    }

    /// A read that lands while another process holds the store's lock waits for it
    /// instead of failing at once (one of 8 parallel memos.list calls failed, 2026-11-10).
    func testReadWaitsOutABriefLockOnTheStore() throws {
        let writer = try DatabaseQueue(path: dbPath)
        let locked = DispatchSemaphore(value: 0)
        let released = expectation(description: "lock released")
        DispatchQueue.global().async {
            try? writer.inDatabase { db in
                try db.execute(sql: "BEGIN EXCLUSIVE")
                locked.signal()
                Thread.sleep(forTimeInterval: 0.3)
                try db.execute(sql: "COMMIT")
            }
            released.fulfill()
        }
        locked.wait()
        let memos = try VoiceMemosDB(dbPath: dbPath).listMemos()
        XCTAssertEqual(memos.count, 2)
        wait(for: [released], timeout: 5)
    }
}
