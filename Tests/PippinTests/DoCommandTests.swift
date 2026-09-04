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

    func testDoOutputsExposeDryRunAndExecutedFlags() throws {
        let dryData = try JSONEncoder().encode(
            DryRunResult(
                steps: [IntentPlanner.PlannedStep(tool: "status")],
                finalAnswer: "planning note",
                dryRun: true,
                executed: false
            )
        )
        let dryObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: dryData) as? [String: Any]
        )
        XCTAssertEqual(dryObject["dry_run"] as? Bool, true)
        XCTAssertEqual(dryObject["executed"] as? Bool, false)

        let realData = try JSONEncoder().encode(
            ExecutedResult(steps: [], finalAnswer: "planning note", dryRun: false, executed: false)
        )
        let realObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: realData) as? [String: Any]
        )
        XCTAssertEqual(realObject["dry_run"] as? Bool, false)
        XCTAssertEqual(realObject["executed"] as? Bool, false)
    }
}

private final class CallCounter: @unchecked Sendable {
    var count = 0
}
