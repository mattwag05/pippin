import ArgumentParser
import Foundation

/// What a command answers with: the payload plus the envelope metadata that
/// goes beside it. Commands return this instead of printing, so the CLI and the
/// in-process MCP path render the same value (pippin-ql27).
///
/// `payload` is `any Encodable` because some commands vary their row type by
/// flag (`mail list`), so static typing stops at the bridges.
public struct AgentResult {
    let payload: any Encodable
    let warnings: [String]?
    /// Overrides the parsed `--fields` when non-nil.
    let fields: [String]?
    let partial: Bool
    let nextCursor: String?
    /// Process exit status after the envelope is written (`doctor` reports
    /// failed checks in a successful envelope but still exits 1).
    let exitCode: Int32
    /// Row keys kept when the caller did not ask for fields (pippin-w5j3).
    let defaultFields: [String]?

    public init(
        _ payload: some Encodable,
        warnings: [String]? = nil,
        fields: [String]? = nil,
        partial: Bool = false,
        nextCursor: String? = nil,
        exitCode: Int32 = 0,
        untrimmed: Bool = false
    ) {
        self.payload = payload
        self.warnings = warnings
        self.fields = fields
        self.partial = partial
        self.nextCursor = nextCursor
        self.exitCode = exitCode
        defaultFields = untrimmed ? nil : (payload as? EssentialRows)?.essentialFields
    }

    /// A paginated answer (envelope v3, pippin-37az): `data` stays the items
    /// array and the cursor sits beside it in `next_cursor`. Paginated commands
    /// MUST use this or `emitPage`; wrapping a `Page` directly re-nests
    /// `{items, next_cursor}` inside `data`, which `lint-paginated-emit` rejects.
    public static func page<T: Encodable>(
        _ page: Page<T>,
        warnings: [String]? = nil,
        fields: [String]? = nil,
        partial: Bool = false
    ) -> AgentResult {
        AgentResult(page.items, warnings: warnings, fields: fields, partial: partial, nextCursor: page.nextCursor)
    }

    /// A scan result: a soft timeout adds `timedOutHint` to `warnings` and marks
    /// the envelope `partial`, so callers can tell an unfinished scan from a
    /// clean empty result. `extraWarnings` are advisories independent of the
    /// timeout (e.g. "fast path unavailable, fell back to JXA").
    public static func emit(
        _ payload: some Encodable,
        timedOut: Bool = false,
        timedOutHint: String,
        fields: [String]? = nil,
        extraWarnings: [String] = []
    ) -> AgentResult {
        let warnings = (timedOut ? [timedOutHint] : []) + extraWarnings
        return AgentResult(payload, warnings: warnings.isEmpty ? nil : warnings, fields: fields, partial: timedOut)
    }

    /// `emit` for a paginated payload.
    public static func emitPage<T: Encodable>(
        _ page: Page<T>,
        timedOut: Bool = false,
        timedOutHint: String,
        fields: [String]? = nil,
        extraWarnings: [String] = []
    ) -> AgentResult {
        let warnings = (timedOut ? [timedOutHint] : []) + extraWarnings
        return .page(page, warnings: warnings.isEmpty ? nil : warnings, fields: fields, partial: timedOut)
    }
}

/// A row type with a token-saving default projection, applied when a command
/// answers with an array of them. Single-object answers (`show`) stay whole.
public protocol EssentialRow {
    static var essentialFields: [String] { get }
}

protocol EssentialRows {
    var essentialFields: [String] { get }
}

extension Array: EssentialRows where Element: EssentialRow {
    var essentialFields: [String] { Element.essentialFields }
}

/// A command whose behavior is one call returning an `AgentResult`. `run()` is
/// the CLI client of `execute()`; the in-process MCP path is the other.
public protocol AgentCommand: AsyncParsableCommand {
    var output: OutputOptions { get }
    mutating func execute() async throws -> AgentResult
}

public extension AgentCommand {
    mutating func run() async throws {
        let result = try await execute()
        try print(output.render(result))
        if result.exitCode != 0 { throw ExitCode(result.exitCode) }
    }
}
