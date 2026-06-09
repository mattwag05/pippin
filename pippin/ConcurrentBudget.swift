import Foundation

/// A thread-safe box for collecting a value produced on a background thread.
/// `get()` returns `nil` until `set(_:)` runs, which lets a concurrent runner
/// distinguish "task finished" from "task still running past the deadline".
///
/// `@unchecked Sendable`: every access is serialized by the internal lock.
public final class ConcurrentSlot<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    public init() {}

    public func set(_ value: T) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    public func get() -> T? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Runs `tasks` concurrently on background threads, returning once they all
/// finish OR `budgetMs` elapses — whichever comes first.
///
/// Stragglers are **not** cancelled: the blocking bridge work behind a status
/// gather (osascript subprocess waits, `DispatchSemaphore.wait`, EventKit) is
/// not cooperatively cancellable, so a `TaskGroup` would have to await it
/// anyway. Instead the runner stops *waiting* at the deadline; the abandoned
/// task keeps running until its own internal hard cap reaps it, writing into a
/// `ConcurrentSlot` nobody reads. `budgetMs <= 0` waits indefinitely (CLI).
///
/// Returns `true` if every task completed within the budget, `false` if the
/// deadline fired first. Pair with `ConcurrentSlot`s to read which individual
/// tasks finished (slot set) vs. were abandoned (slot still `nil`).
@discardableResult
public func runConcurrentlyWithBudget(
    budgetMs: Int,
    _ tasks: [@Sendable () -> Void]
) -> Bool {
    let group = DispatchGroup()
    let queue = DispatchQueue.global(qos: .userInitiated)
    for task in tasks {
        queue.async(group: group, execute: task)
    }
    guard budgetMs > 0 else {
        group.wait()
        return true
    }
    return group.wait(timeout: .now() + .milliseconds(budgetMs)) == .success
}
