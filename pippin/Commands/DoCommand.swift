import ArgumentParser
import Foundation

// MARK: - DoCommand

/// `pippin do "<intent>"` — hand an LLM the MCP tool registry and let it
/// plan + execute the minimum sequence of tool calls. Single-turn: one
/// planning round (plus optional self-repair), then straight execution.
public struct DoCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "do",
        abstract: "Plan and execute pippin tool calls for a natural-language intent.",
        discussion: """
        Uses the MCP tool registry as its action surface. Each planned
        step runs as a `pippin <cmd> --format agent` subprocess; the
        result is merged back into the response.

        Example:
            pippin do "what's on my calendar today and any overdue reminders?"
            pippin do "list my icloud inbox" --dry-run
        """
    )

    @Argument(help: "Natural-language intent for the planner.")
    public var intent: String

    @Option(name: .long, help: "AI provider: ollama, claude, or openai (overrides config).")
    public var provider: String?

    @Option(name: .long, help: "Model name (overrides config).")
    public var model: String?

    @Option(name: .long, help: "Claude API key (overrides env / Vaultwarden).")
    public var apiKey: String?

    @Option(name: .long, help: "Maximum plan length (default: 5).")
    public var maxSteps: Int = 5

    @Flag(name: .long, help: "Plan only — do not execute steps. Prints the plan as .data.")
    public var dryRun: Bool = false

    @OptionGroup public var output: OutputOptions

    public init() {}

    public mutating func validate() throws {
        guard maxSteps > 0, maxSteps <= 20 else {
            throw ValidationError("--max-steps must be between 1 and 20.")
        }
        guard !intent.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ValidationError("intent must not be empty.")
        }
    }

    public mutating func run() async throws {
        let ai = try AIProviderFactory.make(
            providerFlag: provider, modelFlag: model, apiKeyFlag: apiKey
        )
        // IntentPlanner.plan calls provider.complete() synchronously (a blocking
        // network round-trip). Hop it off the cooperative pool like the execution
        // loop below already does for runChild (pippin-77t).
        let intent = self.intent
        let maxSteps = self.maxSteps
        let plan = try await detachBlocking {
            try IntentPlanner.plan(
                intent: intent, tools: MCPToolRegistry.tools, provider: ai, maxSteps: maxSteps
            )
        }

        if dryRun {
            // The executor validates even in dry-run mode, but its runner is
            // never called. This keeps the output useful without claiming work ran.
            _ = try await DoExecutor.execute(
                plan: plan,
                tools: MCPToolRegistry.tools,
                maxSteps: maxSteps,
                dryRun: true,
                runTool: { _, _ in .null }
            )
            let dry = DryRunResult(
                steps: plan.steps,
                finalAnswer: plan.finalAnswer,
                dryRun: true,
                executed: false
            )
            try emit(dry)
            return
        }

        let pippinPath = MCPServerRuntime.resolvePippinPath()
        let execution = try await DoExecutor.execute(
            plan: plan,
            tools: MCPToolRegistry.tools,
            maxSteps: maxSteps,
            dryRun: false,
            runTool: { tool, args in
                let argv: [String]
                do {
                    argv = try tool.buildArgs(args)
                } catch {
                    throw DoError.buildArgsFailed(tool: tool.name, underlying: error)
                }
                // runChild blocks on process.waitUntilExit(); hop off the cooperative pool.
                let child = try await detachBlocking {
                    try MCPServerRuntime.runChild(argv: argv, pippinPath: pippinPath)
                }
                return Self.decodeChildStdout(child.stdout)
            }
        )

        let result = ExecutedResult(
            steps: execution.executedSteps,
            finalAnswer: plan.finalAnswer,
            dryRun: false,
            executed: execution.executed
        )
        try emit(result)
    }

    private func emit(_ value: some Encodable) throws {
        if output.isAgent {
            try output.printAgent(value)
        } else if output.isJSON {
            try printJSON(value)
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            print(String(data: data, encoding: .utf8) ?? "")
        }
    }

    static func decodeChildStdout(_ stdout: Data) -> JSONValue {
        let trimmed = String(data: stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let value = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) {
            return value
        }
        return .object([
            "status": .string("error"),
            "error": .object([
                "code": .string("invalid_json"),
                "message": .string("Child stdout was not valid JSON: \(String(trimmed.prefix(200)))"),
            ]),
        ])
    }
}

// MARK: - Output shapes

struct DryRunResult: Encodable {
    let steps: [IntentPlanner.PlannedStep]
    let finalAnswer: String?
    let dryRun: Bool
    let executed: Bool

    enum CodingKeys: String, CodingKey {
        case steps
        case finalAnswer = "final_answer"
        case dryRun = "dry_run"
        case executed
    }
}

struct ExecutedStep: Encodable, Sendable {
    let tool: String
    let args: JSONValue?
    let result: JSONValue
}

struct ExecutedResult: Encodable {
    let steps: [ExecutedStep]
    let finalAnswer: String?
    let dryRun: Bool
    let executed: Bool

    enum CodingKeys: String, CodingKey {
        case steps
        case finalAnswer = "final_answer"
        case dryRun = "dry_run"
        case executed
    }
}

struct DoExecutionOutput: Sendable {
    let executedSteps: [ExecutedStep]
    let dryRun: Bool
    let executed: Bool
}

/// Injectable plan executor. Validation happens before the first runner call,
/// and dry-run mode deliberately skips the runner entirely.
enum DoExecutor {
    typealias ToolRunner = @Sendable (MCPTool, JSONValue?) async throws -> JSONValue

    static func execute(
        plan: IntentPlanner.Plan,
        tools: [MCPTool],
        maxSteps: Int,
        dryRun: Bool,
        runTool: @escaping ToolRunner
    ) async throws -> DoExecutionOutput {
        try IntentPlanner.validate(plan: plan, tools: tools, maxSteps: maxSteps)
        guard !dryRun else {
            return DoExecutionOutput(executedSteps: [], dryRun: true, executed: false)
        }

        var executedSteps: [ExecutedStep] = []
        for step in plan.steps {
            guard let tool = tools.first(where: { $0.name == step.tool }) else {
                throw IntentPlannerError.unknownTool(step.tool)
            }
            let payload = try await runTool(tool, step.args)
            executedSteps.append(ExecutedStep(tool: step.tool, args: step.args, result: payload))
        }
        return DoExecutionOutput(
            executedSteps: executedSteps,
            dryRun: false,
            executed: !executedSteps.isEmpty
        )
    }
}

// MARK: - Errors

public enum DoError: LocalizedError {
    case stepValidationFailed(tool: String, underlying: Error)
    case buildArgsFailed(tool: String, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case let .stepValidationFailed(tool, err):
            return "Planned step for '\(tool)' failed schema validation: \(err.localizedDescription)"
        case let .buildArgsFailed(tool, err):
            return "Could not build argv for '\(tool)': \(err.localizedDescription)"
        }
    }
}
