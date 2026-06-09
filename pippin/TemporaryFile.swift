import Foundation

/// Build a unique URL under the system temporary directory. The file is **not**
/// created — the caller writes to it. Use this directly only when the URL must
/// outlive the call (e.g. it's returned for the caller to own and clean up);
/// otherwise prefer `withTemporaryFile`, which cleans up automatically.
public func temporaryFileURL(prefix: String, extension ext: String = "") -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)\(UUID().uuidString)")
    return ext.isEmpty ? url : url.appendingPathExtension(ext)
}

/// Run `body` with a unique temporary file URL, removing the file afterward
/// whether `body` returns or throws. The file is not pre-created — `body` writes
/// to it. Centralizes the `temporaryDirectory + UUID + defer cleanup` pattern
/// that the audio/browser bridges previously hand-rolled.
@discardableResult
public func withTemporaryFile<T>(
    prefix: String,
    extension ext: String = "",
    _ body: (URL) throws -> T
) rethrows -> T {
    let url = temporaryFileURL(prefix: prefix, extension: ext)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}
