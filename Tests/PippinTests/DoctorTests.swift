@testable import PippinLib
import XCTest

final class DoctorTests: XCTestCase {
    /// Cached `runAllChecks()` result reused across every test below that
    /// asserts on a specific check. The full battery includes EventKit
    /// auth probes + a 3s Ollama HTTP request + Python/Node/Playwright
    /// subprocess waits — running it 7+ times per test process added ~30s
    /// to the suite. Lazy + Sendable means it computes once on first use.
    nonisolated(unsafe) static let cachedChecks: [DiagnosticCheck] = runAllChecks()

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

    // Model-name matching tests (formerly `ollamaModelIsAvailable`, pippin-n5p)
    // moved to AIProviderTests — the helper now lives on OllamaProvider, shared
    // between `doctor` and the provider's 404 model-not-found path (issue #22).

    // MARK: - classifyLatency (pippin-11e)

    func testClassifyLatencyFastIsOK() {
        let check = classifyLatency(name: "Mail list latency", ms: 250)
        XCTAssertEqual(check.status, .ok)
        XCTAssertTrue(check.detail.contains("250ms"))
        XCTAssertNil(check.remediation)
    }

    func testClassifyLatencySlowWarns() {
        // 25s — over the 22s soft cap, under the 55s MCP boundary.
        let check = classifyLatency(name: "Mail list latency", ms: 25000)
        XCTAssertEqual(check.status, .skip)
        XCTAssertTrue(check.detail.contains("warning"))
        XCTAssertTrue(check.detail.contains("25000ms"))
    }

    func testClassifyLatencyExceedingMCPCapFails() {
        // 56s — over the 55s red threshold.
        let check = classifyLatency(name: "Mail activity latency", ms: 56000)
        XCTAssertEqual(check.status, .fail)
        XCTAssertTrue(check.detail.contains("MCP"))
        XCTAssertNotNil(check.remediation?.shellCommand)
    }

    func testClassifyLatencyBoundary55sIsFail() {
        // Exactly at the boundary — must be classified as fail.
        let check = classifyLatency(name: "Mail search latency", ms: 55000)
        XCTAssertEqual(check.status, .fail)
    }

    func testClassifyLatencyBoundary20sIsWarn() {
        let check = classifyLatency(name: "Mail search latency", ms: 20000)
        XCTAssertEqual(check.status, .skip)
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
        let checks = Self.cachedChecks
        guard let check = checks.first(where: { $0.name == "Calendar access" }),
              check.status == .fail else { return }
        XCTAssertNil(
            check.remediation?.shellCommand,
            "Calendar permission-denied remediation must not carry a shellCommand"
        )
    }

    func testRemindersPermissionDeniedNoRunnableCommand() {
        let checks = Self.cachedChecks
        guard let check = checks.first(where: { $0.name == "Reminders access" }),
              check.status == .fail else { return }
        XCTAssertNil(
            check.remediation?.shellCommand,
            "Reminders permission-denied remediation must not carry a shellCommand"
        )
    }

    func testContactsPermissionDeniedNoRunnableCommand() {
        let checks = Self.cachedChecks
        guard let check = checks.first(where: { $0.name == "Contacts access" }),
              check.status == .fail else { return }
        XCTAssertNil(
            check.remediation?.shellCommand,
            "Contacts permission-denied remediation must not carry a shellCommand"
        )
    }

    // MARK: - Agent-actionable remediations (must have $ command)

    func testMLXAudioIsRequiredCheck() {
        let checks = Self.cachedChecks
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
        let checks = Self.cachedChecks
        guard let check = checks.first(where: { $0.name == "mlx-audio" }),
              let remediation = check.remediation else { return }
        XCTAssertNotNil(
            remediation.shellCommand,
            "mlx-audio remediation must carry a shellCommand"
        )
    }

    func testNodeJSRemediationHasRunnableCommand() {
        let checks = Self.cachedChecks
        guard let check = checks.first(where: { $0.name == "Node.js" }),
              let remediation = check.remediation else { return }
        XCTAssertNotNil(
            remediation.shellCommand,
            "Node.js remediation must carry a shellCommand"
        )
    }

    func testPlaywrightRemediationHasRunnableCommand() {
        let checks = Self.cachedChecks
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

    // MARK: - sttFlagsMissing (mlx-audio arg-shape probe, pippin-xua)

    /// Real `mlx_audio.stt.generate --help` (0.4.2) usage/options excerpt.
    private static let mlxAudio042Help = """
    usage: mlx_audio.stt.generate [-h] [--model MODEL] --audio AUDIO
                                  --output-path OUTPUT_PATH
                                  [--format {txt,srt,vtt,json}] [--verbose]

    options:
      -h, --help            show this help message and exit
      --model MODEL         Path to the model
      --audio AUDIO         Path to the audio file
      --output-path OUTPUT_PATH
                            Path to save the output
      --format {txt,srt,vtt,json}
                            Output format (txt, srt, vtt, or json)
    """

    func testSTTFlagsMissingNoneOnRealHelp() {
        // The flags pippin passes under the generate contract are all advertised
        // by the installed 0.4.2 CLI → nothing missing → doctor stays green.
        let expected = AudioBridge.expectedSTTFlags(for: AudioBridge.STTEntry(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            prefixArgs: ["-m", "mlx_audio.stt.generate"],
            contract: .generate
        ))
        let missing = sttFlagsMissing(fromHelp: Self.mlxAudio042Help, expected: expected)
        XCTAssertEqual(missing, [], "All generate-contract flags are present in 0.4.2 help")
    }

    /// Regression for pippin-xua: a version skew that drops/renames `--audio`
    /// must be caught — exactly the class of break that let pippin-8ik ship
    /// while doctor reported all-green.
    func testSTTFlagsMissingDetectsDroppedFlag() {
        let skewedHelp = Self.mlxAudio042Help.replacingOccurrences(of: "--audio", with: "--input")
        let expected = ["--model", "--audio", "--output-path", "--format"]
        let missing = sttFlagsMissing(fromHelp: skewedHelp, expected: expected)
        XCTAssertEqual(missing, ["--audio"], "A renamed --audio flag must be reported missing")
    }

    func testSTTFlagsMissingRespectsTokenBoundary() {
        // `--format` must NOT be satisfied by a longer flag that merely shares
        // its prefix.
        let help = "options:\n  --format-version VER   unrelated flag\n"
        XCTAssertEqual(
            sttFlagsMissing(fromHelp: help, expected: ["--format"]),
            ["--format"],
            "--format must not match --format-version"
        )
        // But a genuine --format elsewhere does satisfy it.
        let help2 = help + "  --format FMT   the real one\n"
        XCTAssertEqual(sttFlagsMissing(fromHelp: help2, expected: ["--format"]), [])
    }
}
