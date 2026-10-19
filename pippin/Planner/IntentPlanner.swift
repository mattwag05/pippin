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
        maxSteps: Int = 5,
        excludedData: Set<PersonalDataKind> = []
    ) throws -> Plan {
        guard maxSteps > 0, maxSteps <= 20 else {
            throw IntentPlannerError.invalidPlan("Maximum plan length must be between 1 and 20.")
        }
        let system = buildSystemPrompt(tools: tools, maxSteps: maxSteps, excludedData: excludedData)
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

    // MARK: - Data exclusions

    /// Ask the model which kinds of personal data the intent forbids.
    /// Planning models ignore a "do not touch X" rule when it is buried in a
    /// long tool list (pippin-jhb3), so the caller removes the matching tools
    /// before planning instead. One repair attempt; fails closed by throwing.
    static func extractExclusions(
        intent: String,
        provider: any AIProvider
    ) throws -> Set<PersonalDataKind> {
        let kinds = PersonalDataKind.allCases.map(\.rawValue).joined(separator: ", ")
        let system = """
        You read a user's request and list the kinds of personal data the user
        explicitly says must NOT be accessed. The kinds are: \(kinds).
        Map synonyms: email to mail; texts, SMS or iMessage to messages; events
        or schedule to calendar; to-dos to reminders; voice memos or recordings
        to memos; address book to contacts. "Do not access any personal data"
        means every kind. Asking to read or change data is not an exclusion.

        Respond with ONLY a JSON object: {"excluded": ["<kind>", ...]}
        Use an empty array when nothing is excluded.
        """
        let user = "Request: \(intent)\n\nRespond with only the JSON object."
        let options = AICompletionOptions(jsonMode: true, temperature: 0)
        let raw = try provider.complete(prompt: user, system: system, options: options)
        do {
            return try parseExclusions(raw)
        } catch let first as IntentPlannerError {
            let repairUser = """
            Original request:
            \(intent)

            Your previous response was invalid: \(first.localizedDescription)

            Your previous response:
            \(raw)

            Respond with ONLY the JSON object, no markdown fences or prose.
            """
            let raw = try provider.complete(prompt: repairUser, system: system, options: options)
            return try parseExclusions(raw)
        }
    }

    static func parseExclusions(_ raw: String) throws -> Set<PersonalDataKind> {
        let stripped = stripCodeFences(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let object = try? JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [String: Any],
              Set(object.keys) == ["excluded"],
              let names = object["excluded"] as? [String]
        else {
            throw IntentPlannerError.parseFailed(
                reason: "Exclusions must be a JSON object with only an excluded string array.",
                rawOutput: raw
            )
        }
        var kinds: Set<PersonalDataKind> = []
        for name in names {
            guard let kind = PersonalDataKind(rawValue: name.lowercased()) else {
                throw IntentPlannerError.parseFailed(
                    reason: "Unknown data kind '\(name)'.", rawOutput: raw
                )
            }
            kinds.insert(kind)
        }
        return kinds
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

    static func buildSystemPrompt(
        tools: [MCPTool],
        maxSteps: Int,
        excludedData: Set<PersonalDataKind> = []
    ) -> String {
        // Explicit String return type — without it, Swift can infer GRDB's
        // SQL type via ExpressibleByStringInterpolation and the prompt
        // ends up containing `SQL(elements: [...])` garbage.
        let toolSection = tools.map { tool -> String in
            let schemaText = prettyPrintSchema(tool.inputSchema)
            return """
            - \(tool.name): \(tool.description)
              Accesses: \(accessText(for: tool.name))
              Schema: \(schemaText)
            """
        }.joined(separator: "\n")
        let exclusionNote = excludedData.isEmpty ? "" : """

        The user excluded these kinds of data: \(excludedData.sorted().map(\.rawValue).joined(separator: ", ")).
        These tools exist but were withheld because they access excluded data:
        \(withheldToolSummary(excluding: excludedData)).
        If the intent needs a withheld tool, return an empty steps array and
        say in final_answer which withheld tool would do it and that the
        exclusion prevents it.
        """

        return """
        You are a tool-using planner. Read the user's intent and plan the
        minimum sequence of tool calls that accomplishes it.

        Available tools:
        \(toolSection)
        \(exclusionNote)

        Respond with ONLY a JSON object in this shape:
        {
          "steps": [
            {"tool": "<tool_name>", "args": {<arguments matching the tool's schema>}}
          ],
          "final_answer": "<what the steps will do, or why no step fits>"
        }

        Rules:
        - Use at most \(maxSteps) steps.
        - Each step.tool must be one of the tools listed above.
        - Each step.args must match the tool's schema (required fields, types).
        - No markdown fences around the JSON. No commentary outside the JSON.
        - Each tool lists the personal data it accesses. If the intent says not
          to access some kind of data, never choose a tool that accesses it,
          even to answer part of the intent.
        - Do not substitute a different action for one the tools cannot do.
        - If no allowed tool can accomplish the intent, return an empty steps
          array and explain why in final_answer.
        - Nothing has run when you write the plan. Write final_answer in the
          future tense ("Will run doctor to check permissions."), and never
          claim that anything was checked, found, or done.
        """
    }

    /// "every mail_* and notes_* tool, plus doctor, status" for the registry
    /// tools that `ToolDataAccess.allowedTools` drops.
    private static func withheldToolSummary(excluding excluded: Set<PersonalDataKind>) -> String {
        let allowed = Set(ToolDataAccess.allowedTools(MCPToolRegistry.tools, excluding: excluded).map(\.name))
        let withheld = MCPToolRegistry.tools.map(\.name).filter { !allowed.contains($0) }
        // A family is summarized only when none of its tools survived.
        let families = PersonalDataKind.allCases.map(\.rawValue).filter { kind in
            withheld.contains { $0.hasPrefix(kind + "_") } && !allowed.contains { $0.hasPrefix(kind + "_") }
        }
        let others = withheld.filter { name in !families.contains { name.hasPrefix($0 + "_") } }
        var parts: [String] = []
        if !families.isEmpty {
            parts.append("every " + families.map { "\($0)_*" }.joined(separator: " and ") + " tool")
        }
        if !others.isEmpty { parts.append(others.joined(separator: ", ")) }
        return parts.joined(separator: ", plus ")
    }

    private static func accessText(for toolName: String) -> String {
        guard let kinds = ToolDataAccess.kinds(for: toolName) else {
            return "unknown, treat as any personal data"
        }
        if kinds.isEmpty { return "no personal app data" }
        return kinds.sorted().map(\.rawValue).joined(separator: ", ")
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
