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

    @Option(name: .long, help: "AI provider: ollama or claude (overrides config).")
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
        let tools = MCPToolRegistry.tools
        let plan = try IntentPlanner.plan(
            intent: intent, tools: tools, provider: ai, maxSteps: maxSteps
        )

        // Validate each step before executing anything so a bad plan fails
        // cleanly instead of running the first N-1 steps.
        for step in plan.steps {
            guard let tool = MCPToolRegistry.tool(named: step.tool) else {
                throw IntentPlannerError.unknownTool(step.tool)
            }
            do {
                try SchemaValidator.validate(args: step.args, against: tool.inputSchema)
            } catch let error as SchemaValidatorError {
                throw DoError.stepValidationFailed(tool: step.tool, underlying: error)
            }
        }

        if dryRun {
            let dry = DryRunResult(steps: plan.steps, finalAnswer: plan.finalAnswer)
            try emit(dry)
            return
        }

        let pippinPath = MCPServerRuntime.resolvePippinPath()
        var executed: [ExecutedStep] = []
        for step in plan.steps {
            let tool = MCPToolRegistry.tool(named: step.tool)! // validated above
            let argv: [String]
            do {
                argv = try tool.buildArgs(step.args)
            } catch {
                throw DoError.buildArgsFailed(tool: step.tool, underlying: error)
            }
            let child = try MCPServerRuntime.runChild(argv: argv, pippinPath: pippinPath)
            let payload = Self.decodeChildStdout(child.stdout)
            executed.append(ExecutedStep(tool: step.tool, args: step.args, result: payload))
        }

        let result = ExecutedResult(steps: executed, finalAnswer: plan.finalAnswer)
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

    enum CodingKeys: String, CodingKey {
        case steps
        case finalAnswer = "final_answer"
    }
}

struct ExecutedStep: Encodable {
    let tool: String
    let args: JSONValue?
    let result: JSONValue

    enum CodingKeys: String, CodingKey {
        case tool, args, result
    }
}

struct ExecutedResult: Encodable {
    let steps: [ExecutedStep]
    let finalAnswer: String?

    enum CodingKeys: String, CodingKey {
        case steps
        case finalAnswer = "final_answer"
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
