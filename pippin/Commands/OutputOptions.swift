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
    /// `duration_ms` from `startedAt`. Pass non-empty `warnings` to surface
    /// non-fatal advisories alongside the payload.
    public func printAgent(_ payload: some Encodable, warnings: [String]? = nil) throws {
        try printAgentJSON(payload, startedAt: startedAt, warnings: warnings)
    }

    /// Render `payload` in the configured format, surfacing a soft-timeout
    /// advisory when `timedOut == true`:
    /// - JSON: writes `payload` unchanged + a stderr `Warning:` line.
    /// - Agent: passes `[hint]` as `warnings` in the envelope. Stderr stays
    ///   silent — the MCP server captures child stderr and a duplicate line
    ///   would be double-noise alongside the structured warning.
    /// - Text: stderr `Warning:` line + caller's `renderText` closure +
    ///   trailing `(partial results — <hint>)` trailer.
    public func emit<T: Encodable>(
        _ payload: T,
        timedOut: Bool = false,
        timedOutHint: String,
        renderText: () -> Void
    ) throws {
        if timedOut, !isAgent {
            FileHandle.standardError.write(Data("Warning: \(timedOutHint)\n".utf8))
        }
        if isJSON {
            try printJSON(payload)
        } else if isAgent {
            try printAgent(payload, warnings: timedOut ? [timedOutHint] : nil)
        } else {
            renderText()
            if timedOut {
                print("(partial results — \(timedOutHint))")
            }
        }
    }
}
