@testable import PippinLib
import XCTest

final class DoCommandTests: XCTestCase {
    // MARK: - Parse validation

    func testEmptyIntentFails() {
        XCTAssertThrowsError(try DoCommand.parse([""]))
    }

    func testMaxStepsZeroFails() {
        XCTAssertThrowsError(try DoCommand.parse(["hi", "--max-steps", "0"]))
    }

    func testMaxStepsOverTwentyFails() {
        XCTAssertThrowsError(try DoCommand.parse(["hi", "--max-steps", "21"]))
    }

    func testDryRunFlag() throws {
        let cmd = try DoCommand.parse(["check my mail", "--dry-run"])
        XCTAssertTrue(cmd.dryRun)
    }

    func testAcceptsProviderAndModel() throws {
        let cmd = try DoCommand.parse([
            "do stuff", "--provider", "claude", "--model", "claude-sonnet-4-6",
        ])
        XCTAssertEqual(cmd.provider, "claude")
        XCTAssertEqual(cmd.model, "claude-sonnet-4-6")
    }

    func testDefaultsMaxStepsToFive() throws {
        let cmd = try DoCommand.parse(["do stuff"])
        XCTAssertEqual(cmd.maxSteps, 5)
    }

    // MARK: - Child output decoding

    func testDecodeChildStdoutParsesEnvelope() {
        let envelope = """
        {"v":1,"status":"ok","duration_ms":5,"data":{"foo":1}}
        """
        let result = DoCommand.decodeChildStdout(Data(envelope.utf8))
        if case let .object(dict) = result {
            XCTAssertEqual(dict["status"]?.stringValue, "ok")
        } else {
            XCTFail("expected object, got \(result)")
        }
    }

    func testDecodeChildStdoutHandlesGarbage() {
        let result = DoCommand.decodeChildStdout(Data("not json".utf8))
        if case let .object(dict) = result,
           case let .object(errDict) = dict["error"]
        {
            XCTAssertEqual(errDict["code"]?.stringValue, "invalid_json")
        } else {
            XCTFail("expected invalid_json error, got \(result)")
        }
    }
}
