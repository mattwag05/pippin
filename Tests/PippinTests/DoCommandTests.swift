@testable import PippinLib
import XCTest

final class DoCommandTests: XCTestCase {
    // MARK: - Parse validation

    func testEmptyIntentFails() {
        XCTAssertThrowsError(try DoCommand.parse([""]))
    }

    func testMaxStepsZeroFails() {
        XCTAssertThrowsError(try DoCommand.parse(["hi", "--max-steps", "0"]))
    }

    func testMaxStepsOverTwentyFails() {
        XCTAssertThrowsError(try DoCommand.parse(["hi", "--max-steps", "21"]))
    }

    func testDryRunFlag() throws {
        let cmd = try DoCommand.parse(["check my mail", "--dry-run"])
        XCTAssertTrue(cmd.dryRun)
    }

    func testAcceptsProviderAndModel() throws {
        let cmd = try DoCommand.parse([
            "do stuff", "--provider", "claude", "--model", "claude-sonnet-4-6",
        ])
        XCTAssertEqual(cmd.provider, "claude")
        XCTAssertEqual(cmd.model, "claude-sonnet-4-6")
    }

    func testDefaultsMaxStepsToFive() throws {
        let cmd = try DoCommand.parse(["do stuff"])
        XCTAssertEqual(cmd.maxSteps, 5)
    }

    // MARK: - Child output decoding

    func testDecodeChildStdoutParsesEnvelope() {
        let envelope = """
        {"v":1,"status":"ok","duration_ms":5,"data":{"foo":1}}
        """
        let result = DoCommand.decodeChildStdout(Data(envelope.utf8))
        if case let .object(dict) = result {
            XCTAssertEqual(dict["status"]?.stringValue, "ok")
        } else {
            XCTFail("expected object, got \(result)")
        }
    }

    func testDecodeChildStdoutHandlesGarbage() {
        let result = DoCommand.decodeChildStdout(Data("not json".utf8))
        if case let .object(dict) = result,
           case let .object(errDict) = dict["error"] {
            XCTAssertEqual(errDict["code"]?.stringValue, "invalid_json")
        } else {
            XCTFail("expected invalid_json error, got \(result)")
        }
    }

    func testInvalidPlanExecutesZeroToolsThroughExecutorSeam() async {
        let plan = IntentPlanner.Plan(
            steps: [IntentPlanner.PlannedStep(tool: "not_a_tool", args: nil)], finalAnswer: nil
        )
        let counter = CallCounter()
        do {
            _ = try await DoExecutor.execute(
                plan: plan, tools: MCPToolRegistry.tools, maxSteps: 5, dryRun: false,
                runTool: { _, _ in counter.count += 1; return .null }
            )
            XCTFail("invalid plan should throw")
        } catch {
            XCTAssertEqual(counter.count, 0)
        }
    }

    func testUnexpectedArgumentExecutesZeroToolsThroughExecutorSeam() async {
        let plan = IntentPlanner.Plan(
            steps: [
                IntentPlanner.PlannedStep(
                    tool: "doctor", args: .object(["unexpected": .bool(true)])
                ),
            ],
            finalAnswer: nil
        )
        let counter = CallCounter()
        do {
            _ = try await DoExecutor.execute(
                plan: plan, tools: MCPToolRegistry.tools, maxSteps: 5, dryRun: false,
                runTool: { _, _ in counter.count += 1; return .null }
            )
            XCTFail("plan with an undeclared argument should throw")
        } catch {
            XCTAssertEqual(counter.count, 0)
        }
    }

    func testDryRunExecutesZeroToolsThroughExecutorSeam() async throws {
        let plan = IntentPlanner.Plan(
            steps: [IntentPlanner.PlannedStep(tool: "status", args: nil)], finalAnswer: "note"
        )
        let counter = CallCounter()
        let output = try await DoExecutor.execute(
            plan: plan, tools: MCPToolRegistry.tools, maxSteps: 5, dryRun: true,
            runTool: { _, _ in counter.count += 1; return .null }
        )
        XCTAssertTrue(output.dryRun)
        XCTAssertFalse(output.executed)
        XCTAssertEqual(output.executedSteps.count, 0)
        XCTAssertEqual(counter.count, 0)
    }

    func testExecutionOutputMarksExecutedOnlyAfterToolRuns() async throws {
        let plan = IntentPlanner.Plan(
            steps: [IntentPlanner.PlannedStep(tool: "status", args: nil)], finalAnswer: "note"
        )
        let output = try await DoExecutor.execute(
            plan: plan, tools: MCPToolRegistry.tools, maxSteps: 5, dryRun: false,
            runTool: { _, _ in .string("ok") }
        )
        XCTAssertFalse(output.dryRun)
        XCTAssertTrue(output.executed)
        XCTAssertEqual(output.executedSteps.first?.tool, "status")
    }

    // MARK: - Partial results (RC-11)

    private func threeStepPlan() -> IntentPlanner.Plan {
        IntentPlanner.Plan(
            steps: ["status", "reminders_lists", "calendar_list"].map { IntentPlanner.PlannedStep(tool: $0, args: nil) },
            finalAnswer: nil
        )
    }

