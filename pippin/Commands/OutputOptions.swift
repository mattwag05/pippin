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

    @Option(name: .long, help: "Comma-separated JSON field names to include in each row (e.g. id,title).")
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

    /// Print `payload` as a compact agent-mode envelope, computing
    /// `duration_ms` from `startedAt`. Pass non-empty `warnings` to surface
    /// non-fatal advisories alongside the payload.
    ///
    /// Field projection defaults to the parsed `--fields` (`self.fields`), so
    /// EVERY call site honors `--fields` without threading it — an explicit
    /// `fields:` argument still overrides. When the effective list is non-empty
    /// the payload's `data` is projected to just those top-level keys.
    public func printAgent(
        _ payload: some Encodable,
        warnings: [String]? = nil,
        fields: [String]? = nil,
        partial: Bool = false,
        nextCursor: String? = nil
    ) throws {
        let effectiveFields = fields ?? FieldProjection.parse(self.fields)
        if let effectiveFields, !effectiveFields.isEmpty {
            try printAgentProjectedJSON(
                payload, fields: effectiveFields, startedAt: startedAt,
                warnings: warnings, partial: partial, nextCursor: nextCursor
            )
        } else {
            try printAgentJSON(
                payload, startedAt: startedAt, warnings: warnings,
                partial: partial, nextCursor: nextCursor
            )
        }
    }

    /// Agent-mode print for a paginated payload (envelope v3, pippin-37az).
    ///
    /// Emits `page.items` as `data` and hoists the cursor to the envelope's
    /// top-level `next_cursor`, so `data` is the same array type whether or not
    /// a pagination flag was passed. Paginated commands MUST route through this
    /// (or `emitPage`) rather than handing a `Page` to `printAgent`, which would
    /// re-nest `{items, next_cursor}` inside `data` — the exact v2 bug. Named
    /// distinctly rather than overloaded so a paginated call site is greppable
    /// and can't be resolved back to the unpaginated path by accident.
    public func printAgentPage<T: Encodable>(
        _ page: Page<T>,
        warnings: [String]? = nil,
        fields: [String]? = nil,
        partial: Bool = false
    ) throws {
        try printAgent(
            page.items, warnings: warnings, fields: fields,
            partial: partial, nextCursor: page.nextCursor
        )
    }

    /// Render `payload`, surfacing a soft-timeout advisory when
    /// `timedOut == true`: `[hint]` joins `warnings` and the envelope is marked
    /// `partial: true` so callers can tell an unfinished scan from a clean
    /// empty result. Stderr stays silent — the MCP server captures child
    /// stderr and a duplicate line would be double-noise alongside the
    /// structured warning.
    ///
    /// `extraWarnings` are advisories independent of the soft timeout (e.g.
    /// "fast path unavailable, fell back to JXA").
    ///
    /// Field projection defaults to the parsed `--fields` (`self.fields`) — an
    /// explicit `fields:` argument overrides it.
    public func emit<T: Encodable>(
        _ payload: T,
        timedOut: Bool = false,
        timedOutHint: String,
        fields: [String]? = nil,
        extraWarnings: [String] = []
    ) throws {
        let warnings = (timedOut ? [timedOutHint] : []) + extraWarnings
        try printAgent(
            payload, warnings: warnings.isEmpty ? nil : warnings,
            fields: fields ?? FieldProjection.parse(self.fields), partial: timedOut
        )
    }

    /// `emit` for a paginated payload (envelope v3, pippin-37az): array `data`
    /// plus top-level `next_cursor`.
    public func emitPage<T: Encodable>(
        _ page: Page<T>,
        timedOut: Bool = false,
        timedOutHint: String,
        fields: [String]? = nil,
        extraWarnings: [String] = []
    ) throws {
        let warnings = (timedOut ? [timedOutHint] : []) + extraWarnings
        try printAgentPage(
            page,
            warnings: warnings.isEmpty ? nil : warnings,
            fields: fields ?? FieldProjection.parse(self.fields),
            partial: timedOut
        )
    }
}
