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

    func testMLXAudioIsRequiredCheck() {
        let checks = runAllChecks()
        guard let check = checks.first(where: { $0.name == "mlx-audio" }) else {
            XCTFail("mlx-audio check must be present in runAllChecks()")
            return
        }
        // mlx-audio is now required for transcription — must be .ok or .fail, never .skip
        XCTAssertTrue(
            check.status == .ok || check.status == .fail,
            "mlx-audio must be .ok or .fail (not .skip), got: \(check.status)"
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

    // MARK: - AudioBridge mlx-audio python discovery

    func testFindPythonWithMLXAudioReturnsNilForEmptyCandidates() {
        let result = AudioBridge.findPythonWithMLXAudio(candidates: [])
        XCTAssertNil(result, "Empty candidate list must return nil")
    }

    func testFindPythonWithMLXAudioReturnsNilForBogusCandidates() {
        let bogus = [
            URL(fileURLWithPath: "/nonexistent/path/python3"),
            URL(fileURLWithPath: "/tmp/definitely-not-a-python-\(UUID().uuidString)"),
        ]
        let result = AudioBridge.findPythonWithMLXAudio(candidates: bogus)
        XCTAssertNil(result, "Nonexistent paths must return nil")
    }

    func testFindPythonWithMLXAudioSystemPythonConsistent() {
        // Probing just /usr/bin/python3: result must be either that URL (if mlx_audio is
        // importable from system python) or nil (if not). Tolerates CI/dev machines where
        // mlx-audio is installed via pipx and not system python.
        let systemPython = URL(fileURLWithPath: "/usr/bin/python3")
        let result = AudioBridge.findPythonWithMLXAudio(candidates: [systemPython])
        if let found = result {
            XCTAssertEqual(found.path, systemPython.path)
        }
    }

    func testDefaultMLXAudioPythonCandidatesIncludesSystemAndPipx() {
        let candidates = AudioBridge.defaultMLXAudioPythonCandidates()
        XCTAssertFalse(candidates.isEmpty, "Default candidate list must not be empty")
        XCTAssertTrue(
            candidates.contains(where: { $0.path == "/usr/bin/python3" }),
            "Default candidates must include /usr/bin/python3"
        )
        XCTAssertTrue(
            candidates.contains(where: { $0.path.hasSuffix(".local/pipx/venvs/mlx-audio/bin/python3") }),
            "Default candidates must include the pipx venv path"
        )
        // System python should come before pipx venv.
        let systemIdx = candidates.firstIndex(where: { $0.path == "/usr/bin/python3" })
        let pipxIdx = candidates.firstIndex(where: { $0.path.hasSuffix(".local/pipx/venvs/mlx-audio/bin/python3") })
        if let s = systemIdx, let p = pipxIdx {
            XCTAssertLessThan(s, p, "System python should be probed before pipx venv")
        }
    }
}
