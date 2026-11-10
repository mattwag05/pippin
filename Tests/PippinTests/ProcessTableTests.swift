@testable import PippinLib
import XCTest

final class ProcessTableTests: XCTestCase {
    func testStartTimeOfThisProcessIsRecentAndDeadPidHasNone() throws {
        let start = try XCTUnwrap(ProcessTable.startTime(of: getpid()))
        XCTAssertLessThan(start, Date())
        XCTAssertGreaterThan(start, Date().addingTimeInterval(-3600))

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        XCTAssertNil(ProcessTable.startTime(of: child.processIdentifier))
    }

    func testIsRunningFindsAProcessByExactName() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }
        XCTAssertTrue(ProcessTable.isRunning(named: "sleep"))
        XCTAssertFalse(ProcessTable.isRunning(named: "pippin-no-such-process"))
    }
}
