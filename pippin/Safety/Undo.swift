import Foundation

/// Runs `pippin <argv>` and returns its stdout envelope. The dispatcher passes
/// its child runner; tests pass a fake app.
typealias ArgvRunner = @Sendable ([String]) async throws -> (text: String, isError: Bool)

/// What is saved, mode 0600 beside the log, so an action can be reversed. It
/// holds prior field values (a note body, a reminder's notes), which is why it
/// is a file of its own and not part of the log line.
struct UndoSidecar: Codable, Equatable {
    struct Verify: Codable, Equatable {
        /// Reads the target as it is now.
        let argv: [String]
        /// The fields the action set, and their hash right after it ran.
        let fields: [String]
        let sha256: String
    }

    /// The pippin argv that puts the prior values back.
    let inverse: [String]
    /// Nil when the inverse checks the target itself (`--expect-message-id`).
    let verify: Verify?
}

/// The inverse of each undoable tool. Everything else is labeled irreversible.
enum Undo {
    struct Unsupported: Error {
        let reason: String
        init(_ reason: String) {
            self.reason = reason
        }
    }

    struct Plan {
        /// Argv that reads the target before and after the action, or nil when
        /// the command's own result carries the prior state (Mail).
        var show: @Sendable (_ args: JSONValue) -> [String]? = { _ in nil }
        /// Keys of the `show` payload that this call changes.
        var fields: @Sendable (_ args: JSONValue) -> [String] = { _ in [] }
        let inverse: @Sendable (_ args: JSONValue, _ before: JSONValue?, _ result: JSONValue?) throws -> [String]
    }

    private static let agent = ["--format", "agent"]

    /// One edited argument: the `show` field that holds its value, the flag
    /// that sets it, and whether an empty value can be written back.
    private struct Field {
        let arg: String
        let key: String
        let flag: String
        var clearable = false
    }

    private static func setFields(_ fields: [Field], _ args: JSONValue) -> [Field] {
        fields.filter { args[$0.arg] != nil }
    }

    private static func restore(_ fields: [Field], args: JSONValue, before: JSONValue?, what: String) throws -> [String] {
        guard let before else { throw Unsupported("the \(what)'s prior state could not be read") }
        let set = setFields(fields, args)
        guard !set.isEmpty else { throw Unsupported("the call set no restorable field") }
        return try set.flatMap { field in
            switch before[field.key] {
            case let .string(text)? where !text.isEmpty: return ["\(field.flag)=\(text)"]
            case let .int(number)?: return ["\(field.flag)=\(number)"]
            case .null?, nil, .string?:
                guard field.clearable else {
                    throw Unsupported("the \(what) had no \(field.arg) before, and pippin cannot clear one")
                }
                // ArgumentParser reads `--flag=` as a missing value; an empty value needs its own token.
                return [field.flag, ""]
            default: throw Unsupported("the prior \(field.arg) is not a value pippin can write back")
            }
        }
    }

    private static let reminderFields = [
        Field(arg: "title", key: "title", flag: "--title"), Field(arg: "due", key: "dueDate", flag: "--due"),
        Field(arg: "priority", key: "priority", flag: "--priority"),
        Field(arg: "notes", key: "notes", flag: "--notes", clearable: true),
        Field(arg: "url", key: "url", flag: "--url"), Field(arg: "list", key: "listId", flag: "--list"),
    ]
    private static let eventFields = [
        Field(arg: "title", key: "title", flag: "--title"), Field(arg: "start", key: "startDate", flag: "--start"),
        Field(arg: "end", key: "endDate", flag: "--end"), Field(arg: "calendar", key: "calendarId", flag: "--calendar"),
        Field(arg: "location", key: "location", flag: "--location", clearable: true),
        Field(arg: "notes", key: "notes", flag: "--notes", clearable: true),
        Field(arg: "url", key: "url", flag: "--url"),
    ]
    private static let contactFields = [
        Field(arg: "first", key: "givenName", flag: "--first", clearable: true),
        Field(arg: "last", key: "familyName", flag: "--last", clearable: true),
        Field(arg: "organization", key: "organization", flag: "--organization", clearable: true),
        Field(arg: "jobTitle", key: "jobTitle", flag: "--job-title", clearable: true),
    ]
    /// `contacts edit` replaces every address with one, so only a contact that
    /// had exactly one can be put back.
    private static let contactLists = [
        Field(arg: "email", key: "emails", flag: "--email"), Field(arg: "phone", key: "phones", flag: "--phone"),
    ]
    // shortcut: the prior body travels in argv, so a very large note is not undoable; add a --body-file if that matters.
    static let maxNoteBodyBytes = 200_000

    /// The id the target reported for itself, so a prefix the caller passed
    /// cannot resolve to a different item later.
    private static func id(_ args: JSONValue, _ before: JSONValue?, key: String = "id") throws -> String {
        guard let id = before?["id"]?.stringValue ?? args[key]?.stringValue, !id.hasPrefix("-") else {
            throw Unsupported("the target has no usable id")
        }
        return id
    }

