import ArgumentParser
import Foundation
@testable import PippinLib
import XCTest

/// Checks the generated MCP registry against the ArgumentParser command
/// definitions. The CLI is the source and the registry derives each tool's
/// schema and `buildArgs` from it; these tests read the help dump on their own
/// and run the real parser, so a wrong `as: .integer`, a `.custom` closure or a
/// generator bug that disagrees with the CLI fails here.
final class CLIMCPDriftTests: XCTestCase {
    /// CLI arguments deliberately not offered to MCP clients, with the tools
    /// they apply to (nil: every tool) and why. An entry that stops being
    /// needed fails `testAllowlistHasNoStaleEntries`.
    static let cliOnly: [String: (tools: Set<String>?, reason: String)] = [
        "--help": (nil, "ArgumentParser built-in; prints text, not an envelope."),
        "--fields": (nil, "Row projection; offered on the list and search tools (MCPToolRegistry.projectableTools) only."),
        "--api-key": (nil, "Secret. Provider keys come from config or the environment, never from tool arguments."),
        "--summarize-api-key": (nil, "Secret, as --api-key."),
        "--sanitize-api-key": (nil, "Secret, as --api-key."),
        "--summarize": (["mail_list", "mail_show"], "Inline AI summary; MCP clients summarize themselves or call memos_summarize / mail_triage."),
        "--summarize-provider": (["mail_list", "mail_show"], "Belongs to --summarize."),
        "--summarize-model": (["mail_list", "mail_show"], "Belongs to --summarize."),
        "--sanitize": (["mail_show"], "mail_sanitize is the tool for this."),
        "--ai-assisted-scan": (["mail_show"], "Belongs to --sanitize."),
        "--sanitize-provider": (["mail_show"], "Belongs to --sanitize."),
        "--sanitize-model": (["mail_show"], "Belongs to --sanitize."),
        "--no-cache": (["mail_list", "mail_show", "mail_verify"], "Cache bypass is a debugging switch."),
        "--contacts": (nil, "Contact-name resolution follows the user's config; not a per-call choice for an agent."),
        "--no-contacts": (nil, "As --contacts."),
        "--verbose": (["mail_search"], "Diagnostics on stderr, which MCP does not return."),
        "--embedding-model": (["mail_search"], "Semantic-search backend is the user's config."),
        "--ollama-url": (["mail_search"], "Semantic-search backend is the user's config."),
        "--provider": (["mail_search"], "Semantic-search backend is the user's config."),
        "--type": (["calendar_events"], "Not exposed yet; calendarId and calendarName cover the common filter."),
        "--limit": (["calendar_upcoming", "contacts_search"], "Not exposed; pageSize is the row bound these tools offer."),
        "<0>": (["calendar_search"], "The positional query; the tool passes --query, which cannot be mistaken for a flag."),
        "--autonomous": (["messages_send"], "Refused for MCP clients by MCPCommandPolicy."),
        "--keep-converted": (["memos_transcribe"], "Leaves a temp file behind; a debugging switch."),
        "--skip": (["digest"], "Not exposed yet."),
        "--no-mail": (["actions_extract"], "Not exposed yet."),
        "--no-notes": (["actions_extract"], "Not exposed yet."),
        "--latency": (["doctor"], "Adds up to 70 s, past the MCP call budget; run it from the CLI."),
        "--poll-ms": (["job_wait"], "Polling cadence is an implementation detail."),
        "--wait": (["job_run"], "Holds the process open; job_run returns at once and job_wait blocks."),
        "--schedule-id": (["job_run"], "Set by the LaunchAgent that `job schedule` writes; scheduling is CLI-only."),
        "--input": (["batch"], "Reads a file; the tool passes entries inline."),
        "--locate-by-message-id": (["mail_move"], "What `pippin undo` runs to move a message back; a client calls undo instead."),
        "--incomplete": (["reminders_complete"], "What `pippin undo` runs to un-complete; a client calls undo instead."),
        "--html": (["notes_show"], "The HTML body, read by undo to restore a note; clients get plainText."),
    ]

