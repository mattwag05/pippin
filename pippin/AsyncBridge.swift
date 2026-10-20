import Foundation

/// Run async work from synchronous code and wait for it with a timeout.
///
/// The async body needs cooperative-pool threads to make progress (framework
/// continuations resume there), so the caller must not be one of many
/// pool threads blocked at once: concurrent callers hop with `detachBlocking`
/// first. A single blocked pool thread is harmless.
func waitForAsync<T: Sendable>(
    timeoutSeconds: TimeInterval,
    _ body: @escaping @Sendable () async throws -> T
) throws -> T {
    let box = AsyncResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    let task = Task {
        do { box.result = try .success(await body()) } catch { box.result = .failure(error) }
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + timeoutSeconds) == .success else {
        task.cancel()
        throw AIProviderError.timeout
    }
    // The semaphore orders the write in the task before this read.
    return try box.result!.get()
}

/// Written once by the task before it signals; read after the wait.
private final class AsyncResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}
