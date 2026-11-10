import Foundation
@testable import PippinLib
import XCTest

/// Runs every read-only tool against real app data and checks that stdout is
/// one envelope that fits `envelope.schema.json` and, for an `ok` result with
/// an output schema, that `data` fits it too. `ConformanceTests` covers the
/// error path of every tool; this covers the success path the hermetic suite
/// cannot reach.
///
/// It reads real Mail, Messages, Notes, Calendar, Reminders and Contacts, so
/// it runs only inside a virtual machine with fixture data and only when asked:
///
///     PIPPIN_LIVE_CONFORMANCE=1 PIPPIN_LIVE_BIN=<granted pippin> \
///         swift test --filter LiveConformanceTests
///
/// A failure names the tool and the schema errors, never the data.
final class LiveConformanceTests: XCTestCase {
    /// Arguments for tools whose required arguments need a real-looking value.
    /// Ids that match nothing give a schema-valid `error` envelope, which is
    /// still checked; the list and search tools carry the `data` checks.
    private static let arguments: [String: JSONValue] = [
        "calendar_search": .object(["query": .string("e")]),
        "reminders_search": .object(["query": .string("e")]),
        "contacts_search": .object(["query": .string("e")]),
        "notes_search": .object(["query": .string("e")]),
        "mail_search": .object(["query": .string("e")]),
        "messages_search": .object(["query": .string("e"), "sinceHours": .int(24 * 365)]),
    ]

    /// Read tools left out, with why.
    private static let skipped: [String: String] = [
        "memos_transcribe": "Runs a speech model for minutes; past this test's budget.",
        "memos_summarize": "Needs an AI provider and a transcript.",
        "memos_export": "Writes files to a directory.",
        "mail_triage": "Needs an AI provider.",
        "actions_extract": "Needs an AI provider.",
        "calendar_agenda": "Needs an AI provider.",
        "job_wait": "Needs a running job; ConformanceTests covers it.",
    ]

    func testEveryReadToolEmitsASchemaValidEnvelopeOnRealData() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["PIPPIN_LIVE_CONFORMANCE"] == "1" else {
            throw XCTSkip("Set PIPPIN_LIVE_CONFORMANCE=1 inside a VM with fixture data.")
        }
        var isVM: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.hv_vmm_present", &isVM, &size, nil, 0) == 0, isVM == 1 else {
            throw XCTSkip("Refusing to read real app data outside a virtual machine.")
        }
        let binary = try XCTUnwrap(env["PIPPIN_LIVE_BIN"], "PIPPIN_LIVE_BIN must name a pippin binary that holds the VM's grants")
        let envelopeSchema = try SchemaFiles.load("envelope.schema.json")

        var tally: [String: Int] = [:]
        for tool in MCPToolRegistry.tools where tool.effect == .readOnly && Self.skipped[tool.name] == nil {
            let argv: [String]
            do {
                argv = try tool.buildArgs(Self.arguments[tool.name] ?? Self.placeholders(tool))
            } catch {
                tally["refused before running", default: 0] += 1
                continue
            }
            let stdout = try run(binary, argv)
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(stdout.utf8)),
                  stdout.hasSuffix("\n"), !stdout.dropLast().contains("\n")
            else {
                XCTFail("\(tool.name): stdout is not one JSON line (\(stdout.utf8.count) bytes)")
                continue
            }
            let errors = JSONSchema.errors(value, envelopeSchema)
            XCTAssertTrue(errors.isEmpty, "\(tool.name) envelope: \(errors.joined(separator: "; "))")
            let status = value["status"]?.stringValue ?? "?"
            tally[status, default: 0] += 1
            if status == "ok", SchemaGoldenTests.outputs[tool.name] != nil, let data = value["data"] {
                let dataErrors = try JSONSchema.errors(data, SchemaFiles.load("tools/\(tool.name).output.schema.json"))
                XCTAssertTrue(dataErrors.isEmpty, "\(tool.name) data: \(dataErrors.joined(separator: "; "))")
                tally["ok with data checked", default: 0] += 1
            }
        }
        print("LiveConformanceTests:", tally.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        XCTAssertGreaterThan(tally["ok with data checked", default: 0], 20, "too few tools returned data to check")
    }

    /// A value of the right type for each required property.
    private static func placeholders(_ tool: MCPTool) -> JSONValue {
        guard let required = tool.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue),
              case let .object(properties)? = tool.inputSchema["properties"]
        else { return .object([:]) }
        var arguments: [String: JSONValue] = [:]
        for name in required {
            switch properties[name]?["type"]?.stringValue {
            case "integer": arguments[name] = .int(1)
            case "number": arguments[name] = .double(1)
            case "boolean": arguments[name] = .bool(false)
            case "array": arguments[name] = .array([.string("zz-no-such-item")])
            default: arguments[name] = .string("zz-no-such-item")
            }
        }
        return .object(arguments)
    }

    /// Runs the binary as a user would: the disclaim re-exec stays on, so TCC
    /// answers for pippin's own grants. Output goes to a file, not a pipe, so a
    /// large result cannot block the child.
    private func run(_ binary: String, _ argv: [String]) throws -> String {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString).json")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: out) }
        let handle = try FileHandle(forWritingTo: out)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = argv
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(90)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            XCTFail("\(argv.prefix(2).joined(separator: " ")): no answer in 90 s")
        }
        try handle.close()
        return try String(contentsOf: out, encoding: .utf8)
    }
}
