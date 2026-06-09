@testable import PippinLib
import XCTest

/// Tests for the shared temp-file helpers (pippin-u39) that replaced the
/// hand-rolled `temporaryDirectory + UUID + defer` pattern in the audio/browser
/// bridges.
final class TemporaryFileTests: XCTestCase {
    func testTemporaryFileURLHasPrefixExtensionAndIsUnique() {
        let a = temporaryFileURL(prefix: "pippin-test-", extension: "wav")
        let b = temporaryFileURL(prefix: "pippin-test-", extension: "wav")

        XCTAssertEqual(a.pathExtension, "wav")
        XCTAssertTrue(a.lastPathComponent.hasPrefix("pippin-test-"))
        XCTAssertEqual(a.deletingLastPathComponent().path,
                       FileManager.default.temporaryDirectory.path)
        XCTAssertNotEqual(a, b, "each call yields a fresh UUID")
    }

    func testTemporaryFileURLWithoutExtension() {
        let url = temporaryFileURL(prefix: "pippin-base-")
        XCTAssertEqual(url.pathExtension, "")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("pippin-base-"))
    }

    func testWithTemporaryFileReturnsBodyValueAndCleansUp() throws {
        var captured: URL?
        let result = try withTemporaryFile(prefix: "pippin-test-", extension: "txt") { url in
            captured = url
            try "hello".write(to: url, atomically: true, encoding: .utf8)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            return 42
        }
        XCTAssertEqual(result, 42)
        let url = try XCTUnwrap(captured)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "the temp file is removed after the closure returns")
    }

    func testWithTemporaryFileCleansUpEvenWhenBodyThrows() {
        struct Boom: Error {}
        var captured: URL?
        XCTAssertThrowsError(try withTemporaryFile(prefix: "pippin-test-", extension: "txt") { url in
            captured = url
            try "x".write(to: url, atomically: true, encoding: .utf8)
            throw Boom()
        })
        if let url = captured {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                           "the temp file is removed even when the closure throws")
        } else {
            XCTFail("closure never ran")
        }
    }

    func testWithTemporaryFileToleratesUncreatedFile() throws {
        // A body that never writes the file must not fail cleanup.
        let result = try withTemporaryFile(prefix: "pippin-test-", extension: "json") { _ in "ok" }
        XCTAssertEqual(result, "ok")
    }
}
