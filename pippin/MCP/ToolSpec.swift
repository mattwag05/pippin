import ArgumentParser
import Foundation

/// The command groups an MCP tool can reach. The real root lives in the
/// executable target; this one exists so the registry can read the
/// ArgumentParser definitions of the commands its tools run.
/// `ConformanceTests` runs every tool against the built binary, so a group
/// listed here but missing there fails.
struct MCPCommandRoot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pippin",
        subcommands: [
            MailCommand.self, MemosCommand.self, CalendarCommand.self, ContactsCommand.self,
            RemindersCommand.self, NotesCommand.self, MessagesCommand.self, ActionsCommand.self,
            DigestCommand.self, DoctorCommand.self, StatusCommand.self, BatchCommand.self,
            JobCommand.self, PolicyCommand.self, LogCommand.self, UndoCommand.self,
        ]
    )
}

/// One argument of a CLI command, as ArgumentParser's help dump describes it.
/// The dump carries no Swift types, which is why a numeric option's binding
/// names its JSON type (`as: .integer`) and `CLIMCPDriftTests` checks it
/// against the real parser.
struct CLIArgument: Decodable {
    struct Name: Decodable {
        let kind: String
        let name: String
    }

    let kind: String
    let names: [Name]?
    let isOptional: Bool
    let isRepeating: Bool
    let abstract: String?
    let defaultValue: String?
    let allValues: [String]?

    var longNames: [String] { (names ?? []).filter { $0.kind == "long" }.map { "--\($0.name)" } }

    /// The arguments of the command at `path` under `MCPCommandRoot`.
    static func arguments(of path: [String]) -> [CLIArgument] {
        var command: ParsableCommand.Type = MCPCommandRoot.self
        for name in path {
            guard let next = command.configuration.subcommands.first(where: { $0._commandName == name }) else {
                fatalError("MCP tool registry: no CLI command `\(path.joined(separator: " "))`")
            }
            command = next
        }
        struct Dump: Decodable {
            struct Command: Decodable { let arguments: [CLIArgument]? }
            let command: Command
        }
        guard let dump = try? JSONDecoder().decode(Dump.self, from: Data(command._dumpHelp().utf8)) else {
            fatalError("MCP tool registry: ArgumentParser's help dump no longer decodes; update CLIArgument")
        }
        return dump.command.arguments ?? []
    }
}

/// One MCP tool, declared against the CLI command it runs. The command path
/// comes from the tool name (`MCPCommandPolicy.commandPath`), and each
/// property's JSON Schema and argv come from the CLI argument it binds to.
struct MCPToolSpec: Sendable {
    let name: String
    let effect: MCPTool.Effect
    let description: String
    var properties: [MCPProperty]
    /// Tokens always passed right after the command path (`--to-reminders`).
    var lead: [String] = []
    /// Tokens always passed after every property (`--draft`).
    var trail: [String] = []
    var inProcess: (@Sendable ([String]) async throws -> String)?

    init(
        _ name: String, _ effect: MCPTool.Effect, _ description: String,
        lead: [String] = [], trail: [String] = [],
        inProcess: (@Sendable ([String]) async throws -> String)? = nil,
        properties: [MCPProperty] = []
    ) {
        self.name = name
        self.effect = effect
        self.description = description
        self.lead = lead
        self.trail = trail
        self.inProcess = inProcess
        self.properties = properties
    }
}

/// One MCP input property and the CLI argument it sets.
struct MCPProperty: Sendable {
    /// The CLI argument: `--name` for an option or flag, or the command's
    /// positional, passed either in place (an id, refused when it starts with
    /// "-") or last after `--` (free text, which may start with "-").
    enum CLIRef: Sendable, ExpressibleByStringLiteral {
        case named(String)
        case positional
        case trailing

        init(stringLiteral value: String) {
            self = .named(value)
        }
    }

    /// The JSON type of an option whose value is a number. Everything else
    /// follows the argument kind: flag is boolean, repeating is an array of
    /// strings, the rest are strings.
    enum NumberType: String, Sendable {
        case integer, number
    }

    enum Emit: Sendable {
        case derived
        /// Set by another property's `custom` closure.
        case none
        case custom(@Sendable (JSONValue?) throws -> [String])
    }

    let name: String
    let cli: CLIRef?
    var numberType: NumberType?
    /// Overrides the CLI help text where the MCP wording differs.
    var description: String?
    /// Overrides the CLI's required-ness (MCP may require what the CLI leaves optional).
    var required: Bool?
    var defaultValue: JSONValue?
    /// A whole schema for a property no single CLI argument describes.
    var schema: JSONValue?
    var emit: Emit = .derived
    /// Pass before `--format agent` rather than after it.
    var leading = false

    /// A property bound to one CLI argument; everything not given is derived.
    static func arg(
        _ name: String, _ cli: CLIRef, _ description: String? = nil, as numberType: NumberType? = nil,
        required: Bool? = nil, default defaultValue: JSONValue? = nil, emit: Emit = .derived
    ) -> MCPProperty {
        MCPProperty(
            name: name, cli: cli, numberType: numberType, description: description,
            required: required, defaultValue: defaultValue, emit: emit
        )
    }

    /// A property no single CLI argument describes, so its schema is written
    /// out: the gates and the bindings `CLIMCPDriftTests.specialBindings` lists.
    static func special(
        _ name: String, schema: JSONValue, required: Bool = false, leading: Bool = false, emit: Emit
    ) -> MCPProperty {
        MCPProperty(name: name, cli: nil, required: required, schema: schema, emit: emit, leading: leading)
    }
}

