import ArgumentParser
import Foundation

public enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
    case text
    case json
    case agent
}

public struct OutputOptions: ParsableArguments {
    @Option(name: .long, help: "Output format: text (default), json, or agent (compact JSON for AI agents).")
    public var format: OutputFormat = .text

    /// Wall-clock time when this option group was constructed (during
    /// ArgumentParser's `parse()`). Threaded into agent-mode envelopes as
    /// `duration_ms`.
    public let startedAt: Date = .init()

    /// Only `format` is a parsed argument. `startedAt` is initialized from its
    /// default expression and must be excluded from Codable synthesis.
    private enum CodingKeys: String, CodingKey {
        case format
    }

    public init() {}

    public var isJSON: Bool {
        format == .json
    }

    public var isAgent: Bool {
        format == .agent
    }

    public var isStructured: Bool {
        isJSON || isAgent
    }

    /// Print `payload` as a compact agent-mode envelope, computing
    /// `duration_ms` from `startedAt`.
    public func printAgent(_ payload: some Encodable) throws {
        try printAgentJSON(payload, startedAt: startedAt)
    }
}
