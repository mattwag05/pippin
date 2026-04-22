import Foundation

// MARK: - IntentPlanner

/// Asks an `AIProvider` to plan a sequence of MCP tool calls from a natural
/// language intent. Does NOT execute the plan — that's `DoCommand`'s job.
/// Self-repairs once on parse failure by feeding the error + bad output
/// back to the model; hard cap at 2 attempts.
enum IntentPlanner {
    struct Plan: Codable, Equatable {
        let steps: [PlannedStep]
        let finalAnswer: String?

        enum CodingKeys: String, CodingKey {
            case steps
            case finalAnswer = "final_answer"
        }
    }

    struct PlannedStep: Codable, Equatable {
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
        let system = buildSystemPrompt(tools: tools, maxSteps: maxSteps)
        let user = "Intent: \(intent)\n\nRespond with only the JSON object."
        do {
            let raw = try provider.complete(prompt: user, system: system)
            return try parsePlan(raw)
        } catch let first as IntentPlannerError {
            // One self-repair round-trip — feed the error back to the model.
            let repairUser = """
            Your previous response could not be parsed: \(first.localizedDescription)

            Your previous response:
            \(first.rawOutput ?? "<empty>")

            Respond with ONLY the JSON object, no markdown fences or prose.
            """
            let raw = try provider.complete(prompt: repairUser, system: system)
            return try parsePlan(raw)
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

    var errorDescription: String? {
        switch self {
        case let .parseFailed(reason, _):
            return "Plan JSON could not be parsed: \(reason)"
        case let .unknownTool(name):
            return "Planner returned an unknown tool: '\(name)'."
        }
    }

    /// The model's raw output, if the planner still has it. Surfaces only
    /// in the self-repair path — do not include in user-facing error text.
    var rawOutput: String? {
        if case let .parseFailed(_, output) = self { return output }
        return nil
    }
}
