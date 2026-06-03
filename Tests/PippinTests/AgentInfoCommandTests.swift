@testable import PippinLib
import XCTest

/// Unit tests for the `agent-info` payload — verify the advertised contract
/// matches the actual implementation so the probe can't go stale.
final class AgentInfoCommandTests: XCTestCase {
    func testToolCountIsNonEmpty() {
        // The probe reads MCPToolRegistry.tools.count, the single source of
        // truth shared with `mcp-server --list-tools`. End-to-end parity with
        // the listing is asserted in CLIIntegrationTests; here we just guard
        // that the registry is non-empty.
        XCTAssertGreaterThan(MCPToolRegistry.tools.count, 0)
    }

    func testExitCodeCatalogMatchesClassifier() {
        // Every advertised exit code must be one the classifier can actually
        // produce (plus 0 = success), and retryable must agree.
        for entry in AgentInfoCommand.exitCodeCatalog where entry.code != 0 {
            XCTAssertTrue(
                [2, 3, 4, 5, 7].contains(entry.code),
                "Advertised code \(entry.code) is not in the classifier's range"
            )
        }
        // The 7 bucket is the only retryable one.
        let retryable = AgentInfoCommand.exitCodeCatalog.filter(\.retryable).map(\.code)
        XCTAssertEqual(retryable, [7])
    }

    func testEnvelopeEncodesSnakeCaseKeys() throws {
        let info = AgentInfo(
            name: "pippin",
            version: "9.9.9",
            tagline: "t",
            schemaVersion: AGENT_SCHEMA_VERSION,
            formats: ["agent"],
            exitCodes: AgentInfoCommand.exitCodeCatalog,
            globalFlags: ["--format"],
            experimentalEnabled: false,
            mcp: AgentInfo.MCPInfo(toolCount: 44),
            commands: ["mail"]
        )
        let data = try JSONEncoder().encode(info)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schema_version"] as? Int, AGENT_SCHEMA_VERSION)
        XCTAssertNotNil(json["global_flags"])
        XCTAssertNotNil(json["exit_codes"])
        let mcp = try XCTUnwrap(json["mcp"] as? [String: Any])
        XCTAssertEqual(mcp["tool_count"] as? Int, 44, "tool_count must be snake_case")
    }
}
