@testable import PippinLib
import XCTest

/// Stub AIProvider that queues responses — each `complete` call pops the
/// next queued answer, enabling tests of the self-repair retry path.
final class ScriptedAIProvider: AIProvider, @unchecked Sendable {
    private var responses: [String]
    private(set) var calls: [(prompt: String, system: String)] = []

    init(_ responses: [String]) {
        self.responses = responses
    }

    func complete(prompt: String, system: String) throws -> String {
        calls.append((prompt, system))
        guard !responses.isEmpty else {
            throw AIProviderError.networkError("ScriptedAIProvider exhausted")
        }
        return responses.removeFirst()
    }
}

final class IntentPlannerTests: XCTestCase {
    // MARK: - Happy path

    func testPlansFromStubbedResponse() throws {
        let json = """
        {"steps":[{"tool":"calendar_today","args":{}}],"final_answer":"today's events"}
        """
        let provider = ScriptedAIProvider([json])
        let plan = try IntentPlanner.plan(
            intent: "what's on my calendar today",
            tools: MCPToolRegistry.tools,
            provider: provider,
            maxSteps: 5
        )
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.steps.first?.tool, "calendar_today")
        XCTAssertEqual(plan.finalAnswer, "today's events")
        XCTAssertEqual(provider.calls.count, 1)
    }

    func testHandlesEmptySteps() throws {
        let json = """
        {"steps":[],"final_answer":"no tools match"}
        """
        let provider = ScriptedAIProvider([json])
        let plan = try IntentPlanner.plan(
            intent: "summon a dragon",
            tools: MCPToolRegistry.tools,
            provider: provider
        )
        XCTAssertEqual(plan.steps.count, 0)
        XCTAssertEqual(plan.finalAnswer, "no tools match")
    }

    func testFinalAnswerOptional() throws {
        let json = """
        {"steps":[{"tool":"reminders_lists","args":null}]}
        """
        let provider = ScriptedAIProvider([json])
        let plan = try IntentPlanner.plan(
            intent: "list reminder lists",
            tools: MCPToolRegistry.tools,
            provider: provider
        )
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertNil(plan.finalAnswer)
    }

    // MARK: - Self-repair

    func testMarkdownFencesStripped() throws {
        let json = """
        ```json
        {"steps":[{"tool":"status","args":{}}]}
        ```
        """
        let provider = ScriptedAIProvider([json])
        let plan = try IntentPlanner.plan(
            intent: "status",
            tools: MCPToolRegistry.tools,
            provider: provider
        )
        XCTAssertEqual(plan.steps.first?.tool, "status")
        XCTAssertEqual(provider.calls.count, 1, "markdown fences should not trigger self-repair")
    }

    func testSelfRepairOnMalformedFirstResponse() throws {
        let bad = "not JSON at all"
        let good = """
        {"steps":[{"tool":"status"}]}
        """
        let provider = ScriptedAIProvider([bad, good])
        let plan = try IntentPlanner.plan(
            intent: "status",
            tools: MCPToolRegistry.tools,
            provider: provider
        )
        XCTAssertEqual(provider.calls.count, 2, "planner should have retried once")
        XCTAssertEqual(plan.steps.first?.tool, "status")
        // Repair prompt includes the bad output so the model has context.
        XCTAssertTrue(provider.calls[1].prompt.contains("not JSON at all"))
    }

    func testSelfRepairCappedAtTwoAttempts() {
        let provider = ScriptedAIProvider(["garbage", "still garbage"])
        XCTAssertThrowsError(try IntentPlanner.plan(
            intent: "x",
            tools: MCPToolRegistry.tools,
            provider: provider
        )) { error in
            guard case IntentPlannerError.parseFailed = error else {
                return XCTFail("expected parseFailed, got \(error)")
            }
        }
        XCTAssertEqual(provider.calls.count, 2, "should not attempt a third time")
    }

    // MARK: - Prompt shape

    func testSystemPromptListsAllTools() {
        let prompt = IntentPlanner.buildSystemPrompt(
            tools: MCPToolRegistry.tools, maxSteps: 5
        )
        XCTAssertTrue(prompt.contains("calendar_today"))
        XCTAssertTrue(prompt.contains("mail_list"))
        XCTAssertTrue(prompt.contains("job_run"))
        XCTAssertTrue(prompt.contains("batch"))
        XCTAssertTrue(prompt.contains("at most 5 steps"))
    }

    func testSystemPromptIncludesSchemaForEachTool() throws {
        let tools = try [
            XCTUnwrap(MCPToolRegistry.tool(named: "mail_search")),
            XCTUnwrap(MCPToolRegistry.tool(named: "calendar_today")),
        ]
        let prompt = IntentPlanner.buildSystemPrompt(tools: tools, maxSteps: 3)
        XCTAssertTrue(prompt.contains("\"required\""))
        XCTAssertTrue(prompt.contains("\"query\""))
    }

    // MARK: - Parse error shape

    func testParseErrorCarriesRawOutput() {
        XCTAssertThrowsError(try IntentPlanner.parsePlan("not json")) { error in
            guard let parsed = error as? IntentPlannerError else { return XCTFail() }
            XCTAssertEqual(parsed.rawOutput, "not json")
        }
    }
}
