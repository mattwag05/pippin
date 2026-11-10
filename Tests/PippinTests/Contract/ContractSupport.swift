import ArgumentParser
import Foundation
@testable import PippinLib
import XCTest

/// The command groups an MCP tool can reach, the same root the registry reads
/// its definitions from. The real root lives in the executable target, which
/// tests cannot import; `ConformanceTests` runs every tool against the built
/// binary, so a group listed there but missing here fails.
typealias ContractRoot = MCPCommandRoot

/// The parts of ArgumentParser's `--experimental-dump-help` JSON the contract reads.
struct DumpCommand: Decodable {
    struct Argument: Decodable {
        struct Name: Decodable {
            let kind: String
            let name: String
        }

        let kind: String
        let names: [Name]?
        let isOptional: Bool
        let isRepeating: Bool
        let shouldDisplay: Bool
        let allValues: [String]?

        var longNames: [String] { (names ?? []).filter { $0.kind == "long" }.map(\.name) }
    }

    let commandName: String
    let subcommands: [DumpCommand]?
    let arguments: [Argument]?

    var positionals: [Argument] { (arguments ?? []).filter { $0.kind == "positional" } }

    func argument(long name: String) -> Argument? {
        (arguments ?? []).first { $0.longNames.contains(name) }
    }

    func descend(_ path: [String]) -> DumpCommand? {
        path.reduce(Optional(self)) { node, name in node?.subcommands?.first { $0.commandName == name } }
    }

    static let root: DumpCommand = {
        struct Dump: Decodable { let command: DumpCommand }
        guard let dump = try? JSONDecoder().decode(Dump.self, from: Data(ContractRoot._dumpHelp().utf8)) else {
            fatalError("ArgumentParser's help dump no longer decodes; update DumpCommand")
        }
        return dump.command
    }()
}

/// One argv element after parsing: which CLI argument it feeds and with what.
/// `key` is `--name` for an option or flag and `<n>` for the nth positional.
struct BoundToken: Hashable {
    let key: String
    let value: String?
}

/// How one MCP tool maps onto its CLI command, found by running `buildArgs`.
struct ToolContract {
    let tool: MCPTool
    let path: [String]
    let command: DumpCommand
    /// Schema property to the CLI arguments it sets.
    var bindings: [String: [String]] = [:]
    /// Every CLI argument some call reached.
    var reached: Set<String> = []
    /// The argv each property was probed with, for the type checks.
    var probes: [String: (value: JSONValue, argv: [String])] = [:]
    var problems: [String] = []

    var properties: [String: JSONValue] {
        guard case let .object(dict)? = tool.inputSchema["properties"] else { return [:] }
        return dict
    }

    var required: [String] { (tool.inputSchema["required"]?.arrayValue ?? []).compactMap(\.stringValue) }

    func cliArgument(_ key: String) -> DumpCommand.Argument? {
        if key.hasPrefix("--") { return command.argument(long: String(key.dropFirst(2))) }
        guard let index = Int(key.dropFirst().dropLast()) else { return nil }
        let positionals = command.positionals
        return index < positionals.count ? positionals[index] : positionals.last
    }

    /// Split argv (after the command path) into the CLI arguments it sets.
    func bind(_ argv: [String]) -> [BoundToken] {
        var tokens: [BoundToken] = []
        var positional = 0
        var rest = Array(argv.dropFirst(path.count))[...]
        var literal = false
        while let token = rest.popFirst() {
            if literal || !token.hasPrefix("-") {
                tokens.append(BoundToken(key: "<\(positional)>", value: token))
                positional += 1
            } else if token == "--" {
                literal = true
            } else if let equals = token.firstIndex(of: "=") {
                tokens.append(BoundToken(key: String(token[..<equals]), value: String(token[token.index(after: equals)...])))
            } else if command.argument(long: String(token.dropFirst(2)))?.kind == "option" {
                tokens.append(BoundToken(key: token, value: rest.popFirst()))
            } else {
                tokens.append(BoundToken(key: token, value: nil))
            }
        }
        return tokens
    }
}

enum ContractProbe {
    /// Two different values the schema allows for `property`; the second lets a
    /// required property be varied where it cannot be left out.
    static func samples(_ tool: String, _ property: String, _ schema: JSONValue) -> (JSONValue, JSONValue) {
        let group = String(tool.prefix { $0 != "_" })
        let isArray = schema["type"]?.stringValue == "array"
        if let fixed = sampleValues["\(tool).\(property)"] ?? sampleValues["\(group).\(property)"] ?? sampleValues[property] {
            // A string sample for an array property is one element of it.
            func shaped(_ value: JSONValue) -> JSONValue {
                isArray && value.stringValue != nil ? .array([value]) : value
            }
            return (shaped(fixed.0), shaped(fixed.1))
        }
        if let cases = schema["enum"]?.arrayValue, let first = cases.first { return (first, cases.last ?? first) }
        switch schema["type"]?.stringValue {
        case "integer": return (.int(3), .int(4))
        case "number": return (.double(0.5), .double(0.25))
        case "boolean": return (.bool(true), .bool(false))
        case "array": return (.array([.string("sample-\(property)")]), .array([.string("other-\(property)")]))
        default: return (.string("sample-\(property)"), .string("other-\(property)"))
        }
    }

    private static let day: (JSONValue, JSONValue) = (.string("2026-01-02"), .string("2026-01-03"))
    private static let email: (JSONValue, JSONValue) = (.string("a@example.com"), .string("b@example.com"))

