import Foundation

/// Run a synchronous, thread-blocking operation off the cooperative thread
/// pool by hopping to a Dispatch thread. Use at boundaries where an `async`
/// command invokes sync bridge code that internally calls
/// `process.waitUntilExit()`, `DispatchSemaphore.wait()`, or
/// `URLSession.sendSynchronousRequest`. Without this hop those waits stall
/// a Swift cooperative thread for seconds-to-minutes under any concurrent
/// usage (notably `pippin mcp-server`, which fans out commands per-connection).
///
/// A detached `Task` is NOT enough: it still runs on the cooperative pool, so
/// enough concurrent callers block every pool thread, and work that waits on
/// async code through `waitForAsync` never finishes (pippin-vb4a).
public func detachBlocking<T: Sendable>(_ body: @Sendable @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result(catching: body))
        }
    }
}

/// Non-throwing overload, so non-throwing work needs no `try`.
public func detachBlocking<T: Sendable>(_ body: @Sendable @escaping () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: body())
        }
    }
}
