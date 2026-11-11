import ArgumentParser
@testable import PippinLib
import XCTest

/// Unit tests for the runtime-error → process-exit-code mapping.
final class PippinExitCodeTests: XCTestCase {
    func testTimeoutAndRateLimitMapTo7() {
        XCTAssertEqual(PippinExitCode.classify("timed_out"), 7)
        XCTAssertEqual(PippinExitCode.classify("timeout"), 7)
        XCTAssertEqual(PippinExitCode.classify("child_timed_out"), 7)
        XCTAssertEqual(PippinExitCode.classify("wait_timed_out"), 7)
        XCTAssertEqual(PippinExitCode.classify("rate_limited"), 7)
    }

    func testAuthPermissionConfigMapTo4() {
        XCTAssertEqual(PippinExitCode.classify("access_denied"), 4)
        XCTAssertEqual(PippinExitCode.classify("autonomous_not_authorized"), 4)
        XCTAssertEqual(PippinExitCode.classify("missing_api_key"), 4)
        XCTAssertEqual(PippinExitCode.classify("not_available"), 4)
    }

    func testNotFoundMapsTo3() {
        XCTAssertEqual(PippinExitCode.classify("not_found"), 3)
        XCTAssertEqual(PippinExitCode.classify("event_not_found"), 3)
        XCTAssertEqual(PippinExitCode.classify("memo_not_found"), 3)
        XCTAssertEqual(PippinExitCode.classify("job_not_found"), 3)
        XCTAssertEqual(PippinExitCode.classify("database_not_found"), 3)
    }

    func testUsageMapsTo2() {
        XCTAssertEqual(PippinExitCode.classify("missing_required"), 2)
        XCTAssertEqual(PippinExitCode.classify("invalid_cursor"), 2)
        XCTAssertEqual(PippinExitCode.classify("invalid_page_size"), 2)
        XCTAssertEqual(PippinExitCode.classify("invalid_json"), 2)
        XCTAssertEqual(PippinExitCode.classify("invalid_mailbox"), 2)
    }

    func testUnknownAndBridgeFailuresDefaultTo5() {
        XCTAssertEqual(PippinExitCode.classify("script_failed"), 5)
        XCTAssertEqual(PippinExitCode.classify("database_error"), 5)
        XCTAssertEqual(PippinExitCode.classify("something_unexpected"), 5)
        XCTAssertEqual(PippinExitCode.classify(""), 5)
        XCTAssertEqual(PippinExitCode.toolFailure, 5)
    }

    func testRetryableBucketWinsOverNotFoundOrdering() {
        // A hypothetical future code carrying both signals must land on the
        // retryable bucket (checked first), not be mis-routed.
        XCTAssertEqual(PippinExitCode.classify("lookup_timed_out"), 7)
    }

    func testFromErrorDerivesCodeFromEnumCase() {
        // jobNotFound("...") → "job_not_found" → 3
        XCTAssertEqual(PippinExitCode.from(JobStoreError.jobNotFound("abc")), 3)
    }

    // MARK: - ArgumentParser errors → usage (pippin-3sy)

    /// A thrown `ValidationError` is bad input, not a tool/bridge failure — it
    /// must exit 2 (usage) so an agent can distinguish "fix my args and retry"
    /// from "the tool broke." Its derived code `validation_error` doesn't match
    /// the string buckets, so the routing keys off the ArgumentParser type.
    func testValidationErrorMapsTo2() {
        XCTAssertEqual(PippinExitCode.from(ValidationError("--start must be YYYY-MM-DD")), 2)
    }

    /// ArgumentParser's parse-time failures (missing required arg, unknown flag)
    /// surface as `CommandError` in agent mode — also usage → 2.
    func testArgumentParserCommandErrorMapsTo2() {
        let commandError: Error
        do {
            _ = try ProbeArgs.parse(["--unknown"])
            commandError = ValidationError("unreachable")
        } catch {
            commandError = error
        }
        XCTAssertTrue(String(reflecting: type(of: commandError)).hasPrefix("ArgumentParser."))
        XCTAssertEqual(PippinExitCode.from(commandError), 2)
    }
}

private struct ProbeArgs: ParsableArguments {
    @Option var start: String = ""
}
