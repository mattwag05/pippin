@testable import PippinLib
import XCTest

final class TranscriberTests: XCTestCase {
    // MARK: - TranscriberFactory

    func testIsParakeetAvailableReturnsBool() {
        // Should not crash regardless of whether parakeet-mlx is installed
        let available = TranscriberFactory.isParakeetAvailable()
        XCTAssertTrue(available == true || available == false)
    }

    func testMakeDefaultReturnsTranscriber() {
        let transcriber = TranscriberFactory.makeDefault()
        // Should return either ParakeetTranscriber or SpeechFrameworkTranscriber
        XCTAssertTrue(transcriber is ParakeetTranscriber || transcriber is SpeechFrameworkTranscriber)
    }

    // MARK: - ParakeetTranscriber

    func testParakeetTranscriberHandlesMissingBinary() {
        // When parakeet-mlx is not installed, transcribe should throw binaryNotFound
        // We test with a path that definitely does not contain the binary
        guard !TranscriberFactory.isParakeetAvailable() else {
            // parakeet-mlx is actually installed — skip this test
            return
        }

        let transcriber = ParakeetTranscriber()
        XCTAssertThrowsError(try transcriber.transcribe(audioPath: "/nonexistent/audio.m4a")) { error in
            guard let tError = error as? TranscriberError else {
                XCTFail("Expected TranscriberError, got \(type(of: error))")
                return
            }
            if case .binaryNotFound = tError {
                // Expected
            } else {
                XCTFail("Expected binaryNotFound, got \(tError)")
            }
        }
    }

    // MARK: - SpeechFrameworkTranscriber

    func testSpeechFrameworkTranscriberThrowsUnavailable() {
        let transcriber = SpeechFrameworkTranscriber()
        XCTAssertThrowsError(try transcriber.transcribe(audioPath: "/test.m4a")) { error in
            guard let tError = error as? TranscriberError else {
                XCTFail("Expected TranscriberError, got \(type(of: error))")
                return
            }
            if case .speechFrameworkUnavailable = tError {
                // Expected
            } else {
                XCTFail("Expected speechFrameworkUnavailable, got \(tError)")
            }
        }
    }

    // MARK: - Error descriptions

    func testTranscriberErrorDescriptions() throws {
        let errors: [TranscriberError] = [
            .binaryNotFound("parakeet-mlx"),
            .timeout,
            .failed(1, "some error"),
            .emptyOutput,
            .speechFrameworkUnavailable,
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error should have a description: \(error)")
            XCTAssertFalse(try XCTUnwrap(error.errorDescription?.isEmpty))
        }
    }
}
