@testable import PippinLib
import XCTest

/// Tests for `MailBridge.clampHardTimeout` — the ScriptRunner hard-timeout
/// clamp that keeps cross-account-scaled mail scans below the 60s MCP
/// `runChild` cap so a wedged osascript is reaped gracefully (partial results /
/// `.timeout`) instead of being SIGKILLed by the MCP layer (`.childTimedOut`).
final class MailBridgeHardTimeoutTests: XCTestCase {
    func testCliLeavesTimeoutUnclamped() {
        // In CLI there is no runChild cap — the full cross-account-scaled value
        // must pass through untouched.
        XCTAssertEqual(MailBridge.clampHardTimeout(95, underMCP: false), 95)
        XCTAssertEqual(MailBridge.clampHardTimeout(75, underMCP: false), 75)
        XCTAssertEqual(MailBridge.clampHardTimeout(10, underMCP: false), 10)
    }

    func testMcpClampsAboveCeiling() {
        // Values exceeding the 55s ceiling (single-account --body 75s,
        // cross-account --body 95s, cross-account activity 115s) must clamp.
        XCTAssertEqual(MailBridge.clampHardTimeout(75, underMCP: true), 55)
        XCTAssertEqual(MailBridge.clampHardTimeout(95, underMCP: true), 55)
        XCTAssertEqual(MailBridge.clampHardTimeout(115, underMCP: true), 55)
        XCTAssertEqual(MailBridge.clampHardTimeout(65, underMCP: true), 55)
    }

    func testMcpLeavesValuesAtOrBelowCeiling() {
        // Single-account no --body (45s) and short list scans stay under the
        // ceiling and must not be inflated.
        XCTAssertEqual(MailBridge.clampHardTimeout(55, underMCP: true), 55)
        XCTAssertEqual(MailBridge.clampHardTimeout(45, underMCP: true), 45)
        XCTAssertEqual(MailBridge.clampHardTimeout(10, underMCP: true), 10)
    }

    func testClampStaysBelowRunChildCap() {
        // The whole point: the MCP-clamped ceiling must be strictly below the
        // runtime's hard cap so the bridge self-reaps first.
        let clamped = MailBridge.clampHardTimeout(999, underMCP: true)
        XCTAssertLessThan(clamped, MCPServerRuntime.defaultChildTimeoutSeconds)
    }

    // MARK: - listScanTimeout soft-cap floor (pippin-zzdd, pippin-9rf0)

    func testSingleAccountListOutlastsTheSoftCap() {
        // A 10s hard timeout killed slow JXA scans before the 22s soft cap
        // could return partial rows.
        let softSeconds = SoftTimeout.defaultMs / 1000
        let timeout = MailBridge.listScanTimeout(crossAccount: false, fetchesBodies: false)
        XCTAssertGreaterThan(timeout, softSeconds)
        XCTAssertEqual(timeout, softSeconds + MailBridge.softCapHeadroomSeconds)
    }

    func testListTimeoutTracksTheCallersSoftCap() {
        XCTAssertEqual(
            MailBridge.listScanTimeout(crossAccount: false, fetchesBodies: false, softTimeoutMs: 40000),
            40 + MailBridge.softCapHeadroomSeconds
        )
        // Larger fixed budgets are kept when they already exceed the floor.
        XCTAssertEqual(MailBridge.listScanTimeout(crossAccount: true, fetchesBodies: false), 60)
        XCTAssertEqual(MailBridge.listScanTimeout(crossAccount: true, fetchesBodies: true), 100)
        XCTAssertEqual(MailBridge.listScanTimeout(crossAccount: false, fetchesBodies: true), 50)
    }

    func testListTimeoutStaysUnderTheMcpCeilingByDefault() {
        // Under MCP the default single-account budget must still let the soft
        // cap fire before the 55s clamp.
        let timeout = MailBridge.listScanTimeout(crossAccount: false, fetchesBodies: false)
        XCTAssertEqual(MailBridge.clampHardTimeout(timeout, underMCP: true), timeout)
    }
}
