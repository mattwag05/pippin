import Foundation

/// Run a synchronous, thread-blocking operation off the cooperative thread
/// pool by hopping to a detached `Task`. Use at boundaries where an `async`
/// command invokes sync bridge code that internally calls
/// `process.waitUntilExit()`, `DispatchSemaphore.wait()`, or
/// `URLSession.sendSynchronousRequest`. Without this hop those waits stall
/// a Swift cooperative thread for seconds-to-minutes under any concurrent
/// usage (notably `pippin mcp-server`, which fans out commands per-connection).
///
/// `priority: .userInitiated` matches every existing call site — these are
/// CLI commands the user is actively waiting on. Override per-call when the
/// work is genuinely background.
@inlinable
public func detachBlocking<T: Sendable>(
    priority: TaskPriority = .userInitiated,
    _ body: @Sendable @escaping () throws -> T
) async throws -> T {
    try await Task.detached(priority: priority, operation: body).value
}

/// Non-throwing overload. Picks up `runAllChecks()`-style callers that
/// would otherwise force callers to write `try await detachBlocking { ... }`
/// for non-throwing work.
@inlinable
public func detachBlocking<T: Sendable>(
    priority: TaskPriority = .userInitiated,
    _ body: @Sendable @escaping () -> T
) async -> T {
    await Task.detached(priority: priority, operation: body).value
}