    static let plans: [String: Plan] = [
        "reminders_complete": Plan(
            show: { args in args["id"]?.stringValue.map { ["reminders", "show", $0] + agent } },
            fields: { _ in ["isCompleted"] },
            inverse: { args, before, _ in
                guard before?["isCompleted"]?.boolValue == false else {
                    throw Unsupported("the reminder was already completed, or its prior state could not be read")
                }
                return try ["reminders", "complete", id(args, before), "--incomplete"] + agent
            }
        ),
        "reminders_edit": Plan(
            show: { args in args["id"]?.stringValue.map { ["reminders", "show", $0] + agent } },
            fields: { args in setFields(reminderFields, args).map(\.key) },
            inverse: { args, before, _ in
                try ["reminders", "edit", id(args, before)]
                    + restore(reminderFields, args: args, before: before, what: "reminder") + agent
            }
        ),
        "calendar_edit": Plan(
            show: { args in args["id"]?.stringValue.map { ["calendar", "show", $0] + agent } },
            fields: { args in setFields(eventFields, args).map(\.key) },
            inverse: { args, before, _ in
                for key in ["span", "occurrence", "alert", "allDay", "noAllDay"] where args[key] != nil {
                    throw Unsupported("an edit that sets \(key) is not undoable")
                }
                guard before?["isRecurring"]?.boolValue != true else {
                    throw Unsupported("an edit to a recurring event is not undoable")
                }
                if before?["isAllDay"]?.boolValue == true, args["start"] != nil || args["end"] != nil {
                    throw Unsupported("the times of an all-day event are not restored exactly")
                }
                return try ["calendar", "edit", id(args, before)]
                    + restore(eventFields, args: args, before: before, what: "event") + agent
            }
        ),
        "contacts_edit": Plan(
            show: { args in args["identifier"]?.stringValue.map { ["contacts", "show", $0] + agent } },
            fields: { args in setFields(contactFields + contactLists, args).map(\.key) },
            inverse: { args, before, _ in
                var options = setFields(contactFields, args).isEmpty
                    ? [] : try restore(contactFields, args: args, before: before, what: "contact")
                for list in setFields(contactLists, args) {
                    guard let values = before?[list.key]?.arrayValue, values.count == 1,
                          let value = values[0]["value"]?.stringValue
                    else {
                        throw Unsupported("contacts edit replaces every \(list.arg) with one; the contact did not have exactly one before, so they cannot be put back")
                    }
                    options.append("\(list.flag)=\(value)")
                }
                guard !options.isEmpty else { throw Unsupported("the call set no restorable field") }
                return try ["contacts", "edit", id(args, before, key: "identifier")] + options + agent
            }
        ),
        "notes_edit": Plan(
            show: { args in args["id"]?.stringValue.map { ["notes", "show", "--html"] + agent + ["--", $0] } },
            fields: { args in (args["title"] != nil ? ["title"] : []) + (args["body"] != nil ? ["body"] : []) },
            inverse: { args, before, _ in
                guard let before else { throw Unsupported("the note's prior state could not be read") }
                var argv = ["notes", "edit"]
                if args["title"] != nil, let title = before["title"]?.stringValue { argv.append("--title=\(title)") }
                if args["body"] != nil {
                    guard let body = before["body"]?.stringValue else { throw Unsupported("the note's prior body could not be read") }
                    guard body.utf8.count <= maxNoteBodyBytes else {
                        throw Unsupported("the note's prior body is too large to restore through pippin")
                    }
                    argv += ["--body=\(body)", "--html"]
                }
                guard argv.count > 2 else { throw Unsupported("the call set no restorable field") }
                return try argv + agent + ["--", id(args, before)]
            }
        ),
        "mail_mark": Plan(inverse: { args, _, result in
            let details = result?["details"]
            guard let previous = details?["previousReadStatus"]?.stringValue,
                  let messageId = args["messageId"]?.stringValue, !messageId.hasPrefix("-")
            else { throw Unsupported("the message's prior read state was not reported") }
            guard previous != details?["readStatus"]?.stringValue else {
                throw Unsupported("the call changed nothing: the message already had that read state")
            }
            guard let rfc = details?["rfcMessageId"]?.stringValue, !rfc.isEmpty else {
                throw Unsupported("the message has no Message-ID to check its identity against")
            }
            return ["mail", "mark", messageId, previous == "true" ? "--read" : "--unread", "--expect-message-id=\(rfc)"] + agent
        }),
        "mail_move": Plan(inverse: { _, _, result in
            let details = result?["details"]
            guard let source = details?["messageId"]?.stringValue, let from = details?["from"]?.stringValue,
                  let destination = details?["toResolved"]?.stringValue,
                  let account = source.components(separatedBy: "||").first, !account.hasPrefix("-")
            else { throw Unsupported("the move did not report where the message went") }
            guard let rfc = details?["rfcMessageId"]?.stringValue, !rfc.isEmpty else {
                throw Unsupported("the message has no Message-ID to find it by in its new mailbox")
            }
            // Mail gives a moved message a new row id, so the inverse finds it by Message-ID.
            return [
                "mail", "move", "\(account)||\(destination)||0", "--to=\(from)",
                "--expect-message-id=\(rfc)", "--locate-by-message-id",
            ] + agent
        }),
    ]