extension MCPTool {
    /// Generate a tool from its spec and the ArgumentParser definition of the
    /// command it runs.
    init(_ spec: MCPToolSpec) {
        let path = MCPCommandPolicy.commandPath(for: spec.name)
        let cliArguments = CLIArgument.arguments(of: path)
        let resolved = spec.properties.map { ResolvedProperty($0, tool: spec.name, cliArguments: cliArguments) }
        let required = resolved.filter(\.required).map(\.property.name)
        let (lead, trail) = (spec.lead, spec.trail)
        self.init(
            name: spec.name,
            effect: spec.effect,
            description: spec.description,
            inputSchema: resolved.isEmpty
                ? Schema.empty
                : Schema.object(
                    properties: Dictionary(uniqueKeysWithValues: resolved.map { ($0.property.name, $0.schema) }),
                    required: required
                ),
            buildArgs: { args in
                var head = path + lead
                var body: [String] = []
                var tail: [String] = []
                for property in resolved {
                    let tokens = try property.argv(args)
                    if property.property.leading {
                        head += tokens
                    } else if case .trailing? = property.property.cli {
                        tail += tokens
                    } else {
                        body += tokens
                    }
                }
                // `--format agent` before any trailing `-- <positional>`.
                return head + ["--format", "agent"] + body + trail + tail
            },
            inProcess: spec.inProcess
        )
    }
}

/// A property joined to its CLI argument: the schema and argv builder the
/// registry serves.
private struct ResolvedProperty: Sendable {
    let property: MCPProperty
    let schema: JSONValue
    let required: Bool
    private let flag: String?
    private let kind: String?
    private let isRepeating: Bool
    /// `--name` / `--no-name` for a flag whose CLI default is on.
    private let isInversion: Bool

    init(_ property: MCPProperty, tool: String, cliArguments: [CLIArgument]) {
        self.property = property
        var flag: String?
        let argument: CLIArgument?
        switch property.cli {
        case let .named(name)?:
            flag = name
            argument = cliArguments.first { $0.longNames.contains(name) }
        case .positional?, .trailing?:
            argument = cliArguments.first { $0.kind == "positional" }
        case nil:
            argument = nil
        }
        if property.cli != nil, argument == nil {
            fatalError("MCP tool registry: \(tool).\(property.name) binds a CLI argument the command does not have")
        }
        let isInversion = argument?.kind == "flag" && flag != nil && argument?.defaultValue == flag
        self.flag = flag
        self.isInversion = isInversion
        kind = argument?.kind
        isRepeating = argument?.isRepeating ?? false
        required = property.required ?? (argument.map { !$0.isOptional } ?? false)
        schema = property.schema ?? Self.schema(for: property, argument: argument, isInversion: isInversion, tool: tool)
    }

    private static func schema(for property: MCPProperty, argument: CLIArgument?, isInversion: Bool, tool: String) -> JSONValue {
        guard let argument else { fatalError("MCP tool registry: \(tool).\(property.name) needs a schema") }
        guard let description = property.description ?? argument.abstract else {
            fatalError("MCP tool registry: \(tool).\(property.name) has no description and its CLI argument no help text")
        }
        var dict: [String: JSONValue] = ["description": .string(description)]
        let defaultValue: JSONValue?
        if argument.kind == "flag" {
            dict["type"] = .string("boolean")
            defaultValue = .bool(isInversion)
        } else if argument.isRepeating {
            dict["type"] = .string("array")
            dict["items"] = .object(["type": .string("string")])
            defaultValue = nil
        } else if let numberType = property.numberType {
            dict["type"] = .string(numberType.rawValue)
            defaultValue = argument.defaultValue.flatMap { text in
                numberType == .integer ? Int64(text).map(JSONValue.int) : Double(text).map(JSONValue.double)
            }
        } else {
            // A string option's CLI default (INBOX, this) is left to the help text.
            dict["type"] = .string("string")
            defaultValue = nil
            if let values = argument.allValues, !values.isEmpty {
                dict["enum"] = .array(values.map(JSONValue.string))
            }
        }
        dict["default"] = property.defaultValue ?? defaultValue
        return .object(dict)
    }

    func argv(_ args: JSONValue?) throws -> [String] {
        let name = property.name
        switch property.emit {
        case .none: return []
        case let .custom(build): return try build(args)
        case .derived: break
        }
        if kind == "flag", let flag {
            if isInversion {
                return ArgHelpers.bool(args, name).map { [$0 ? flag : "--no-" + flag.dropFirst(2)] } ?? []
            }
            return ArgHelpers.flagIfTrue(args, name, flagName: flag)
        }
        if isRepeating, let flag {
            guard let values = ArgHelpers.stringArray(args, name) else {
                if required { throw MCPToolArgError.missingRequired(name) }
                return []
            }
            return values.map { ArgHelpers.option(flag, $0) }
        }
        let value: String?
        switch property.numberType {
        case .integer?: value = ArgHelpers.int(args, name).map { String($0) }
        case .number?: value = ArgHelpers.double(args, name).map { String($0) }
        case nil: value = ArgHelpers.string(args, name)
        }
        guard let value else {
            if required { throw MCPToolArgError.missingRequired(name) }
            return []
        }
        switch property.cli {
        case let .named(flag)?: return [ArgHelpers.option(flag, value)]
        case .positional?: return try [ArgHelpers.notFlagLike(value, name)]
        case .trailing?: return ["--", value]
        case nil: return []
        }
    }
}
