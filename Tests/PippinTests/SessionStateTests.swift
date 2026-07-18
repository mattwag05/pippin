@testable import PippinLib
import XCTest

final class SessionStateTests: XCTestCase {
    private var tmpPath: String!

    override func setUp() {
        super.setUp()
        tmpPath = NSTemporaryDirectory() + "pippin-test-session-\(UUID().uuidString).json"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpPath)
        super.tearDown()
    }

    // MARK: - SessionState Codable

    func testSessionStateDefaultInit() {
        let state = SessionState()
        XCTAssertNil(state.activeAccount)
        XCTAssertTrue(state.history.isEmpty)
    }

    func testSessionStateRoundTrip() throws {
        var state = SessionState()
        state.activeAccount = "Work"
        state.history = ["mail list", "mail show Work||INBOX||42"]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionState.self, from: data)

        XCTAssertEqual(decoded.activeAccount, "Work")
        XCTAssertEqual(decoded.history, ["mail list", "mail show Work||INBOX||42"])
    }

    // MARK: - SessionManager

    func testSessionManagerCreatesNewState() {
        let manager = SessionManager(path: tmpPath)
        XCTAssertNil(manager.activeAccount)
        XCTAssertTrue(manager.history.isEmpty)
    }

    func testSessionManagerSetActiveAccount() {
        let manager = SessionManager(path: tmpPath)
        manager.setActiveAccount("iCloud")
        XCTAssertEqual(manager.activeAccount, "iCloud")
        manager.setActiveAccount(nil)
        XCTAssertNil(manager.activeAccount)
    }

    func testSessionManagerRecordCommand() {
        let manager = SessionManager(path: tmpPath)
        manager.recordCommand("mail list")
        manager.recordCommand("calendar today")
        XCTAssertEqual(manager.history, ["mail list", "calendar today"])
    }

    func testSessionManagerHistoryCapped() {
        let manager = SessionManager(path: tmpPath)
        for i in 0 ..< 110 {
            manager.recordCommand("cmd \(i)")
        }
        XCTAssertEqual(manager.history.count, 100)
        XCTAssertEqual(manager.history.first, "cmd 10")
        XCTAssertEqual(manager.history.last, "cmd 109")
    }

    func testSessionManagerPersistence() {
        // Write
        let manager1 = SessionManager(path: tmpPath)
        manager1.setActiveAccount("Exchange")
        manager1.recordCommand("mail accounts")

        // Read back in a new manager
        let manager2 = SessionManager(path: tmpPath)
        XCTAssertEqual(manager2.activeAccount, "Exchange")
        XCTAssertEqual(manager2.history, ["mail accounts"])
    }

    // MARK: - Persistence atomicity under concurrent mutation

    //
    // Regression: mutators used to release the lock, then call save() which
    // re-snapshotted under a *separate* lock acquisition and wrote outside it.
    // Two concurrent mutators' atomic writes were unordered, so an older
    // snapshot's write could land last and revert a sibling field on disk.
    // Persistence now happens inside the mutation's lock (persistLocked).

    func testDistinctFieldMutationsBothPersistToDisk() {
        let m1 = SessionManager(path: tmpPath)
        m1.setActiveAccount("Work")
        m1.recordCommand("mail list")
        // Fresh manager reads only what reached disk.
        let m2 = SessionManager(path: tmpPath)
        XCTAssertEqual(m2.activeAccount, "Work")
        XCTAssertEqual(m2.history, ["mail list"])
    }

    func testConcurrentMutationsRemainConsistentAndDeadlockFree() {
        let manager = SessionManager(path: tmpPath)
        // Hammer two independent fields from many threads at once. With the old
        // out-of-lock save() this could lose an update or (if someone later
        // nested the lock) deadlock; persistLocked must keep both safe.
        DispatchQueue.concurrentPerform(iterations: 300) { i in
            if i % 2 == 0 {
                manager.setActiveAccount("acct-\(i)")
            } else {
                manager.recordCommand("cmd-\(i)")
            }
        }
        // In-memory state must have both fields set, and the on-disk file must
        // round-trip to a consistent state with both present.
        XCTAssertNotNil(manager.activeAccount)
        XCTAssertFalse(manager.history.isEmpty)
        let reloaded = SessionManager(path: tmpPath)
        XCTAssertNotNil(reloaded.activeAccount, "an account mutation must survive on disk")
        XCTAssertFalse(reloaded.history.isEmpty, "a recorded command must survive on disk")
        XCTAssertLessThanOrEqual(reloaded.history.count, 100, "history cap holds under concurrency")
    }
}
