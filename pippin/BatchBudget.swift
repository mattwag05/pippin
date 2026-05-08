import Foundation

/// Wall-clock budget for parallel batch operations (memos export/transcribe,
/// future bulk command paths). Bounds the *whole* batch — distinct from the
/// per-call soft caps used by `MailBridge`/`NotesBridge` which bound a single
/// JXA invocation.
///
/// CLI mode is unbounded (the user can `kill` if they want to stop). MCP
/// mode caps at 50s so the JSON-RPC client sees a typed warning + partial
/// results instead of a SIGKILL halfway through chunk N.
public struct BatchBudget: Sendable {
    public let start: Date
    public let softTimeoutMs: Int

    public init(softTimeoutMs: Int) {
        start = Date()
        self.softTimeoutMs = softTimeoutMs
    }

    /// `true` once the elapsed time since `start` exceeds the budget. A
    /// budget of `0` is treated as "unlimited" — `exceeded` stays false.
    public var exceeded: Bool {
        guard softTimeoutMs > 0 else { return false }
        return Int(Date().timeIntervalSince(start) * 1000) > softTimeoutMs
    }

    /// Default budget for the current execution context. CLI: unlimited.
    /// MCP (`PIPPIN_MCP=1`): 50s, well under `MCPServerRuntime.defaultChildTimeoutSeconds`
    /// so partial output reaches the JSON-RPC client before runChild SIGKILLs us.
    public static func forCurrentContext() -> BatchBudget {
        BatchBudget(softTimeoutMs: isMCPContext() ? 50000 : 0)
    }
}
