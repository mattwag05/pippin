import CoreServices
@testable import PippinLib
import XCTest

/// Pure-mapping tests for the Automation (Apple Events) pre-flight decision.
/// These exercise `AutomationPermission.decision(for:)` without touching TCC,
/// so they're deterministic in CI. (pippin-qjf)
final class AutomationPermissionTests: XCTestCase {
    func testExplicitDenialFastFails() {
        XCTAssertEqual(
            AutomationPermission.decision(for: OSStatus(errAEEventNotPermitted)),
            .deny
        )
    }

    func testUndeterminedUnpromptableFastFails() {
        // Returned when askUserIfNeeded was false (non-interactive/MCP) and the
        // grant is undetermined — the exact 22s-hang case we want to short-circuit.
        XCTAssertEqual(
            AutomationPermission.decision(for: OSStatus(errAEEventWouldRequireUserConsent)),
            .deny
        )
    }

    func testAuthorizedProceeds() {
        XCTAssertEqual(AutomationPermission.decision(for: noErr), .allow)
    }

    func testAppNotRunningProceeds() {
        // We can't know the grant until the target launches; let the normal
        // script path (with its launcher retry) handle it rather than fast-fail.
        XCTAssertEqual(AutomationPermission.decision(for: OSStatus(procNotFound)), .allow)
    }

    func testUnexpectedStatusProceeds() {
        // A surprise status must never regress a working setup into a false deny.
        XCTAssertEqual(AutomationPermission.decision(for: OSStatus(-12345)), .allow)
    }
}
