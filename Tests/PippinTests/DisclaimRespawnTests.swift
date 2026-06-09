@testable import PippinLib
import XCTest

/// Tests for the re-exec-disclaimed decision logic (pippin-0vr). The actual
/// posix_spawn lives in the CDisclaimSpawn C target; here we only pin the pure
/// guard that decides whether to re-exec.
final class DisclaimRespawnTests: XCTestCase {
    func testRespawnsByDefault() {
        XCTAssertTrue(DisclaimRespawn.shouldRespawn(environment: [:]))
        XCTAssertTrue(DisclaimRespawn.shouldRespawn(environment: ["HOME": "/x"]))
    }

    func testDoesNotRespawnWhenAlreadyDisclaimed() {
        XCTAssertFalse(DisclaimRespawn.shouldRespawn(environment: [DisclaimRespawn.guardKey: "1"]))
        // Any value of the guard counts — it's set by the re-exec'd child.
        XCTAssertFalse(DisclaimRespawn.shouldRespawn(environment: [DisclaimRespawn.guardKey: "anything"]))
    }

    func testOptOutDisablesRespawn() {
        XCTAssertFalse(DisclaimRespawn.shouldRespawn(environment: [DisclaimRespawn.optOutKey: "1"]))
        XCTAssertFalse(DisclaimRespawn.shouldRespawn(environment: [DisclaimRespawn.optOutKey: "true"]))
        XCTAssertFalse(DisclaimRespawn.shouldRespawn(environment: [DisclaimRespawn.optOutKey: "TRUE"]))
    }

    func testOptOutOnlyHonorsTruthyValues() {
        // A non-truthy opt-out value must NOT disable disclaim (avoids surprises
        // from an empty/legacy export like PIPPIN_NO_DISCLAIM=0).
        XCTAssertTrue(DisclaimRespawn.shouldRespawn(environment: [DisclaimRespawn.optOutKey: "0"]))
        XCTAssertTrue(DisclaimRespawn.shouldRespawn(environment: [DisclaimRespawn.optOutKey: ""]))
    }

    func testGuardWinsOverMissingOptOut() {
        let env = [DisclaimRespawn.guardKey: "1", "FOO": "bar"]
        XCTAssertFalse(DisclaimRespawn.shouldRespawn(environment: env))
    }
}