    /// Values the CLI's own validation needs in a particular shape, keyed by
    /// `tool.property`, `group.property`, or a property name shared across tools.
    static let sampleValues: [String: (JSONValue, JSONValue)] = [
        "after": day, "before": day, "since": day, "start": day, "end": day, "due": day,
        "dueAfter": day, "dueBefore": day, "createdAfter": day, "modifiedAfter": day, "occurrence": day,
        "calendar.from": day, "calendar.to": day,
        "mail_send.to": email, "mail_reply.to": email, "mail_forward.to": email, "cc": email, "bcc": email,
        "attach": (.string("/etc/hosts"), .string("/etc/shells")),
        "saveDir": (.string("/tmp"), .string("/private/tmp")),
        "range": (.string("today"), .string("week")),
        "span": (.string("this"), .string("all")),
        "priority": (.string("high"), .string("low")),
        "alert": (.string("15m"), .string("1h")),
        "sidecarFormat": (.string("txt"), .string("srt")),
        "job_run.argv": (.array([.string("status")]), .array([.string("doctor")])),
        "batch.entries": (
            .array([.object(["cmd": .string("status")])]),
            .array([.object(["cmd": .string("doctor")])])
        ),
    ]

    /// Properties that satisfy a tool whose requirement is "one of several",
    /// which JSON Schema `required` cannot say.
    static let oneOfRequired: [String: String] = [
        "mail_show": "messageId",
        "memos_export": "id", "memos_transcribe": "id", "memos_summarize": "id",
        "notes_edit": "title",
    ]

    /// Nil when `argv` parses to the command at `path`, else why not.
    static func parseFailure(_ argv: [String], as path: [String]) -> String? {
        do {
            let parsed = try ContractRoot.parseAsRoot(argv)
            let name = type(of: parsed).configuration.commandName
            return name == path.last ? nil : "parsed as `\(name ?? "?")`, expected `\(path.joined(separator: " "))`"
        } catch {
            return ContractRoot.message(for: error)
        }
    }

    /// The smallest arguments a tool accepts.
    static func baseline(for tool: MCPTool) -> [String: JSONValue] {
        let names = (tool.inputSchema["required"]?.arrayValue ?? []).compactMap(\.stringValue)
            + [oneOfRequired[tool.name]].compactMap { $0 }
        var baseline: [String: JSONValue] = [:]
        for name in names {
            baseline[name] = tool.inputSchema["properties"]?[name].map { samples(tool.name, name, $0).0 }
        }
        return baseline
    }

    static func contract(for tool: MCPTool) -> ToolContract? {
        let path = MCPCommandPolicy.commandPath(for: tool.name)
        guard let command = DumpCommand.root.descend(path) else { return nil }
        var contract = ToolContract(tool: tool, path: path, command: command)
        let baseline = baseline(for: tool)
        do {
            let baseArgv = try tool.buildArgs(.object(baseline))
            if let failure = parseFailure(baseArgv, as: path) {
                contract.problems.append("minimal argv \(baseArgv) does not parse: \(failure)")
            }
            contract.reached.formUnion(contract.bind(baseArgv).map(\.key))
        } catch {
            contract.problems.append("buildArgs rejects the minimal arguments \(baseline.keys.sorted()): \(error.localizedDescription)")
            return contract
        }

        for (name, schema) in contract.properties.sorted(by: { $0.key < $1.key }) {
            let (value, other) = samples(tool.name, name, schema)
            var with = baseline
            with[name] = value
            // Compare against the call without the property, or with a
            // different value where the baseline needs it.
            var against = baseline
            against[name] = baseline[name] == nil ? nil : other
            guard let argv = try? tool.buildArgs(.object(with)) else {
                contract.problems.append("\(name): buildArgs rejects \(value)")
                continue
            }
            if let failure = parseFailure(argv, as: path) {
                contract.problems.append("\(name): argv \(argv) does not parse: \(failure)")
            }
            contract.probes[name] = (value, argv)
            let tokens = contract.bind(argv)
            contract.reached.formUnion(tokens.map(\.key))
            guard let others = (try? tool.buildArgs(.object(against))).map(contract.bind) else {
                // Only a gate (`confirm` must be true) refuses the other value.
                contract.bindings[name] = []
                continue
            }
            contract.reached.formUnion(others.map(\.key))
            var added = Set(tokens).subtracting(others).map(\.key)
            let removed = Set(others).subtracting(tokens).map(\.key)
            // An alternative to the one-of property (`subject` beside
            // `messageId`) only shows once that property is out of the way.
            if added.isEmpty, removed.isEmpty, let alternative = oneOfRequired[tool.name], alternative != name {
                var alone = baseline
                alone[alternative] = nil
                alone[name] = value
                if let aloneArgv = try? tool.buildArgs(.object(alone)) {
                    if let failure = parseFailure(aloneArgv, as: path) {
                        contract.problems.append("\(name): argv \(aloneArgv) does not parse: \(failure)")
                    }
                    contract.probes[name] = (value, aloneArgv)
                    let aloneTokens = contract.bind(aloneArgv)
                    contract.reached.formUnion(aloneTokens.map(\.key))
                    added = Set(aloneTokens).subtracting(others).map(\.key)
                }
            }
            contract.bindings[name] = Set(added.isEmpty ? removed : added).sorted()
        }
        return contract
    }

    static func sampleStrings(_ value: JSONValue) -> [String] {
        switch value {
        case let .string(text): return [text]
        case let .int(number): return [String(number)]
        case let .double(number): return [String(number)]
        case let .array(items): return items.flatMap(sampleStrings)
        default: return []
        }
    }

    static let contracts: [ToolContract] = MCPToolRegistry.tools.compactMap(contract)
}
