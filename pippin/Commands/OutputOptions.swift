import ArgumentParser
import Foundation

/// The only output contract: the versioned agent envelope. `text` and `json`
/// were removed (pippin-xg3z); `--format agent` is still accepted so existing
/// callers keep working.
public enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
    case agent

    /// `--format` parser that names the replacement instead of ArgumentParser's
    /// generic "invalid value" when a removed format is passed.
    static func parse(_ raw: String) throws -> OutputFormat {
        if let format = OutputFormat(rawValue: raw) { return format }
        throw ValidationError(
            "--format \(raw) was removed; pippin only emits the compact JSON agent envelope. Drop the flag or pass --format agent."
        )
    }
}

public struct OutputOptions: ParsableArguments {
    @Option(name: .long, help: "Output format. Only `agent` (compact JSON envelope) exists; accepted for compatibility.", transform: OutputFormat.parse)
    public var format: OutputFormat = .agent

    @Option(name: .long, help: "Comma-separated JSON field names to include in each row (e.g. id,title), or `all`. List commands default to essential fields.")
    public var fields: String?

    /// Wall-clock time when this option group was constructed (during
    /// ArgumentParser's `parse()`). Threaded into agent-mode envelopes as
    /// `duration_ms`.
    public let startedAt: Date = .init()

    /// `format` and `fields` are parsed arguments. `startedAt` is initialized
    /// from its default expression and must be excluded from Codable synthesis.
    private enum CodingKeys: String, CodingKey {
        case format
        case fields
    }

    public init() {}

    /// The envelope for `result`. Field projection defaults to the parsed
    /// `--fields`, so every command honors it without threading it; an explicit
    /// `result.fields` overrides. With neither, array rows trim to their
    /// essential fields, and `--fields all` turns that off. `duration_ms` runs
    /// from `startedAt`.
    public func render(_ result: AgentResult) throws -> String {
        let requested = result.fields ?? FieldProjection.parse(fields)
        let effectiveFields = requested == [FieldProjection.all] ? nil : requested ?? result.defaultFields
        if let effectiveFields, !effectiveFields.isEmpty {
            var warnings = result.warnings ?? []
            if requested != nil {
                let missing = try FieldProjection.fieldsInNoRow(result.payload, fields: effectiveFields)
                if !missing.isEmpty {
                    warnings.append("No row has field(s): \(missing.joined(separator: ", ")).")
                }
            }
            return try projectedAgentJSON(
                result.payload, fields: effectiveFields, startedAt: startedAt,
                warnings: warnings.isEmpty ? nil : warnings, partial: result.partial, nextCursor: result.nextCursor
            )
        }
        return try agentJSON(
            result.payload, startedAt: startedAt, warnings: result.warnings,
            partial: result.partial, nextCursor: result.nextCursor
        )
    }
}
