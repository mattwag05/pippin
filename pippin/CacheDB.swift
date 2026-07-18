import Foundation
import GRDB

/// Open a GRDB queue for a cache DB, creating its parent directory first.
/// Shared by the ~/.config/pippin cache stores (mail bodies, transcripts,
/// embeddings, contact index).
func openCacheQueue(path: String) throws -> DatabaseQueue {
    let dir = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return try DatabaseQueue(path: path)
}
