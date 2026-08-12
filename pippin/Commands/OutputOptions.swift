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

    @Option(name: .long, help: "Comma-separated JSON field names to include (e.g. id,title). JSON/agent output only.")
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

    /// Render `payload` in the configured format, surfacing a soft-timeout
    /// advisory when `timedOut == true`:
    /// - JSON: writes `payload` unchanged + a stderr `Warning:` line.
    /// - Agent: passes `[hint]` as `warnings` in the envelope and marks it
    ///   `partial: true` so callers can tell an unfinished scan from a clean
    ///   empty result. Stderr stays silent — the MCP server captures child
    ///   stderr and a duplicate line would be double-noise alongside the
    ///   structured warning.
    /// - Text: stderr `Warning:` line + caller's `renderText` closure +
    ///   trailing `(partial results — <hint>)` trailer.
    ///
    /// `extraWarnings` are advisories independent of the soft timeout (e.g.
    /// "fast path unavailable, fell back to JXA") — merged into the agent
    /// `warnings` array, printed as stderr `Warning:` lines in json/text.
    ///
    /// Field projection defaults to the parsed `--fields` (`self.fields`) — an
    /// explicit `fields:` argument overrides it. Projection applies in both json
    /// and agent modes; text rendering is unaffected.
    public func emit<T: Encodable>(
        _ payload: T,
        timedOut: Bool = false,
        timedOutHint: String,
        fields: [String]? = nil,
        extraWarnings: [String] = [],
        renderText: () -> Void
    ) throws {
        let effectiveFields = fields ?? FieldProjection.parse(self.fields)
        if !isAgent {
            if timedOut {
                FileHandle.standardError.write(Data("Warning: \(timedOutHint)\n".utf8))
            }
            for warning in extraWarnings {
                FileHandle.standardError.write(Data("Warning: \(warning)\n".utf8))
            }
        }
        if isJSON {
            if let effectiveFields, !effectiveFields.isEmpty {
                let projected = try FieldProjection.projectedObject(payload, fields: effectiveFields)
                let data = try JSONSerialization.data(withJSONObject: projected, options: [.prettyPrinted, .sortedKeys])
                print(String(data: data, encoding: .utf8)!)
            } else {
                try printJSON(payload)
            }
        } else if isAgent {
            let warnings = (timedOut ? [timedOutHint] : []) + extraWarnings
            try printAgent(payload, warnings: warnings.isEmpty ? nil : warnings, fields: effectiveFields, partial: timedOut)
        } else {
            renderText()
            if timedOut {
                print("(partial results — \(timedOutHint))")
            }
        }
    }

    /// `emit` for a paginated payload (envelope v3, pippin-37az).
    ///
    /// Agent mode unwraps the page (array `data` + top-level `next_cursor`);
    /// json and text keep rendering the `Page` itself, since neither has an
    /// envelope to hoist the cursor into — `--format json` writes the whole
    /// `{items, next_cursor}` document, which is where a cursor belongs there.
    public func emitPage<T: Encodable>(
        _ page: Page<T>,
        timedOut: Bool = false,
        timedOutHint: String,
        fields: [String]? = nil,
        extraWarnings: [String] = [],
        renderText: () -> Void
    ) throws {
        guard isAgent else {
            return try emit(
                page, timedOut: timedOut, timedOutHint: timedOutHint,
                fields: fields, extraWarnings: extraWarnings, renderText: renderText
            )
        }
        let warnings = (timedOut ? [timedOutHint] : []) + extraWarnings
        try printAgentPage(
            page,
            warnings: warnings.isEmpty ? nil : warnings,
            fields: fields ?? FieldProjection.parse(self.fields),
            partial: timedOut
        )
    }
}
