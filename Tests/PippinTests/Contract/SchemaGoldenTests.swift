import Foundation
@testable import PippinLib
import XCTest

/// Generates `docs/schemas/v<N>/` from the registry and the payload models and
/// fails when the checked-in files differ. Regenerate after an intended change:
/// `PIPPIN_UPDATE_SCHEMAS=1 make test`.
final class SchemaGoldenTests: XCTestCase {
    // MARK: - Output payloads

    /// What each tool puts under `data`, as samples from the real encoder: one
    /// with every optional field set and one with none.
    static var outputs: [String: () throws -> [JSONValue]] { [
        "mail_accounts": rows(MailAccount.self),
        "mail_mailboxes": rows(Mailbox.self),
        "mail_list": rows(MailMessage.self),
        "mail_search": rows(MailMessage.self),
        "mail_activity": rows(MailMessage.self),
        "mail_triage": object(TriageResult.self),
        "mail_sanitize": object(ScanResult.self),
        "mail_extract": object(ExtractionResult.self),
        "mail_verify": object(MailCommand.Verify.VerifyReport.self),
        "mail_attachments": rows(Attachment.self),
        "mail_send": object(BridgeActionResult.self),
        "mail_reply": object(BridgeActionResult.self),
        "mail_forward": object(BridgeActionResult.self),
        "mail_apply_rules": object(RuleApplyResult.self),
        "mail_mark": object(BridgeActionResult.self),
        "mail_move": object(BridgeActionResult.self),
        "calendar_list": rows(CalendarInfo.self),
        "calendar_events": rows(CalendarEvent.self),
        "calendar_today": rows(CalendarEvent.self),
        "calendar_remaining": rows(CalendarEvent.self),
        "calendar_upcoming": rows(CalendarEvent.self),
        "calendar_search": rows(CalendarEvent.self),
        "calendar_show": object(CalendarEvent.self),
        "calendar_conflicts": rows(CalendarConflict.self),
        "calendar_create": object(BridgeActionResult.self),
        "calendar_edit": object(BridgeActionResult.self),
        "calendar_delete": object(BridgeActionResult.self),
        "reminders_lists": rows(ReminderList.self),
        "reminders_list": rows(ReminderItem.self),
        "reminders_search": rows(ReminderItem.self),
        "reminders_show": object(ReminderItem.self),
        "reminders_create": object(BridgeActionResult.self),
        "reminders_edit": object(BridgeActionResult.self),
        "reminders_complete": object(BridgeActionResult.self),
        "reminders_delete": object(BridgeActionResult.self),
        "contacts_search": rows(ContactInfo.self),
        "contacts_list": rows(ContactInfo.self),
        "contacts_show": object(ContactInfo.self),
        "contacts_groups": rows(ContactGroup.self),
        "contacts_create": object(BridgeActionResult.self),
        "contacts_edit": object(BridgeActionResult.self),
        "contacts_delete": object(BridgeActionResult.self),
        "notes_list": rows(NoteInfo.self),
        "notes_search": rows(NoteInfo.self),
        "notes_show": { try [encoded(NoteAgentView(note: Filler.make(NoteInfo.self, full: true)))] },
        "notes_folders": rows(NoteFolder.self),
        "notes_create": object(BridgeActionResult.self),
        "notes_edit": object(NoteEditResult.self),
        "notes_delete": object(BridgeActionResult.self),
        "messages_list": rows(MessageConversation.self),
        "messages_search": object(MessagesSearchResult.self),
        "messages_show": object(MessagesShowResult.self),
        "messages_send": object(MessagesSendResult.self),
        "messages_exclude_list": object(MessagesExcludeResult.self),
        "messages_exclude_add": object(MessagesExcludeResult.self),
        "messages_exclude_remove": object(MessagesExcludeResult.self),
        "memos_list": rows(VoiceMemo.self),
        "memos_info": object(VoiceMemo.self),
        "memos_export": rows(ExportResult.self),
        "memos_transcribe": rows(TranscribeResult.self),
        "memos_capture_to_reminders": object(MemosCaptureResult.self),
        "memos_delete": object(BridgeActionResult.self),
        "digest": object(DigestPayload.self),
        "status": object(StatusReport.self),
        "doctor": rows(DiagnosticCheck.self),
        "job_list": rows(Job.self),
        "job_run": object(Job.self),
        "job_wait": object(Job.self),
        "job_show": {
            try [true, false].map { full in
                try encoded(JobView(job: Filler.make(Job.self, full: full), stdoutTail: "text", stderrTail: "text"))
            }
        },
    ] }

