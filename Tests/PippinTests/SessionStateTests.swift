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
        XCTAssertNil(state.activeMailbox)
        XCTAssertNil(state.lastMessageId)
        XCTAssertTrue(state.history.isEmpty)
    }

    func testSessionStateRoundTrip() throws {
        var state = SessionState()
        state.activeAccount = "Work"
        state.activeMailbox = "INBOX"
        state.lastMessageId = "Work||INBOX||42"
        state.history = ["mail list", "mail show Work||INBOX||42"]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionState.self, from: data)

        XCTAssertEqual(decoded.activeAccount, "Work")
        XCTAssertEqual(decoded.activeMailbox, "INBOX")
        XCTAssertEqual(decoded.lastMessageId, "Work||INBOX||42")
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
    }

    func testSessionManagerClearAccountClearsMailbox() {
        let manager = SessionManager(path: tmpPath)
        manager.setActiveAccount("Work")
        manager.setActiveMailbox("INBOX")
        XCTAssertEqual(manager.activeMailbox, "INBOX")
        manager.setActiveAccount(nil)
        XCTAssertNil(manager.activeAccount)
        XCTAssertNil(manager.activeMailbox)
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

    func testSessionManagerClearContext() {
        let manager = SessionManager(path: tmpPath)
        manager.setActiveAccount("Work")
        manager.setActiveMailbox("Sent")
        manager.setLastMessageId("Work||Sent||1")
        manager.setLastEventId("evt-123")
        manager.setLastReminderId("rem-456")
        manager.setLastNoteId("note-789")
        manager.clearContext()
        XCTAssertNil(manager.activeAccount)
        XCTAssertNil(manager.activeMailbox)
        XCTAssertNil(manager.lastMessageId)
        XCTAssertNil(manager.lastEventId)
        XCTAssertNil(manager.lastReminderId)
        XCTAssertNil(manager.lastNoteId)
    }

    func testSessionManagerClearHistory() {
        let manager = SessionManager(path: tmpPath)
        manager.recordCommand("test")
        manager.clearHistory()
        XCTAssertTrue(manager.history.isEmpty)
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

    func testSessionManagerLastIds() {
        let manager = SessionManager(path: tmpPath)
        manager.setLastMessageId("iCloud||INBOX||99")
        manager.setLastEventId("evt-abc")
        manager.setLastReminderId("rem-def")
        manager.setLastNoteId("x-coredata://123")
        XCTAssertEqual(manager.lastMessageId, "iCloud||INBOX||99")
        XCTAssertEqual(manager.lastEventId, "evt-abc")
        XCTAssertEqual(manager.lastReminderId, "rem-def")
        XCTAssertEqual(manager.lastNoteId, "x-coredata://123")
    }
}
