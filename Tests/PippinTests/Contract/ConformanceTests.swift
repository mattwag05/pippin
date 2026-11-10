import Foundation
@testable import PippinLib
import XCTest

/// Runs the built `pippin` binary for every MCP tool and checks stdout is
/// exactly one JSON document that validates against `envelope.schema.json`.
///
/// Nothing here reaches Mail, Messages, Notes, Calendar, Reminders or
/// Contacts: the error path only spawns argv the parser refuses, and the
/// success path runs the few commands that need no Apple app, under a
/// throwaway home directory.
final class ConformanceTests: XCTestCase {
    private var home: URL!

    override class func setUp() {
        super.setUp()
        CLIIntegrationTests.setUp() // locates the built binary
    }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("pippin-conformance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: home)
    }

    /// The environment with every per-user path pointed at the throwaway home.
    private var hermeticEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        env["CFFIXED_USER_HOME"] = home.path // what NSHomeDirectory() reads
        env["PIPPIN_CONFIG"] = home.appendingPathComponent("config.json").path
        env["PIPPIN_MCP"] = nil
        return env
    }

    private func run(_ argv: [String]) throws -> (stdout: String, exitCode: Int32) {
        let binary = try XCTUnwrap(CLIIntegrationTests.binaryURL, "pippin binary not found; run `swift build` first")
        let result = CLIIntegrationTests.runProcess(binary.path, args: argv, env: hermeticEnvironment)
        return (result.stdout, result.exitCode)
    }

    /// Asserts `stdout` is one newline-terminated JSON document that fits the
    /// envelope schema, and returns it.
    private func envelope(_ stdout: String, _ label: String) throws -> JSONValue? {
        let schema = try SchemaFiles.load("envelope.schema.json")
        guard stdout.hasSuffix("\n"), !stdout.dropLast().contains("\n") else {
            XCTFail("\(label): stdout is not a single line: \(stdout.prefix(300))")
            return nil
        }
        // JSONDecoder refuses trailing content, so a second document fails here.
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(stdout.utf8)) else {
            XCTFail("\(label): stdout is not one JSON document: \(stdout.prefix(300))")
            return nil
        }
        let errors = JSONSchema.errors(value, schema)
        XCTAssertTrue(errors.isEmpty, "\(label): \(errors.joined(separator: "; "))")
        return value
    }

    // MARK: - Error path, every tool

    func testEveryToolAnswersABadArgumentWithOneErrorEnvelope() throws {
        XCTAssertEqual(ContractProbe.contracts.count, MCPToolRegistry.tools.count)
        for contract in ContractProbe.contracts {
            let argv = contract.path + ["--format=not-a-format"]
            // Spawn only what the parser refuses, so no command body can run.
            guard (try? ContractRoot.parseAsRoot(argv)) == nil else {
                XCTFail("\(contract.tool.name): \(argv) parses, so it is not a safe bad-argument probe")
                continue
            }
            let result = try run(argv)
            XCTAssertNotEqual(result.exitCode, 0, "\(contract.tool.name): bad argument exited 0")
            guard let value = try envelope(result.stdout, contract.tool.name) else { continue }
            XCTAssertEqual(value["status"]?.stringValue, "error", contract.tool.name)
        }
    }

    /// The MCP dispatcher's own refusal (a missing required argument never
    /// reaches a child) is the same envelope.
    func testEveryToolRefusesMissingArgumentsWithAValidEnvelope() throws {
        let schema = try SchemaFiles.load("envelope.schema.json")
        var refused = 0
        for tool in MCPToolRegistry.tools {
            do {
                _ = try tool.buildArgs(.object([:]))
            } catch {
                refused += 1
                let text = MCPInProcessTools.errorEnvelope(error, startedAt: Date())
                let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
                let errors = JSONSchema.errors(value, schema)
                XCTAssertTrue(errors.isEmpty, "\(tool.name): \(errors.joined(separator: "; "))")
            }
        }
        XCTAssertGreaterThan(refused, 20, "expected most tools with required arguments to refuse an empty call")
    }

    // MARK: - Success path, where one is hermetic

    /// Runs `tool` with `arguments` and checks the envelope and, when the tool
    /// has an output schema, its `data`.
    private func succeed(_ name: String, _ arguments: [String: JSONValue] = [:]) throws -> JSONValue? {
        let tool = try XCTUnwrap(MCPToolRegistry.tool(named: name))
        let result = try run(tool.buildArgs(.object(arguments)))
        guard let value = try envelope(result.stdout, name) else { return nil }
        XCTAssertEqual(result.exitCode, 0, "\(name): \(result.stdout.prefix(300))")
        XCTAssertEqual(value["status"]?.stringValue, "ok", "\(name): \(result.stdout.prefix(300))")
        if SchemaGoldenTests.outputs[name] != nil, let data = value["data"] {
            let errors = try JSONSchema.errors(data, SchemaFiles.load("tools/\(name).output.schema.json"))
            XCTAssertTrue(errors.isEmpty, "\(name) data: \(errors.joined(separator: "; "))")
        }
        return value["data"]
    }

    func testHermeticToolsSucceedWithOneValidEnvelope() throws {
        _ = try succeed("job_list")
        _ = try succeed("messages_exclude_list")

        // Each batch entry's response is an envelope of its own.
        let schema = try SchemaFiles.load("envelope.schema.json")
        let entries: JSONValue = .array([.object(["cmd": .string("job"), "args": .array([.string("list")])])])
        let responses = try XCTUnwrap(succeed("batch", ["entries": entries])?.arrayValue)
        XCTAssertEqual(responses.count, 1)
        for response in responses {
            let errors = JSONSchema.errors(response, schema)
            XCTAssertTrue(errors.isEmpty, "batch entry: \(errors.joined(separator: "; "))")
        }

        let started = try succeed("job_run", ["argv": .array([.string("job"), .string("list")])])
        let id = try XCTUnwrap(started?["id"]?.stringValue, "job_run returned no id")
        _ = try succeed("job_wait", ["id": .string(id)])
        _ = try succeed("job_show", ["id": .string(id)])
        // The job record landed in the throwaway home, so the isolation held.
        let written = FileManager.default.enumerator(at: home, includingPropertiesForKeys: nil)?.allObjects ?? []
        XCTAssertFalse(written.isEmpty, "nothing was written under the throwaway home; the commands used the real one")
    }
}
