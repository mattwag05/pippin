import Foundation
@testable import PippinLib
import XCTest

/// Generates `docs/cli-reference.md` from the built binary's own command
/// definitions (`--experimental-dump-help`) and fails when the checked-in file
/// differs, so every visible command is documented with its own help text.
/// Regenerate after a command change: `PIPPIN_UPDATE_SCHEMAS=1 make test`.
final class CLIReferenceTests: XCTestCase {
    private struct Command: Decodable {
        let commandName: String
        let abstract: String?
        let shouldDisplay: Bool?
        let subcommands: [Command]?
    }

    private struct Dump: Decodable {
        let command: Command
    }

    func testCLIReferenceListsEveryVisibleCommand() throws {
        CLIIntegrationTests.setUp()
        let binary = try XCTUnwrap(CLIIntegrationTests.binaryURL, "pippin binary not found; run `swift build` first")
        let result = CLIIntegrationTests.runProcess(binary.path, args: ["--experimental-dump-help"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let dump = try JSONDecoder().decode(Dump.self, from: Data(result.stdout.utf8))

        var rows: [String] = []
        func walk(_ command: Command, _ path: [String]) {
            guard command.shouldDisplay ?? true else { return }
            let children = (command.subcommands ?? []).filter { $0.commandName != "help" }
            if children.isEmpty, !path.isEmpty {
                let about = (command.abstract ?? "").replacingOccurrences(of: "|", with: "\\|")
                rows.append("| `pippin \(path.joined(separator: " "))` | \(about) |")
            }
            for child in children {
                walk(child, path + [child.commandName])
            }
        }
        walk(dump.command, [])
        XCTAssertGreaterThan(rows.count, 90)

        let text = """
        # CLI reference

        Every command `pippin` exposes, with its own help text. Generated from the command definitions by `CLIReferenceTests`; do not edit by hand. Regenerate with `PIPPIN_UPDATE_SCHEMAS=1 make test`. Run `pippin <command> --help` for the options of one command, and see [mcp-server.md](mcp-server.md) for the MCP tools.

        | Command | What it does |
        | --- | --- |
        \(rows.joined(separator: "\n"))

        """
        let url = SchemaFiles.repoRoot.appendingPathComponent("docs/cli-reference.md")
        if ProcessInfo.processInfo.environment["PIPPIN_UPDATE_SCHEMAS"] == "1" {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let current = try? String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(current, text, "docs/cli-reference.md is stale; run PIPPIN_UPDATE_SCHEMAS=1 make test")
    }
}