    func testThrowingStepKeepsEarlierStepsAndStops() async throws {
        let counter = CallCounter()
        let output = try await DoExecutor.execute(
            plan: threeStepPlan(), tools: MCPToolRegistry.tools, maxSteps: 5, dryRun: false,
            runTool: { tool, _ in
                counter.count += 1
                if tool.name == "reminders_lists" { throw MailBridgeError.timeout }
                return .object(["status": .string("ok"), "data": .string(tool.name)])
            }
        )
        XCTAssertEqual(counter.count, 2, "the step after the failure must not run")
        XCTAssertEqual(output.executedSteps.map(\.tool), ["status", "reminders_lists"])
        XCTAssertEqual(output.executedSteps[0].result, .object(["status": .string("ok"), "data": .string("status")]))
        XCTAssertEqual(output.failure?.step, 1)
        XCTAssertEqual(output.failure?.tool, "reminders_lists")
        XCTAssertEqual(output.failure?.code, "timeout")
        XCTAssertNotNil(DoExecutor.stepError(output.executedSteps[1].result))
    }

    func testErrorEnvelopeStepStopsTheRun() async throws {
        let counter = CallCounter()
        let output = try await DoExecutor.execute(
            plan: threeStepPlan(), tools: MCPToolRegistry.tools, maxSteps: 5, dryRun: false,
            runTool: { _, _ in
                counter.count += 1
                return DoExecutor.errorEnvelope(code: "access_denied", message: "no")
            }
        )
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(output.failure, StepFailure(step: 0, tool: "status", code: "access_denied", message: "no"))
    }

    func testSuccessfulRunHasNoFailure() async throws {
        let output = try await DoExecutor.execute(
            plan: threeStepPlan(), tools: MCPToolRegistry.tools, maxSteps: 5, dryRun: false,
            runTool: { _, _ in .object(["status": .string("ok")]) }
        )
        XCTAssertEqual(output.executedSteps.count, 3)
        XCTAssertNil(output.failure)
        let data = try JSONEncoder().encode(ExecutedResult(
            steps: output.executedSteps, finalAnswer: nil, excludedData: [], dryRun: false, executed: true
        ))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("failure"), "omitted when nothing failed")
    }

    func testDoOutputsExposeDryRunAndExecutedFlags() throws {
        let dryData = try JSONEncoder().encode(
            DryRunResult(
                steps: [IntentPlanner.PlannedStep(tool: "status")],
                finalAnswer: "planning note",
                excludedData: ["mail"],
                dryRun: true,
                executed: false
            )
        )
        let dryObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: dryData) as? [String: Any]
        )
        XCTAssertEqual(dryObject["dry_run"] as? Bool, true)
        XCTAssertEqual(dryObject["executed"] as? Bool, false)
        XCTAssertEqual(dryObject["excluded_data"] as? [String], ["mail"])

        let realData = try JSONEncoder().encode(
            ExecutedResult(
                steps: [], finalAnswer: "planning note", excludedData: [], dryRun: false, executed: false
            )
        )
        let realObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: realData) as? [String: Any]
        )
        XCTAssertEqual(realObject["dry_run"] as? Bool, false)
        XCTAssertEqual(realObject["executed"] as? Bool, false)
    }

    // MARK: - Data exclusions (pippin-jhb3)

    func testExecutorRejectsExcludedToolBeforeRunningAnything() async {
        let counter = CallCounter()
        let allowed = ToolDataAccess.allowedTools(MCPToolRegistry.tools, excluding: [.mail])
        let plan = IntentPlanner.Plan(
            steps: [
                IntentPlanner.PlannedStep(tool: "reminders_lists", args: nil),
                IntentPlanner.PlannedStep(tool: "doctor", args: nil),
            ],
            finalAnswer: "Will check."
        )
        do {
            _ = try await DoExecutor.execute(
                plan: plan, tools: allowed, maxSteps: 5, dryRun: false,
                runTool: { _, _ in counter.count += 1; return .null }
            )
            XCTFail("expected the excluded doctor step to be rejected")
        } catch IntentPlannerError.unknownTool("doctor") {
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(counter.count, 0)
    }

    func testParseExcludeDataAcceptsKnownKinds() throws {
        XCTAssertEqual(try DoCommand.parseExcludeData(nil), [])
        XCTAssertEqual(try DoCommand.parseExcludeData(" Mail, notes "), [.mail, .notes])
        XCTAssertThrowsError(try DoCommand.parseExcludeData("mail,photos"))
    }

    func testDoParsesExcludeDataFlag() throws {
        let cmd = try DoCommand.parse(["check status", "--exclude-data", "mail,calendar"])
        XCTAssertEqual(cmd.excludeData, "mail,calendar")
        XCTAssertThrowsError(try DoCommand.parse(["check status", "--exclude-data", "photos"]))
    }
}

private final class CallCounter: @unchecked Sendable {
    var count = 0
}
