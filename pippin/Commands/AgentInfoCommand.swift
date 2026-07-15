import ArgumentParser
import Foundation

/// Machine-readable description of pippin's agent contract: version, output
/// formats, the typed exit-code map, global flags, experimental gating, and the
/// MCP tool count. An orchestrating agent calls this once to learn what it can
/// rely on, instead of scraping `--help` or hard-coding assumptions.
///
/// Complements `pippin mcp-server --list-tools` (which enumerates the MCP tool
/// surface in detail); this is the lightweight "who are you and what's your
/// contract" probe.
public struct AgentInfo: Codable, Sendable {
    public struct ExitCodeEntry: Codable, Sendable {
        public let code: Int
        public let meaning: String
        public let retryable: Bool
    }

    public let name: String
    public let version: String
    public let tagline: String
    public let schemaVersion: Int
    public let formats: [String]
    public let exitCodes: [ExitCodeEntry]
    public let globalFlags: [String]
    public let experimentalEnabled: Bool
    public let mcp: MCPInfo
    public let commands: [String]

    public struct MCPInfo: Codable, Sendable {
        public let toolCount: Int

        enum CodingKeys: String, CodingKey {
            case toolCount = "tool_count"
        }
    }

    enum CodingKeys: String, CodingKey {
        case name, version, tagline
        case schemaVersion = "schema_version"
        case formats
        case exitCodes = "exit_codes"
        case globalFlags = "global_flags"
        case experimentalEnabled = "experimental_enabled"
        case mcp, commands
    }
}

public struct AgentInfoCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "agent-info",
        abstract: "Describe pippin's agent contract: version, formats, exit codes, tool count.",
        discussion: """
        A single discovery handshake for orchestrating agents. Use \
        `--format agent` (or `json`) for the structured contract; the text view \
        is a human-readable summary. Complements `pippin mcp-server --list-tools`.
        """
    )

    /// Injected by the entry point so the command list stays in lockstep with
    /// the root command's registered subcommands (no drift, no duplication).
    /// The entry point computes this once at startup (on the main actor) and
    /// stores the resolved names; reading a plain array here avoids crossing an
    /// executor boundary to touch each subcommand's `configuration`.
    public nonisolated(unsafe) static var commandNames: [String] = []

    @OptionGroup public var output: OutputOptions

    public init() {}

    public mutating func run() async throws {
        let info = AgentInfo(
            name: "pippin",
            version: PippinVersion.version,
            tagline: PippinVersion.tagline,
            schemaVersion: AGENT_SCHEMA_VERSION,
            formats: OutputFormat.allCases.map(\.rawValue),
            exitCodes: Self.exitCodeCatalog,
            globalFlags: ["--format", "--fields"],
            experimentalEnabled: ProcessInfo.processInfo.environment["PIPPIN_EXPERIMENTAL"] == "1",
            mcp: AgentInfo.MCPInfo(toolCount: MCPToolRegistry.tools.count),
            commands: Self.commandNames.sorted()
        )

        if output.isAgent {
            try output.printAgent(info)
        } else if output.isJSON {
            try printJSON(info)
        } else {
            printText(info)
        }
    }

    /// The documented exit-code map, mirroring `PippinExitCode`. Kept here as
    /// data so the probe can advertise it; the actual routing lives in
    /// `PippinExitCode.classify`.
    static let exitCodeCatalog: [AgentInfo.ExitCodeEntry] = [
        .init(code: 0, meaning: "success", retryable: false),
        .init(code: 2, meaning: "usage / bad input", retryable: false),
        .init(code: 3, meaning: "resource not found", retryable: false),
        .init(code: 4, meaning: "auth / permission / config", retryable: false),
        .init(code: 5, meaning: "tool / bridge failure", retryable: false),
        .init(code: 7, meaning: "timeout / rate-limit", retryable: true),
        .init(code: 64, meaning: "argument-parse failure (unknown subcommand/flag; ArgumentParser EX_USAGE)", retryable: false),
    ]

    private func printText(_ info: AgentInfo) {
        print("\(info.name) \(info.version) — \(info.tagline)")
        print("schema version: \(info.schemaVersion)")
        print("formats: \(info.formats.joined(separator: ", "))")
        print("global flags: \(info.globalFlags.joined(separator: ", "))")
        print("experimental: \(info.experimentalEnabled ? "enabled" : "disabled")")
        print("mcp tools: \(info.mcp.toolCount)")
        if !info.commands.isEmpty {
            print("commands: \(info.commands.joined(separator: ", "))")
        }
        print("exit codes:")
        for entry in info.exitCodes {
            let retry = entry.retryable ? " (retryable)" : ""
            print("  \(entry.code)  \(entry.meaning)\(retry)")
        }
    }
}
