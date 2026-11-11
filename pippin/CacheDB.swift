import Foundation
import GRDB

/// Open a GRDB queue for a cache DB, creating its parent directory first.
/// Shared by the ~/.config/pippin cache stores (mail bodies, transcripts,
/// embeddings, contact index).
func openCacheQueue(path: String) throws -> DatabaseQueue {
    let dir = (path as NSString).deletingLastPathComponent
    try PrivateFile.ensureDirectory(dir)
    var config = Configuration()
    // A background fill writes while other commands read the same store.
    config.busyMode = .timeout(5)
    config.prepareDatabase { db in
        try db.execute(sql: "PRAGMA journal_mode = WAL")
    }
    let queue = try DatabaseQueue(path: path, configuration: config)
    // Cache rows hold mail and note text: owner-only, WAL sidecars included.
    for suffix in ["", "-wal", "-shm"] {
        PrivateFile.restrict(path + suffix)
    }
    return queue
}
