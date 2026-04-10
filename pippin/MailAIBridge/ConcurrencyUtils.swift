import Foundation

/// Dispatch `items` concurrently, collecting results in original order.
///
/// - Parameters:
///   - items: The inputs to process.
///   - maxConcurrent: Maximum number of in-flight tasks. Pass `nil` for unlimited.
///   - transform: Work to perform for each item. Throwing discards that item's result
///     when `failFast` is false, or aborts the remaining work when `failFast` is true.
///   - failFast: When true, the first error aborts remaining work and is re-thrown.
///     When false (default), errors are silently ignored and only successful results are returned.
/// - Returns: Results in the same order as `items` (minus any that threw when `failFast` is false).
public func runConcurrently<Input, Output>(
    _ items: [Input],
    maxConcurrent: Int? = nil,
    failFast: Bool = false,
    transform: @Sendable @escaping (Input) throws -> Output
) throws -> [Output] {
    guard !items.isEmpty else { return [] }

    nonisolated(unsafe) var results: [(index: Int, value: Output)] = []
    nonisolated(unsafe) var firstError: Error?

    let group = DispatchGroup()
    let lock = NSLock()
    let rateLimiter: DispatchSemaphore? = maxConcurrent.map { DispatchSemaphore(value: $0) }

    for (i, item) in items.enumerated() {
        if failFast, lock.withLock({ firstError != nil }) { break }

        rateLimiter?.wait()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                rateLimiter?.signal()
                group.leave()
            }
            do {
                let value = try transform(item)
                lock.withLock { results.append((index: i, value: value)) }
            } catch {
                if failFast {
                    lock.withLock { if firstError == nil { firstError = error } }
                }
                // When not failFast, silently drop this item
            }
        }
    }

    group.wait()

    if let error = firstError {
        throw error
    }

    return results.sorted { $0.index < $1.index }.map(\.value)
}
