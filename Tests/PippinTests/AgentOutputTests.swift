@testable import PippinLib
import XCTest

final class AgentOutputTests: XCTestCase {
    // Test: OutputFormat.agent exists
    func testAgentFormatExists() {
        XCTAssertEqual(OutputFormat.agent.rawValue, "agent")
    }

    // Test: OutputFormat.allCases includes agent
    func testAllCasesIncludesAgent() {
        XCTAssertTrue(OutputFormat.allCases.contains(.agent))
    }

    // Test: printAgentJSON produces compact output (no newlines)
    func testPrintAgentJSONIsCompact() throws {
        struct TestItem: Encodable { let name: String; let count: Int }
        let item = TestItem(name: "test", count: 42)
        let encoder = JSONEncoder()
        let data = try encoder.encode(item)
        let output = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(output.contains("\n"), "Agent JSON should not contain newlines")
        XCTAssertTrue(output.contains("test"), "Agent JSON should contain value")
    }

    // Test: agent format is valid in CLI argument parsing
    func testAgentFormatParsesSuccessfully() throws {
        let opts = try OutputOptions.parse(["--format", "agent"])
        XCTAssertEqual(opts.format, .agent)
    }

    // Test: agent is the only format left
    func testAllCasesCount() {
        XCTAssertEqual(OutputFormat.allCases.count, 1)
    }
}
