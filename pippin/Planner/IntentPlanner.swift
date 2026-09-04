import Foundation

// MARK: - IntentPlanner

/// Asks an `AIProvider` to plan a sequence of MCP tool calls from a natural
/// language intent. Does NOT execute the plan — that's `DoCommand`'s job.
/// Self-repairs once on parse failure by feeding the error + bad output
/// back to the model; hard cap at 2 attempts.
enum IntentPlanner {
    struct Plan: Codable, Equatable, Sendable {
        let steps: [PlannedStep]
        let finalAnswer: String?

        enum CodingKeys: String, CodingKey {
            case steps
            case finalAnswer = "final_answer"
        }
    }

    struct PlannedStep: Codable, Equatable, Sendable {
        let tool: String
        let args: JSONValue?

        init(tool: String, args: JSONValue? = nil) {
            self.tool = tool
            self.args = args
        }
    }

    /// Plan steps for `intent` over the given tool surface. Throws
    /// `IntentPlannerError` on parse failure after 2 attempts.
    static func plan(
        intent: String,
        tools: [MCPTool],
        provider: any AIProvider,
        maxSteps: Int = 5
    ) throws -> Plan {
        guard maxSteps > 0, maxSteps <= 20 else {
            throw IntentPlannerError.invalidPlan("Maximum plan length must be between 1 and 20.")
        }
        let system = buildSystemPrompt(tools: tools, maxSteps: maxSteps)
        let user = "Intent: \(intent)\n\nRespond with only the JSON object."
        let raw = try provider.complete(
            prompt: user,
            system: system,
            options: AICompletionOptions(jsonMode: true, temperature: 0)
        )
        do {
            let plan = try parsePlan(raw)
            try validate(plan: plan, tools: tools, maxSteps: maxSteps)
            return plan
        } catch let first as IntentPlannerError {
            // One self-repair round-trip. Keep the rejected JSON even when it
            // parsed successfully but failed semantic plan validation.
            let repairUser = """
            Original user intent:
            \(intent)

            Your previous response was invalid: \(first.localizedDescription)

            Your previous response:
            \(first.rawOutput ?? raw)

            Respond with ONLY the JSON object, no markdown fences or prose.
            """
            let raw = try provider.complete(
                prompt: repairUser,
                system: system,
                options: AICompletionOptions(jsonMode: true, temperature: 0)
            )
            let plan = try parsePlan(raw)
            try validate(plan: plan, tools: tools, maxSteps: maxSteps)
            return plan
        }
    }

