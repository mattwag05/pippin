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
}