    /// Properties whose mapping is not one option of the same JSON type.
    static let specialBindings: [String: String] = [
        "calendar_delete.confirm": "Gate: buildArgs refuses the call unless true, then always passes --force.",
        "reminders_delete.confirm": "Gate, as calendar_delete.confirm.",
        "contacts_delete.confirm": "Gate, as calendar_delete.confirm.",
        "notes_delete.confirm": "Gate, as calendar_delete.confirm.",
        "memos_delete.confirm": "Gate, as calendar_delete.confirm.",
        "contacts_search.phone": "Moves the query from the positional to the value of --phone.",
        "batch.entries": "An array of objects, passed as one JSON string to --entries.",
    ]

    func testEveryToolMapsToACLICommand() {
        let mapped = Set(ContractProbe.contracts.map(\.tool.name))
        for tool in MCPToolRegistry.tools where !mapped.contains(tool.name) {
            XCTFail("\(tool.name): no CLI command at `\(MCPCommandPolicy.commandPath(for: tool.name).joined(separator: " "))`")
        }
    }

    func testBuildArgsParsesWithTheRealCommands() {
        for contract in ContractProbe.contracts {
            for problem in contract.problems {
                XCTFail("\(contract.tool.name): \(problem)")
            }
        }
    }

    func testEverySchemaPropertySetsACLIArgument() {
        for contract in ContractProbe.contracts {
            for (name, keys) in contract.bindings.sorted(by: { $0.key < $1.key }) {
                if keys.isEmpty, Self.specialBindings["\(contract.tool.name).\(name)"] == nil {
                    XCTFail("\(contract.tool.name).\(name): setting it changes nothing in argv")
                }
                for key in keys where contract.cliArgument(key) == nil {
                    XCTFail("\(contract.tool.name).\(name): `\(key)` is not an argument of `\(contract.path.joined(separator: " "))`")
                }
            }
        }
    }

    func testSchemaTypesMatchCLIArgumentKinds() {
        for contract in ContractProbe.contracts {
            for (name, keys) in contract.bindings.sorted(by: { $0.key < $1.key }) {
                guard let schema = contract.properties[name], let probe = contract.probes[name] else { continue }
                let label = "\(contract.tool.name).\(name)"
                if Self.specialBindings[label] != nil { continue }
                let type = schema["type"]?.stringValue ?? "?"
                for key in keys {
                    guard let argument = contract.cliArgument(key) else { continue }
                    switch type {
                    case "boolean":
                        XCTAssertEqual(argument.kind, "flag", "\(label): boolean bound to \(argument.kind) `\(key)`")
                    case "array":
                        XCTAssertTrue(argument.isRepeating, "\(label): array bound to non-repeating `\(key)`")
                    case "integer", "number":
                        // The dump carries no Swift types, so ask the parser: a
                        // numeric CLI argument must refuse text, and an integer
                        // one must refuse a fraction.
                        guard let sample = ContractProbe.sampleStrings(probe.value).first else { continue }
                        func swapped(_ replacement: String) -> [String] {
                            probe.argv.map { $0 == "\(key)=\(sample)" || ($0 == sample && !key.hasPrefix("--")) ? $0.replacingOccurrences(of: sample, with: replacement) : $0 }
                        }
                        guard swapped("zz") != probe.argv else {
                            XCTFail("\(label): cannot find `\(key)=\(sample)` in \(probe.argv) to check its type")
                            continue
                        }
                        XCTAssertNotNil(
                            ContractProbe.parseFailure(swapped("zz"), as: contract.path),
                            "\(label): schema says \(type) but `\(key)` accepts text"
                        )
                        let fraction = ContractProbe.parseFailure(swapped("0.75"), as: contract.path)
                        if type == "integer" {
                            XCTAssertNotNil(fraction, "\(label): schema says integer but `\(key)` accepts 0.75")
                        } else {
                            XCTAssertNil(fraction, "\(label): schema says number but `\(key)` refuses 0.75")
                        }
                    default:
                        XCTAssertNotEqual(argument.kind, "flag", "\(label): \(type) bound to flag `\(key)`")
                    }
                }
            }
        }
    }