    /// Validate every aspect of a plan before any tool can run.
    static func validate(plan: Plan, tools: [MCPTool], maxSteps: Int) throws {
        guard maxSteps > 0, maxSteps <= 20 else {
            throw IntentPlannerError.invalidPlan("Maximum plan length must be between 1 and 20.")
        }
        guard plan.steps.count <= maxSteps else {
            throw IntentPlannerError.invalidPlan(
                "Plan contains \(plan.steps.count) steps, but the limit is \(maxSteps)."
            )
        }
        if plan.steps.isEmpty {
            guard let answer = plan.finalAnswer,
                  !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw IntentPlannerError.invalidPlan(
                    "An empty plan requires a nonblank final_answer explanation."
                )
            }
        }
        for step in plan.steps {
            guard let tool = tools.first(where: { $0.name == step.tool }) else {
                throw IntentPlannerError.unknownTool(step.tool)
            }
            do {
                try SchemaValidator.validate(args: step.args, against: tool.inputSchema)
            } catch let error as SchemaValidatorError {
                throw IntentPlannerError.invalidPlan(
                    "Step for '\(step.tool)' failed schema validation: \(error.localizedDescription)"
                )
            }
        }
    }

    // MARK: - Prompt

    static func buildSystemPrompt(tools: [MCPTool], maxSteps: Int) -> String {
        // Explicit String return type — without it, Swift can infer GRDB's
        // SQL type via ExpressibleByStringInterpolation and the prompt
        // ends up containing `SQL(elements: [...])` garbage.
        let toolSection = tools.map { tool -> String in
            let schemaText = prettyPrintSchema(tool.inputSchema)
            return "- \(tool.name): \(tool.description)\n  Schema: \(schemaText)"
        }.joined(separator: "\n")

        return """
        You are a tool-using planner. Read the user's intent and plan the
        minimum sequence of tool calls that accomplishes it.

        Available tools:
        \(toolSection)

        Respond with ONLY a JSON object in this shape:
        {
          "steps": [
            {"tool": "<tool_name>", "args": {<arguments matching the tool's schema>}}
          ],
          "final_answer": "<short human-readable summary, optional>"
        }

        Rules:
        - Use at most \(maxSteps) steps.
        - Each step.tool must be one of the tools listed above.
        - Each step.args must match the tool's schema (required fields, types).
        - No markdown fences around the JSON. No commentary outside the JSON.
        - If the intent cannot be answered with the available tools, return
          an empty steps array and put the reason in final_answer.
        """
    }

    /// Compact one-line JSON schema for the system prompt — agents don't
    /// need pretty indentation, and smaller is cheaper.
    static func prettyPrintSchema(_ schema: JSONValue) -> String {
        guard
            let data = try? JSONEncoder().encode(schema),
            let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    // MARK: - Parsing

    /// Parse the model's response into a Plan. Strips markdown fences if the
    /// model ignored instructions and wrapped the JSON in ```json ... ```.
    static func parsePlan(_ raw: String) throws -> Plan {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = stripCodeFences(trimmed)
        guard let data = stripped.data(using: .utf8) else {
            throw IntentPlannerError.parseFailed(
                reason: "Could not encode response as UTF-8.", rawOutput: raw
            )
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IntentPlannerError.parseFailed(
                reason: "Plan must be a JSON object.", rawOutput: raw
            )
        }
        let allowedKeys: Set = ["steps", "final_answer"]
        guard Set(object.keys).isSubset(of: allowedKeys) else {
            throw IntentPlannerError.parseFailed(
                reason: "Plan contains unknown top-level fields.", rawOutput: raw
            )
        }
        guard object["steps"] is [Any] else {
            throw IntentPlannerError.parseFailed(
                reason: "Plan must contain a steps array.", rawOutput: raw
            )
        }
        if let steps = object["steps"] as? [[String: Any]] {
            let allowedStepKeys: Set = ["tool", "args"]
            for step in steps {
                guard Set(step.keys).isSubset(of: allowedStepKeys) else {
                    throw IntentPlannerError.parseFailed(
                        reason: "A plan step contains unknown fields.", rawOutput: raw
                    )
                }
            }
        } else if !(object["steps"] as? [Any] ?? []).isEmpty {
            throw IntentPlannerError.parseFailed(
                reason: "Each plan step must be an object.", rawOutput: raw
            )
        }
        if let finalAnswer = object["final_answer"], !(finalAnswer is String), !(finalAnswer is NSNull) {
            throw IntentPlannerError.parseFailed(
                reason: "final_answer must be a string when supplied.", rawOutput: raw
            )
        }
        do {
            return try JSONDecoder().decode(Plan.self, from: data)
        } catch {
            throw IntentPlannerError.parseFailed(
                reason: error.localizedDescription, rawOutput: raw
            )
        }
    }

    private static func stripCodeFences(_ text: String) -> String {
        var s = text
        if s.hasPrefix("```json") {
            s = String(s.dropFirst(7))
        } else if s.hasPrefix("```") {
            s = String(s.dropFirst(3))
        }
        if s.hasSuffix("```") {
            s = String(s.dropLast(3))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Errors

enum IntentPlannerError: LocalizedError {
    case parseFailed(reason: String, rawOutput: String?)
    case unknownTool(String)
    case invalidPlan(String)

    var errorDescription: String? {
        switch self {
        case let .parseFailed(reason, _):
            return "Plan JSON could not be parsed: \(reason)"
        case let .unknownTool(name):
            return "Planner returned an unknown tool: '\(name)'."
        case let .invalidPlan(reason):
            return "Planner returned an invalid plan: \(reason)"
        }
    }

    /// The model's raw output, if the planner still has it. Surfaces only
    /// in the self-repair path — do not include in user-facing error text.
    var rawOutput: String? {
        if case let .parseFailed(_, output) = self { return output }
        return nil
    }
}
