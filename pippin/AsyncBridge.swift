import Foundation

/// Run async work from synchronous code and wait for it with a timeout.
///
/// The async body needs cooperative-pool threads to make progress (framework
/// continuations resume there), so the caller must not be one of many
/// pool threads blocked at once: concurrent callers hop with `runOffPool`
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

/// Run blocking sync work on a Dispatch thread and await it, keeping the
/// cooperative pool free. Unlike `detachBlocking` (a detached `Task`, which
/// still occupies a pool thread), this is safe when the work itself waits on
/// async work through `waitForAsync`, as Apple on-device transcription does.
/// Use it for task-group children that may transcribe concurrently.
func runOffPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result(catching: body))
        }
    }
}
