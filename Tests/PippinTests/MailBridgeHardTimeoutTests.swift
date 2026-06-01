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
}
