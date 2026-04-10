@testable import PippinLib
import XCTest

final class InitCommandTests: XCTestCase {
    // MARK: - InitReport Codable

    func testInitReportReadyWhenAllOK() {
        let checks = [
            DiagnosticCheck(name: "macOS", status: .ok, detail: "26.0"),
            DiagnosticCheck(name: "Mail", status: .ok, detail: "granted"),
        ]
        let report = InitReport(checks: checks)
        XCTAssertTrue(report.ready)
    }

    func testInitReportNotReadyWhenFail() {
        let checks = [
            DiagnosticCheck(name: "macOS", status: .ok, detail: "26.0"),
            DiagnosticCheck(name: "Mail", status: .fail, detail: "denied", remediation: "fix it"),
        ]
        let report = InitReport(checks: checks)
        XCTAssertFalse(report.ready)
    }

    func testInitReportReadyWhenSkipsOnly() {
        let checks = [
            DiagnosticCheck(name: "macOS", status: .ok, detail: "26.0"),
            DiagnosticCheck(name: "Contacts", status: .skip, detail: "not determined"),
        ]
        let report = InitReport(checks: checks)
        XCTAssertTrue(report.ready)
    }

    func testInitReportRoundTrip() throws {
        let checks = [
            DiagnosticCheck(name: "test", status: .ok, detail: "good"),
            DiagnosticCheck(name: "bad", status: .fail, detail: "broken", remediation: "fix"),
        ]
        let report = InitReport(checks: checks)
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(InitReport.self, from: data)
        XCTAssertEqual(decoded.ready, false)
        XCTAssertEqual(decoded.checks.count, 2)
        XCTAssertEqual(decoded.checks[0].name, "test")
        XCTAssertEqual(decoded.checks[1].status, .fail)
        XCTAssertEqual(decoded.checks[1].remediation, "fix")
    }

    // MARK: - Command Configuration

    func testInitCommandConfiguration() {
        XCTAssertEqual(InitCommand.configuration.commandName, "init")
    }

    func testInitCommandParsesNoArgs() throws {
        let command = try InitCommand.parse([])
        XCTAssertEqual(command.output.format, .text)
    }

    func testInitCommandParsesAgentFormat() throws {
        let command = try InitCommand.parse(["--format", "agent"])
        XCTAssertTrue(command.output.isAgent)
    }

    func testInitCommandParsesJSONFormat() throws {
        let command = try InitCommand.parse(["--format", "json"])
        XCTAssertTrue(command.output.isJSON)
    }
}