    /// Tools with no output schema, and why. Every tool is in exactly one of
    /// `outputs` and this table (`testEveryToolHasAnOutputSchemaOrAReason`).
    static let noOutputSchema: [String: String] = [
        "mail_show": "One message object, an array of them for messageIds, or {message, summary|scan}; no single model.",
        "calendar_smart_create": "Dry run returns the parsed spec and conflicts, a real run an action result.",
        "calendar_agenda": "A string dictionary built inline, with no Codable model.",
        "reminders_smart_create": "Dry run returns the parsed spec, a real run an action result.",
        "memos_summarize": "One result or an array of them depending on --all.",
        "actions_extract": "Extracted actions, or created reminders with create=true.",
        "batch": "An array of envelopes, each validated by envelope.schema.json.",
    ]

    static func encoded(_ value: some Encodable) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: agentPayloadEncoder().encode(value))
    }

    static func object<T: Codable>(_ type: T.Type) -> () throws -> [JSONValue] {
        { try [true, false].map { try encoded(Filler.make(type, full: $0)) } }
    }

    static func rows<T: Codable>(_ type: T.Type) -> () throws -> [JSONValue] {
        { try [true, false].map { try encoded([Filler.make(type, full: $0)]) } }
    }

    /// The schema for a tool's `data`. Rows of a tool that takes `fields` carry
    /// no `required`: the default projection and `fields` may drop any key.
    static func outputSchema(for tool: MCPTool, samples: [JSONValue]) -> JSONValue {
        guard case var .object(schema) = JSONSchema.infer(samples) else { return .object([:]) }
        if tool.inputSchema["properties"]?["fields"] != nil, case var .object(items)? = schema["items"] {
            items["required"] = nil
            schema["items"] = .object(items)
        }
        schema["$schema"] = .string(SchemaFiles.dialect)
        schema["title"] = .string("\(tool.name): data")
        return .object(schema)
    }

    // MARK: - Tests

    func testEveryToolHasAnOutputSchemaOrAReason() {
        let names = Set(MCPToolRegistry.tools.map(\.name))
        for name in names.sorted() {
            XCTAssertNotEqual(
                Self.outputs[name] == nil, Self.noOutputSchema[name] == nil,
                "\(name) must be in exactly one of outputs and noOutputSchema"
            )
        }
        for name in Set(Self.outputs.keys).union(Self.noOutputSchema.keys) where !names.contains(name) {
            XCTFail("\(name) is not a registered tool")
        }
        for tool in MCPToolRegistry.tools where tool.effect == .readOnly {
            guard let reason = Self.noOutputSchema[tool.name] else { continue }
            XCTAssertFalse(reason.isEmpty, "\(tool.name): a read tool without an output schema needs a reason")
        }
    }

    func testInputSchemasMatchRegistry() throws {
        for tool in MCPToolRegistry.tools {
            guard case var .object(schema) = tool.inputSchema else { return XCTFail("\(tool.name): schema is not an object") }
            schema["$schema"] = .string(SchemaFiles.dialect)
            schema["title"] = .string("\(tool.name): arguments")
            schema["description"] = .string(tool.description)
            try SchemaFiles.assertGolden("tools/\(tool.name).input.schema.json", .object(schema))
        }
    }

    func testOutputSchemasMatchModels() throws {
        for tool in MCPToolRegistry.tools {
            guard let make = Self.outputs[tool.name] else { continue }
            do {
                try SchemaFiles.assertGolden(
                    "tools/\(tool.name).output.schema.json", Self.outputSchema(for: tool, samples: make())
                )
            } catch {
                XCTFail("\(tool.name): cannot build a sample payload: \(error)")
            }
        }
    }

    /// The checked-in schema, read back from disk, accepts what the encoder
    /// emits for the fullest and the barest value of each model.
    func testRealEncoderOutputValidatesAgainstCheckedInSchemas() throws {
        for tool in MCPToolRegistry.tools {
            guard let samples = try Self.outputs[tool.name]?() else { continue }
            let schema = try SchemaFiles.load("tools/\(tool.name).output.schema.json")
            for sample in samples {
                let errors = JSONSchema.errors(sample, schema)
                XCTAssertTrue(errors.isEmpty, "\(tool.name): \(errors.joined(separator: "; "))")
            }
        }
    }

    func testIndexMatchesRegistry() throws {
        let tools: [JSONValue] = ContractProbe.contracts.map { contract in
            let tool = contract.tool
            var entry: [String: JSONValue] = [
                "name": .string(tool.name),
                "cli": .string((["pippin"] + contract.path).joined(separator: " ")),
                "effect": .string(tool.effect == .readOnly ? "read" : "write"),
                "input_schema": .string("tools/\(tool.name).input.schema.json"),
                "output_schema": Self.outputs[tool.name] == nil ? .null : .string("tools/\(tool.name).output.schema.json"),
                // Which CLI arguments each property sets, as found by running buildArgs.
                "arguments": .object(contract.bindings.mapValues { .array($0.map { .string($0) }) }),
            ]
            if let reason = Self.noOutputSchema[tool.name] { entry["output_schema_absent_because"] = .string(reason) }
            if case let .mutating(verifyWith?) = tool.effect { entry["verify_with"] = .string(verifyWith) }
            return .object(entry)
        }
        try SchemaFiles.assertGolden("index.json", .object([
            "envelope_version": .int(Int64(AGENT_SCHEMA_VERSION)),
            "envelope_schema": .string("envelope.schema.json"),
            "tools": .array(tools),
        ]))
    }

    func testNoOrphanSchemaFiles() throws {
        var expected: Set<String> = []
        for tool in MCPToolRegistry.tools {
            expected.insert("\(tool.name).input.schema.json")
            if Self.outputs[tool.name] != nil { expected.insert("\(tool.name).output.schema.json") }
        }
        let present = try FileManager.default.contentsOfDirectory(atPath: SchemaFiles.directory.appendingPathComponent("tools").path)
        XCTAssertEqual(Set(present).subtracting(expected), [], "schema files with no tool; delete them")
    }

    /// A property is deprecated in both places or neither: the word in its
    /// description and the JSON Schema `deprecated` annotation.
    func testDeprecatedPropertiesAreAnnotated() {
        for contract in ContractProbe.contracts {
            for (name, schema) in contract.properties {
                let described = schema["description"]?.stringValue?.localizedCaseInsensitiveContains("deprecated") ?? false
                XCTAssertEqual(
                    described, schema["deprecated"] == .bool(true),
                    "\(contract.tool.name).\(name): say Deprecated in the description and set \"deprecated\": true together"
                )
            }
        }
    }

    // MARK: - Envelope

    func testEnvelopeSchemaAcceptsEveryEnvelopeShape() throws {
        let schema = try SchemaFiles.load("envelope.schema.json")
        XCTAssertEqual(SchemaFiles.version, "v4", "envelope version changed: add docs/schemas/\(SchemaFiles.version)/ and keep v4 as published")
        let remediation = Remediation(humanHint: "hint", doctorCheck: "check", shellCommand: "cmd")
        let envelopes: [String] = try [
            agentJSON(["a": 1]),
            agentJSON([1, 2], warnings: ["w"], partial: true, nextCursor: "c"),
            projectedAgentJSON([["id": "1", "x": "y"]], fields: ["id"], warnings: ["w"], partial: true, nextCursor: "c"),
            MCPInProcessTools.errorEnvelope(ValidationErrorStub(), startedAt: Date()),
            encodedEnvelope(AgentError(code: "rate_limited", message: "m", remediation: remediation, nextStep: .retry(after: 3))),
            encodedEnvelope(AgentError(code: "not_found", message: "m", nextStep: .call(tool: "mail_list", args: ["a": "b"], argv: ["mail", "list"]))),
            encodedEnvelope(AgentError(code: "access_denied", message: "m", nextStep: .human("Grant access"))),
        ]
        for text in envelopes {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            let errors = JSONSchema.errors(value, schema)
            XCTAssertTrue(errors.isEmpty, "\(text): \(errors.joined(separator: "; "))")
        }
    }

    func testEnvelopeSchemaRejectsBrokenEnvelopes() throws {
        let schema = try SchemaFiles.load("envelope.schema.json")
        let broken = [
            #"{"v":3,"status":"ok","duration_ms":1,"data":[]}"#,
            #"{"v":4,"status":"ok","duration_ms":1}"#,
            #"{"v":4,"status":"ok","duration_ms":-1,"data":[]}"#,
            #"{"v":4,"status":"ok","duration_ms":1,"data":[],"partial":false}"#,
            #"{"v":4,"status":"ok","duration_ms":1,"data":[],"warnings":[]}"#,
            #"{"v":4,"status":"error","duration_ms":1,"error":{"code":"x","message":"m"}}"#,
            #"{"v":4,"status":"error","duration_ms":1,"error":{"code":"Not Snake","message":"m","next_step":{"retryable":false}}}"#,
            #"{"v":4,"status":"done","duration_ms":1,"data":[]}"#,
            #"[]"#,
        ]
        for text in broken {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            XCTAssertFalse(JSONSchema.errors(value, schema).isEmpty, "schema accepts \(text)")
        }
    }

    private struct ValidationErrorStub: Error {}

    private func encodedEnvelope(_ error: AgentError) throws -> String {
        let envelope = AgentErrorEnvelope(v: AGENT_SCHEMA_VERSION, status: "error", durationMs: 0, error: error.error)
        return try String(decoding: JSONEncoder().encode(envelope), as: UTF8.self)
    }
}