    /// Why a tool with no plan cannot be undone.
    static func irreversibleReason(_ toolName: String) -> String {
        if SafetyPolicy.sendTools.contains(toolName) { return "a sent or drafted message cannot be recalled" }
        if toolName.hasSuffix("_delete") { return "pippin cannot restore a deleted item" }
        if toolName.hasSuffix("create") { return "undo of a create is not implemented; delete the new item instead" }
        if toolName == "undo" { return "an undo cannot itself be undone" }
        return "no inverse is defined for \(toolName)"
    }

    static func data(of run: (text: String, isError: Bool)?) -> JSONValue? {
        guard let run, !run.isError,
              let envelope = try? JSONDecoder().decode(JSONValue.self, from: Data(run.text.utf8))
        else { return nil }
        return envelope["data"]
    }

    static func hash(_ data: JSONValue, fields: [String]) -> String {
        ArgRedactor.sha256(ArgRedactor.canonicalJSON(.object(
            Dictionary(uniqueKeysWithValues: fields.map { ($0, data[$0] ?? .null) })
        )))
    }

    static func sidecarPath(id: String, stateDir: String) -> String {
        "\(stateDir)/undo/\(id).json"
    }

    /// Before the action: the target's current state, where the plan reads one.
    static func snapshot(tool: String, args: JSONValue, run: ArgvRunner) async -> JSONValue? {
        guard let argv = plans[tool]?.show(args) else { return nil }
        return await data(of: try? run(argv))
    }

    /// After a successful action: work out the inverse, hash what the action
    /// left behind, and save both. Never throws: an action that cannot be made
    /// undoable is still done, and says why.
    static func record(
        tool: String, args: JSONValue, before: JSONValue?, result: JSONValue?,
        id actionID: String, stateDir: String, run: ArgvRunner
    ) async -> UndoInfo {
        guard let plan = plans[tool] else { return .no(irreversibleReason(tool)) }
        do {
            let inverse = try plan.inverse(args, before, result)
            var verify: UndoSidecar.Verify?
            if var argv = plan.show(args) {
                // Re-read by the full id the target reported, not the caller's prefix.
                if let full = before?["id"]?.stringValue, let given = (args["id"] ?? args["identifier"])?.stringValue,
                   let index = argv.lastIndex(of: given) {
                    argv[index] = full
                }
                guard let after = await data(of: try? run(argv)) else {
                    return .no("the result could not be read back to verify a later undo against")
                }
                let fields = plan.fields(args)
                verify = .init(argv: argv, fields: fields, sha256: hash(after, fields: fields))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try PrivateFile.writeAtomically(
                encoder.encode(UndoSidecar(inverse: inverse, verify: verify)), to: sidecarPath(id: actionID, stateDir: stateDir)
            )
            return UndoInfo(supported: true, reason: nil, sidecar: "undo/\(actionID).json")
        } catch let unsupported as Unsupported {
            return .no(unsupported.reason)
        } catch {
            return .no("the undo record could not be saved: \(error.localizedDescription)")
        }
    }

    /// What `pippin undo` answers with.
    struct Outcome: Encodable {
        let undone: String
        let tool: String
        let result: JSONValue?
    }

    /// Reverse logged action `id`: check it is undoable and not yet undone,
    /// check the target still looks the way the action left it, run the
    /// inverse, and mark the action undone in the log.
    static func perform(id: String, stateDir: String = SafetyPaths.stateDir(), run: ArgvRunner) async throws -> Outcome {
        let log = ActionLog(path: stateDir + "/actions.jsonl")
        guard let entry = log.entries().first(where: { $0.id == id }) else { throw SafetyError.actionNotFound(id) }
        guard !entry.undone else { throw SafetyError.alreadyUndone(id) }
        guard entry.undo.supported else {
            throw SafetyError.undoNotSupported(id: id, reason: entry.undo.reason ?? "no undo record")
        }
        guard let data = FileManager.default.contents(atPath: sidecarPath(id: id, stateDir: stateDir)),
              let sidecar = try? JSONDecoder().decode(UndoSidecar.self, from: data)
        else { throw SafetyError.undoNotSupported(id: id, reason: "its undo record is missing or unreadable") }

        if let verify = sidecar.verify {
            guard let current = try await Self.data(of: run(verify.argv)),
                  hash(current, fields: verify.fields) == verify.sha256
            else { throw SafetyError.undoTargetChanged(id) }
        }
        let result = try await run(sidecar.inverse)
        guard !result.isError else {
            let error = (try? JSONDecoder().decode(JSONValue.self, from: Data(result.text.utf8)))?["error"]
            throw SafetyError.undoFailed(
                id: id, code: error?["code"]?.stringValue ?? "unknown_error",
                message: error?["message"]?.stringValue ?? "the inverse command failed"
            )
        }
        try log.append(ActionLogLine(ts: ISO8601DateFormatter().string(from: Date()), id: id, phase: "undone", tool: entry.tool))
        return Outcome(undone: id, tool: entry.tool, result: Self.data(of: result))
    }
}
