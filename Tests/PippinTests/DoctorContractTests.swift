@testable import PippinLib
import XCTest

/// What `doctor` answers when a check fails (RC-15).
final class DoctorContractTests: XCTestCase {
    private let checks = [
        DiagnosticCheck(name: "Mail automation", status: .fail, detail: "permission denied"),
        DiagnosticCheck(name: "Calendar", status: .ok, detail: "granted"),
        DiagnosticCheck(name: "Envelope Index", status: .skip, detail: "no Full Disk Access"),
    ]

    func testCLIExitsOneAndNamesTheFailedChecks() {
        let result = DoctorCommand.result(for: checks, underMCP: false)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.warnings, ["1 check(s) failed: Mail automation"])
        XCTAssertEqual((result.payload as? [DiagnosticCheck])?.count, 3)
    }

    func testMCPKeepsExitZeroSoTheDiagnosisIsNotAToolError() {
        let result = DoctorCommand.result(for: checks, underMCP: true)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.warnings, ["1 check(s) failed: Mail automation"])
    }

    func testHealthyRunHasNoWarningsAndExitsZero() {
        let healthy = checks.filter { $0.status != .fail }
        for underMCP in [true, false] {
            let result = DoctorCommand.result(for: healthy, underMCP: underMCP)
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertNil(result.warnings)
        }
    }
}
