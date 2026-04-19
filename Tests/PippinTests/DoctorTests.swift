@testable import PippinLib
import XCTest

final class DoctorTests: XCTestCase {
    // MARK: - classifyMailError

    func testClassifyMailErrorTCC() {
        let check = classifyMailError("not authorized to send Apple events")
        XCTAssertEqual(check.status, .fail)
        XCTAssertNil(
            check.remediation?.shellCommand,
            "TCC remediation must be human-only (no shellCommand), got: \(String(describing: check.remediation?.shellCommand))"
        )
    }

    func testClassifyMailErrorNotRunning() {
        let check = classifyMailError("")
        XCTAssertEqual(check.status, .fail)
        XCTAssertEqual(
            check.remediation?.shellCommand,
            "open -a Mail && sleep 4",
            "Not-running remediation must set shellCommand to open Mail"
        )
    }

    func testClassifyMailErrorUnknown() {
        let check = classifyMailError("socket timeout")
        XCTAssertEqual(check.status, .fail)
        XCTAssertTrue(
            check.detail.contains("socket timeout"),
            "Unknown error detail should pass through, got: \(check.detail)"
        )
        XCTAssertNil(
            check.remediation?.shellCommand,
            "Unknown remediation must not carry a shellCommand"
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
        XCTAssertEqual(check.remediation?.shellCommand, "brew install python3")
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
        XCTAssertNil(
            check.remediation?.shellCommand,
            "Calendar permission-denied remediation must not carry a shellCommand"
        )
    }

    func testRemindersPermissionDeniedNoRunnableCommand() {
        let checks = runAllChecks()
        guard let check = checks.first(where: { $0.name == "Reminders access" }),
              check.status == .fail else { return }
        XCTAssertNil(
            check.remediation?.shellCommand,
            "Reminders permission-denied remediation must not carry a shellCommand"
        )
    }

    func testContactsPermissionDeniedNoRunnableCommand() {
        let checks = runAllChecks()
        guard let check = checks.first(where: { $0.name == "Contacts access" }),
              check.status == .fail else { return }
        XCTAssertNil(
            check.remediation?.shellCommand,
            "Contacts permission-denied remediation must not carry a shellCommand"
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
        XCTAssertNotNil(
            remediation.shellCommand,
            "mlx-audio remediation must carry a shellCommand"
        )
    }

    func testNodeJSRemediationHasRunnableCommand() {
        let checks = runAllChecks()
        guard let check = checks.first(where: { $0.name == "Node.js" }),
              let remediation = check.remediation else { return }
        XCTAssertNotNil(
            remediation.shellCommand,
            "Node.js remediation must carry a shellCommand"
        )
    }

    func testPlaywrightRemediationHasRunnableCommand() {
        let checks = runAllChecks()
        guard let check = checks.first(where: { $0.name == "Playwright" }),
              let remediation = check.remediation else { return }
        XCTAssertNotNil(
            remediation.shellCommand,
            "Playwright remediation must carry a shellCommand"
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
        // Pipx venv should come before system python — pipx is the recommended install path
        // on modern macOS where Homebrew Python is externally-managed.
        let pipxIdx = candidates.firstIndex(where: { $0.path.hasSuffix(".local/pipx/venvs/mlx-audio/bin/python3") })
        let systemIdx = candidates.firstIndex(where: { $0.path == "/usr/bin/python3" })
        if let p = pipxIdx, let s = systemIdx {
            XCTAssertLessThan(p, s, "Pipx venv should be probed before system python")
        }
    }
}