    func testRequiredCLIArgumentsAreRequiredInTheSchema() {
        for contract in ContractProbe.contracts {
            let positionals = contract.command.positionals
            let argumentsByKey = positionals.indices.map { ("<\($0)>", positionals[$0]) }
                + (contract.command.arguments ?? []).flatMap { argument in argument.longNames.map { ("--\($0)", argument) } }
            for (key, argument) in argumentsByKey where !argument.isOptional {
                let owners = contract.bindings.filter { $0.value.contains(key) }.keys
                guard !owners.isEmpty else { continue } // reported by the coverage test
                XCTAssertFalse(
                    owners.allSatisfy { !contract.required.contains($0) && ContractProbe.oneOfRequired[contract.tool.name] != $0 },
                    "\(contract.tool.name): CLI requires `\(key)` but none of \(owners.sorted()) is in the schema's required list"
                )
            }
        }
    }

    func testEnumsMatchCLIAllowedValues() {
        for contract in ContractProbe.contracts {
            for (name, keys) in contract.bindings.sorted(by: { $0.key < $1.key }) {
                let schemaValues = contract.properties[name]?["enum"]?.arrayValue?.compactMap(\.stringValue)
                for key in keys {
                    guard let cliValues = contract.cliArgument(key)?.allValues, !cliValues.isEmpty else { continue }
                    XCTAssertEqual(
                        schemaValues.map(Set.init), Set(cliValues),
                        "\(contract.tool.name).\(name): schema enum differs from the values `\(key)` accepts"
                    )
                }
            }
        }
    }

    func testEveryCLIArgumentIsExposedOrAllowlisted() {
        for contract in ContractProbe.contracts {
            let positionals = contract.command.positionals
            let keys = positionals.indices.map { "<\($0)>" }
                + (contract.command.arguments ?? []).filter(\.shouldDisplay).compactMap { $0.longNames.first.map { "--\($0)" } }
            for key in keys where !contract.reached.contains(key) && !Self.isCLIOnly(key, contract.tool.name) {
                XCTFail("\(contract.tool.name): CLI argument `\(key)` of `\(contract.path.joined(separator: " "))` is neither reachable from the tool nor in cliOnly")
            }
        }
    }

    func testAllowlistHasNoStaleEntries() {
        for (key, entry) in Self.cliOnly {
            let scoped = ContractProbe.contracts.filter { entry.tools?.contains($0.tool.name) ?? true }
            XCTAssertEqual(scoped.count, entry.tools?.count ?? scoped.count, "cliOnly[\(key)] names a tool that does not exist")
            let needed = scoped.filter { $0.cliArgument(key) != nil && !$0.reached.contains(key) }
            if entry.tools == nil {
                XCTAssertFalse(needed.isEmpty, "cliOnly[\(key)] is no longer needed by any tool")
            } else {
                XCTAssertEqual(needed.count, scoped.count, "cliOnly[\(key)] lists a tool that reaches it or whose command lacks it")
            }
        }
        let properties = Set(ContractProbe.contracts.flatMap { contract in contract.properties.keys.map { "\(contract.tool.name).\($0)" } })
        for label in Self.specialBindings.keys {
            XCTAssertTrue(properties.contains(label), "specialBindings names \(label), which no tool has")
        }
    }

    static func isCLIOnly(_ key: String, _ tool: String) -> Bool {
        guard let entry = cliOnly[key] else { return false }
        return entry.tools?.contains(tool) ?? true
    }
}
