@testable import PippinLib
import XCTest

final class TranscriberTests: XCTestCase {
    // MARK: - MLXAudioTranscriber

    func testMLXAudioTranscriberNotAvailableThrows() {
        guard !AudioBridge.isAvailable() else {
            // mlx-audio is installed — skip this test
            return
        }
        let transcriber = MLXAudioTranscriber()
        XCTAssertThrowsError(try transcriber.transcribe(audioPath: "/nonexistent/audio.m4a")) { error in
            guard let tError = error as? TranscriberError else {
                XCTFail("Expected TranscriberError, got \(type(of: error))")
                return
            }
            if case .notAvailable = tError {
                // Expected
            } else {
                XCTFail("Expected .notAvailable, got \(tError)")
            }
        }
    }

    func testMLXAudioTranscriberDefaultModel() {
        let transcriber = MLXAudioTranscriber()
        XCTAssertEqual(transcriber.model, "parakeet")
    }

    func testMLXAudioTranscriberCustomModel() {
        let transcriber = MLXAudioTranscriber(model: "whisper")
        XCTAssertEqual(transcriber.model, "whisper")
    }

    // MARK: - TranscriberError descriptions

    func testTranscriberErrorDescriptions() throws {
        let errors: [TranscriberError] = [
            .notAvailable,
            .timeout,
            .processFailed(1, "some error"),
            .emptyOutput,
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error should have a description: \(error)")
            XCTAssertFalse(try XCTUnwrap(error.errorDescription?.isEmpty))
        }
    }

    func testNotAvailableErrorContainsInstallCommand() {
        let error = TranscriberError.notAvailable
        XCTAssertTrue(
            error.errorDescription?.contains("pip install mlx-audio") == true,
            "notAvailable error should include install command, got: \(error.errorDescription ?? "nil")"
        )
    }

    // MARK: - mlx-audio STT entry resolution

    func testPinnedMLXAudioVersionIsSet() {
        XCTAssertFalse(AudioBridge.pinnedMLXAudioVersion.isEmpty)
    }

    /// `resolveSTTEntry()` must either return `nil` (no mlx-audio installed)
    /// or an entry whose executable actually exists on disk.
    func testResolveSTTEntryReturnsUsablePath() {
        guard let entry = AudioBridge.resolveSTTEntry() else { return }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: entry.executable.path),
            "STT entry executable must exist at \(entry.executable.path)"
        )
    }

    func testVersionMismatchErrorMessage() {
        let error = AudioBridgeError.versionMismatch(installed: "0.3.0", pinned: "0.4.2")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("0.3.0"), "must mention installed version")
        XCTAssertTrue(description.contains("0.4.2"), "must mention pinned version")
        XCTAssertTrue(
            description.contains("pipx install"),
            "must include pipx install remediation"
        )
    }
}
