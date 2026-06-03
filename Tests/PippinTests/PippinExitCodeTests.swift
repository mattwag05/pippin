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
}
