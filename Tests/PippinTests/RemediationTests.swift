@testable import PippinLib
import XCTest

final class RemediationTests: XCTestCase {
    // MARK: - Catalog lookup

    func testAccessDeniedIsCatalogued() throws {
        let remediation = try XCTUnwrap(RemediationCatalog.forCode("access_denied"))
        XCTAssertTrue(remediation.humanHint.contains("Full Disk Access"))
        XCTAssertEqual(remediation.doctorCheck, "Voice Memos access")
    }

    func testDatabaseNotFoundIsCatalogued() throws {
        let remediation = try XCTUnwrap(RemediationCatalog.forCode("database_not_found"))
        XCTAssertEqual(remediation.shellCommand, "open -a \"Voice Memos\" && sleep 3")
    }

    func testNotAvailableIsCatalogued() throws {
        // Transcriber.notAvailable — mlx-audio missing
        let remediation = try XCTUnwrap(RemediationCatalog.forCode("not_available"))
        XCTAssertTrue(remediation.humanHint.contains("mlx-audio"))
        XCTAssertEqual(remediation.shellCommand, "pipx install mlx-audio")
    }

    func testUnknownCodeReturnsNil() {
        XCTAssertNil(RemediationCatalog.forCode("this_is_not_a_real_code"))
    }

    /// Every `ErrorCategory` case must yield a non-empty hint + doctor pointer.
    /// Guards against a future case being added to the enum without matching
    /// text in `forCategory(_:)`.
    func testEveryErrorCategoryHasText() {
        for category in ErrorCategory.allCases {
            let remediation = RemediationCatalog.forCategory(category)
            XCTAssertFalse(
                remediation.humanHint.isEmpty,
                "ErrorCategory.\(category) has empty humanHint"
            )
            XCTAssertFalse(
                remediation.doctorCheck.isEmpty,
                "ErrorCategory.\(category) has empty doctorCheck"
            )
        }
    }

    /// `forCode(String)` must round-trip through `ErrorCategory.rawValue`.
    func testForCodeRoundTripsWithRawValue() {
        for category in ErrorCategory.allCases {
            XCTAssertNotNil(
                RemediationCatalog.forCode(category.rawValue),
                "forCode failed to resolve \(category.rawValue)"
            )
        }
    }

    func testForErrorResolvesViaSnakeCaseCode() throws {
        let error = VoiceMemosError.accessDenied("whatever")
        let remediation = try XCTUnwrap(RemediationCatalog.forError(error))
        XCTAssertTrue(remediation.humanHint.contains("Full Disk Access"))
    }

    func testForErrorReturnsNilForUncataloguedCase() {
        let error = VoiceMemosError.memoNotFound("abc123")
        XCTAssertNil(RemediationCatalog.forError(error))
    }

    // MARK: - AgentError integration

    /// Agent-mode JSON for a catalogued error must include `remediation`.
    /// Also: JSON key must use snake_case ("human_hint", not "humanHint").
    func testAgentErrorIncludesRemediationWhenCatalogued() throws {
        let agentError = AgentError.from(VoiceMemosError.accessDenied("raw detail"))
        let data = try JSONEncoder().encode(agentError)
        let string = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(string.contains("\"code\":\"access_denied\""))
        XCTAssertTrue(string.contains("\"remediation\""))
        XCTAssertTrue(string.contains("\"human_hint\""))
        XCTAssertTrue(string.contains("\"doctor_check\":\"Voice Memos access\""))
    }

    /// When there's no catalog entry, `remediation` must be OMITTED (not null).
    /// Important for backward compatibility — existing agent consumers don't
    /// expect to see a `remediation: null` field on errors that previously
    /// had no such field at all.
    func testAgentErrorOmitsRemediationWhenUncatalogued() throws {
        let agentError = AgentError.from(VoiceMemosError.memoNotFound("abc123"))
        let data = try JSONEncoder().encode(agentError)
        let string = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(string.contains("\"code\":\"memo_not_found\""))
        XCTAssertFalse(
            string.contains("\"remediation\""),
            "Remediation field must be omitted (not present as null) for uncatalogued errors, got: \(string)"
        )
    }

    func testAgentErrorShellCommandOmittedWhenNil() throws {
        // access_denied has no shell_command (FDA fix requires System Settings UI).
        let agentError = AgentError.from(VoiceMemosError.accessDenied("raw"))
        let data = try JSONEncoder().encode(agentError)
        let string = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(
            string.contains("\"shell_command\""),
            "shell_command must be omitted when nil, got: \(string)"
        )
    }

    func testAgentErrorShellCommandPresentWhenNotNil() throws {
        // database_not_found does have a shell_command.
        let agentError = AgentError.from(VoiceMemosError.databaseNotFound("/tmp/bogus.db"))
        let data = try JSONEncoder().encode(agentError)
        let string = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(string.contains("\"shell_command\""))
    }
}
