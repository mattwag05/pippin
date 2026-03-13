@testable import PippinLib
import XCTest

final class DoctorTests: XCTestCase {
    // MARK: - classifyMailError

    func testClassifyMailErrorTCC() {
        let check = classifyMailError("not authorized to send Apple events")
        XCTAssertEqual(check.status, .fail)
        XCTAssertFalse(
            check.remediation?.contains("$ ") ?? false,
            "TCC remediation must be human-only (no $ command), got: \(check.remediation ?? "nil")"
        )
    }

    func testClassifyMailErrorNotRunning() {
        let check = classifyMailError("")
        XCTAssertEqual(check.status, .fail)
        XCTAssertTrue(
            check.remediation?.contains("$ open -a Mail") ?? false,
            "Not-running remediation must include '$ open -a Mail', got: \(check.remediation ?? "nil")"
        )
    }

    func testClassifyMailErrorUnknown() {
        let check = classifyMailError("socket timeout")
        XCTAssertEqual(check.status, .fail)
        XCTAssertTrue(
            check.detail.contains("socket timeout"),
            "Unknown error detail should pass through, got: \(check.detail)"
        )
        XCTAssertFalse(
            check.remediation?.contains("$ ") ?? false,
            "Unknown remediation must not contain runnable '$ ' command, got: \(check.remediation ?? "nil")"
        )
    }

    // MARK: - classifyPython3Output

    func testClassifyPython3OutputSuccess() {
        let check = classifyPython3Output(exitCode: 0, output: "Python 3.14.3")
        XCTAssertEqual(check.status, .ok)
        XCTAssertTrue(
            check.detail.contains("3.14"),
            "Expected parsed version in detail, got: \(check.detail)"
        )
    }

    func testClassifyPython3OutputFailure() {
        let check = classifyPython3Output(exitCode: 1, output: "")
        XCTAssertEqual(check.status, .fail)
        XCTAssertTrue(
            check.remediation?.contains("$ brew install python3") ?? false,
            "Failure remediation must include '$ brew install python3', got: \(check.remediation ?? "nil")"
        )
    }

    // MARK: - checkPython3 live call

    func testCheckPython3Live() {
        let check = checkPython3()
        XCTAssertEqual(check.status, .ok, "Expected python3 to be available on CI, got: \(check.detail)")
    }

    // MARK: - Permission-denial remediations (via runAllChecks)

    func testCalendarPermissionDeniedNoRunnableCommand() {
        let checks = runAllChecks()
        guard let check = checks.first(where: { $0.name == "Calendar access" }),
              check.status == .fail else { return }
        XCTAssertFalse(
            check.remediation?.contains("$ ") ?? false,
            "Calendar permission-denied remediation must not contain runnable '$ ' command"
        )
    }

    func testRemindersPermissionDeniedNoRunnableCommand() {
        let checks = runAllChecks()
        guard let check = checks.first(where: { $0.name == "Reminders access" }),
              check.status == .fail else { return }
        XCTAssertFalse(
            check.remediation?.contains("$ ") ?? false,
            "Reminders permission-denied remediation must not contain runnable '$ ' command"
        )
    }

    func testContactsPermissionDeniedNoRunnableCommand() {
        let checks = runAllChecks()
        guard let check = checks.first(where: { $0.name == "Contacts access" }),
              check.status == .fail else { return }
        XCTAssertFalse(
            check.remediation?.contains("$ ") ?? false,
            "Contacts permission-denied remediation must not contain runnable '$ ' command"
        )
    }

    // MARK: - Agent-actionable remediations (must have $ command)

    func testParakeetMLXRemediationHasRunnableCommand() {
        let checks = runAllChecks()
        guard let check = checks.first(where: { $0.name == "parakeet-mlx" }),
              let remediation = check.remediation else { return }
        XCTAssertTrue(
            remediation.contains("$ "),
            "parakeet-mlx remediation must include a '$ ' command, got: \(remediation)"
        )
    }

    func testMLXAudioRemediationHasRunnableCommand() {
        let checks = runAllChecks()
        guard let check = checks.first(where: { $0.name == "mlx-audio" }),
              let remediation = check.remediation else { return }
        XCTAssertTrue(
            remediation.contains("$ "),
            "mlx-audio remediation must include a '$ ' command, got: \(remediation)"
        )
    }

    func testNodeJSRemediationHasRunnableCommand() {
        let checks = runAllChecks()
        guard let check = checks.first(where: { $0.name == "Node.js" }),
              let remediation = check.remediation else { return }
        XCTAssertTrue(
            remediation.contains("$ "),
            "Node.js remediation must include a '$ ' command, got: \(remediation)"
        )
    }

    func testPlaywrightRemediationHasRunnableCommand() {
        let checks = runAllChecks()
        guard let check = checks.first(where: { $0.name == "Playwright" }),
              let remediation = check.remediation else { return }
        XCTAssertTrue(
            remediation.contains("$ "),
            "Playwright remediation must include a '$ ' command, got: \(remediation)"
        )
    }
}
