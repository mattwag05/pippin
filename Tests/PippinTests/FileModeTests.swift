import GRDB
@testable import PippinLib
import XCTest

/// SEC-12: state under ~/.config/pippin and ~/.cache/pippin/jobs holds mail and
/// note text, so directories are 0700 and files 0600. Everything runs in a
/// temp dir, never the real home.
final class FileModeTests: XCTestCase {
    private var root: String!

    override func setUp() {
        super.setUp()
        root = NSTemporaryDirectory() + "pippin-modes-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
        super.tearDown()
    }

    private func mode(_ path: String) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777
    }

    func testCacheQueueCreatesPrivateDirAndDatabaseFiles() throws {
        let dir = root + "/pippin"
        let path = dir + "/cache.db"
        let queue = try openCacheQueue(path: path)
        try queue.write { try $0.execute(sql: "CREATE TABLE t (x INTEGER); INSERT INTO t VALUES (1)") }
        XCTAssertEqual(try mode(dir), 0o700)
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
            XCTAssertEqual(try mode(path + suffix), 0o600, "\(path + suffix)")
        }
    }

    func testCacheQueueTightensExistingLooseFiles() throws {
        let dir = root + "/pippin"
        let path = dir + "/cache.db"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755]
        )
        try openCacheQueue(path: path).write { try $0.execute(sql: "CREATE TABLE t (x INTEGER)") }
        chmod(path, 0o644)
        _ = try openCacheQueue(path: path)
        XCTAssertEqual(try mode(dir), 0o700)
        XCTAssertEqual(try mode(path), 0o600)
    }

    func testSessionFileIsPrivate() throws {
        let path = root + "/pippin/session.json"
        SessionManager(path: path).recordCommand("mail list")
        XCTAssertEqual(try mode(root + "/pippin"), 0o700)
        XCTAssertEqual(try mode(path), 0o600)
    }

    func testMailAccountsCacheFileIsPrivate() throws {
        let path = root + "/pippin/mail-accounts.json"
        MailAccountsCache.save([], fetchedAt: Date(), path: path)
        XCTAssertEqual(try mode(root + "/pippin"), 0o700)
        XCTAssertEqual(try mode(path), 0o600)
    }

    func testJobDirAndFilesArePrivate() throws {
        let store = JobStore(root: root + "/jobs")
        let id = JobId.generate()
        try store.createDir(id)
        try store.write(Job(id: id, argv: ["mail", "list"], pid: 1, status: .running, startedAt: Date()))
        XCTAssertEqual(try mode(store.root), 0o700)
        XCTAssertEqual(try mode(store.jobDir(id)), 0o700)
        for path in [store.statusPath(id), store.stdoutPath(id), store.stderrPath(id)] {
            XCTAssertEqual(try mode(path), 0o600, path)
        }
    }
}
