import Foundation
@testable import PippinLib
import XCTest

final class SafetyPolicyTests: XCTestCase {
    private var sandbox = SafetySandbox()

    override func setUp() {
        sandbox = SafetySandbox()
    }

    override func tearDown() {
        sandbox.remove()
    }

    private func load(_ json: String) throws -> SafetyPolicy {
        try sandbox.writePolicy(json)
        return try SafetyPolicy.load(path: sandbox.policyPath)
    }

    private func rule(_ policy: SafetyPolicy, _ name: String) throws -> SafetyPolicy.Rule {
        try policy.rule(for: safetyTool(name)).rule
    }

    // MARK: - Defaults

    func testMissingFileIsTheBuiltInPolicy() throws {
        let policy = try SafetyPolicy.load(path: sandbox.policyPath)
        XCTAssertEqual(policy, SafetyPolicy())
        for tool in MCPToolRegistry.tools {
            let expected: SafetyPolicy.Rule = tool.effect != .readOnly
                && (["mail_send", "mail_reply", "mail_forward", "messages_send"].contains(tool.name) || tool.name.hasSuffix("_delete"))
                ? .confirm : .allow
            XCTAssertEqual(policy.rule(for: tool).rule, expected, tool.name)
            XCTAssertEqual(policy.rule(for: tool).source, "default", tool.name)
        }
        XCTAssertEqual(try rule(policy, "notes_delete"), .confirm)
        XCTAssertEqual(try rule(policy, "mail_move"), .allow)
    }

    func testDefaultLimitsCoverSendsAndDeletesOnly() throws {
        let policy = SafetyPolicy()
        XCTAssertEqual(try policy.limit(for: safetyTool("mail_send")), .init(max: 10, perSeconds: 3600))
        XCTAssertEqual(try policy.limit(for: safetyTool("messages_send")), .init(max: 10, perSeconds: 3600))
        XCTAssertEqual(try policy.limit(for: safetyTool("calendar_delete")), .init(max: 30, perSeconds: 3600))
        XCTAssertNil(try policy.limit(for: safetyTool("mail_move")))
        XCTAssertNil(try policy.limit(for: safetyTool("mail_list")))
    }

    // MARK: - Specificity

    func testMostSpecificRuleWins() throws {
        let policy = try load(#"{"rules": {"*": "allow", "messages_*": "deny", "messages_exclude_*": "confirm", "messages_send": "confirm", "mail_move": "deny"}}"#)
        XCTAssertEqual(try rule(policy, "messages_send"), .confirm, "exact beats prefix")
        XCTAssertEqual(try rule(policy, "messages_exclude_add"), .confirm, "longer prefix beats shorter")
        XCTAssertEqual(try rule(policy, "messages_list"), .deny, "prefix beats *")
        XCTAssertEqual(try rule(policy, "mail_move"), .deny)
        XCTAssertEqual(try rule(policy, "mail_send"), .allow, "* in the file replaces the built-in confirm")
        XCTAssertEqual(try policy.rule(for: safetyTool("messages_list")).source, "messages_*")
    }

    func testAToolNoRuleMatchesKeepsItsDefault() throws {
        let policy = try load(#"{"rules": {"mail_move": "confirm"}}"#)
        XCTAssertEqual(try rule(policy, "mail_move"), .confirm)
        XCTAssertEqual(try rule(policy, "mail_send"), .confirm)
        XCTAssertEqual(try rule(policy, "mail_mark"), .allow)
    }

    func testConfirmOnAReadMeansAllowAndDenyStillDenies() throws {
        let policy = try load(#"{"rules": {"*": "confirm", "notes_*": "deny"}}"#)
        XCTAssertEqual(try rule(policy, "mail_list"), .allow)
        XCTAssertEqual(try rule(policy, "mail_mark"), .confirm)
        XCTAssertEqual(try rule(policy, "notes_list"), .deny)
    }

    func testLimitFromFileOverridesDefaultAndReadsAreNeverLimited() throws {
        let policy = try load(#"{"limits": {"mail_send": {"max": 5, "per_seconds": 60}, "*": {"max": 100, "per_seconds": 10}}}"#)
        XCTAssertEqual(try policy.limit(for: safetyTool("mail_send")), .init(max: 5, perSeconds: 60))
        XCTAssertEqual(try policy.limit(for: safetyTool("mail_move")), .init(max: 100, perSeconds: 10))
        XCTAssertNil(try policy.limit(for: safetyTool("mail_list")))
    }

    // MARK: - Broken file

    func testAFileThatCannotBeUsedThrowsNamingTheFile() throws {
        let broken = [
            "{not json",
            #"{"rules": {"mail_send": "maybe"}}"#,
            #"{"rules": {"mail_sned": "deny"}}"#,
            #"{"rules": {"nosuchapp_*": "deny"}}"#,
            #"{"rule": {"mail_send": "deny"}}"#,
            #"{"limits": {"mail_send": {"max": 5, "per_seconds": 0}}}"#,
            #"["deny"]"#,
        ]
        for json in broken {
            XCTAssertThrowsError(try load(json), json) { error in
                guard case let SafetyError.invalidPolicy(path, _) = error else { return XCTFail("\(json): \(error)") }
                XCTAssertEqual(path, sandbox.policyPath)
                XCTAssertEqual(agentErrorCode(for: error), "invalid_policy")
                XCTAssertTrue(error.localizedDescription.contains(sandbox.policyPath))
            }
        }
    }

    // MARK: - policy show and doctor

    func testPolicyReportShowsTheEffectivePolicy() throws {
        var report = PolicyReport.make(path: sandbox.policyPath)
        XCTAssertEqual(report.source, "built-in")
        XCTAssertEqual(report.tools.count, MCPToolRegistry.tools.count)
        XCTAssertEqual(report.tools.first { $0.tool == "mail_send" }?.rule, "confirm")
        XCTAssertEqual(report.tools.first { $0.tool == "mail_send" }?.limit?.max, 10)

        try sandbox.writePolicy(#"{"rules": {"mail_*": "deny"}}"#)
        report = PolicyReport.make(path: sandbox.policyPath)
        XCTAssertEqual(report.source, "file")
        XCTAssertEqual(report.tools.first { $0.tool == "mail_list" }?.rule, "deny")
        XCTAssertEqual(report.tools.first { $0.tool == "mail_list" }?.source, "mail_*")
    }

    func testPolicyReportForABrokenFileDeniesEveryWrite() throws {
        try sandbox.writePolicy("{")
        let report = PolicyReport.make(path: sandbox.policyPath)
        XCTAssertEqual(report.source, "invalid")
        XCTAssertNotNil(report.error)
        for row in report.tools {
            XCTAssertEqual(row.rule, row.effect == "read" ? "allow" : "deny", row.tool)
        }
    }

    func testDoctorReportsABrokenPolicyFile() throws {
        XCTAssertEqual(checkPolicyFile(path: sandbox.policyPath).status, .ok)
        try sandbox.writePolicy(#"{"rules": {"*": "allow"}}"#)
        XCTAssertEqual(checkPolicyFile(path: sandbox.policyPath).status, .ok)
        try sandbox.writePolicy("{")
        let check = checkPolicyFile(path: sandbox.policyPath)
        XCTAssertEqual(check.status, .fail)
        XCTAssertTrue(check.detail.contains(sandbox.policyPath))
        XCTAssertNotNil(check.remediation)
    }
}
