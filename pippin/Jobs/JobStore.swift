import Foundation

// MARK: - JobStoreError

public enum JobStoreError: LocalizedError, Sendable {
    case rootCreationFailed(String)
    case jobNotFound(String)
    case ambiguousPrefix(String, matches: [String])
    case statusReadFailed(String)
    case statusWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .rootCreationFailed(path):
            return "Could not create job cache directory at \(path)."
        case let .jobNotFound(id):
            return "No job found matching '\(id)'."
        case let .ambiguousPrefix(id, matches):
            return "Prefix '\(id)' matches \(matches.count) jobs: \(matches.joined(separator: ", ")). Use a longer prefix."
        case let .statusReadFailed(detail):
            return "Could not read job status: \(detail)"
        case let .statusWriteFailed(detail):
            return "Could not write job status: \(detail)"
        }
    }
}

// MARK: - JobStore

/// Filesystem-backed job registry under `~/.cache/pippin/jobs/<id>/`.
/// One directory per job: `status.json` + `stdout.log` + `stderr.log`.
/// Safe for concurrent readers; writers must use `write(...)` which renames
/// atomically so an interrupted write can never leave a half-written file.
public final class JobStore: @unchecked Sendable {
    public static let defaultRoot: String = {
        let home = NSHomeDirectory()
        return "\(home)/.cache/pippin/jobs"
    }()

    public let root: String

    public init(root: String? = nil) {
        self.root = root ?? JobStore.defaultRoot
    }

    // MARK: Paths

    public func jobDir(_ id: String) -> String {
        "\(root)/\(id)"
    }

    public func statusPath(_ id: String) -> String {
        "\(jobDir(id))/status.json"
    }

    public func stdoutPath(_ id: String) -> String {
        "\(jobDir(id))/stdout.log"
    }

    public func stderrPath(_ id: String) -> String {
        "\(jobDir(id))/stderr.log"
    }

    // MARK: Lifecycle

    /// Create the job dir and empty log files. Returns the absolute dir path.
    @discardableResult
    public func createDir(_ id: String) throws -> String {
        let dir = jobDir(id)
        do {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true
            )
        } catch {
            throw JobStoreError.rootCreationFailed(dir)
        }
        FileManager.default.createFile(atPath: stdoutPath(id), contents: nil)
        FileManager.default.createFile(atPath: stderrPath(id), contents: nil)
        return dir
    }

    public func write(_ job: Job) throws {
        let path = statusPath(job.id)
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(job)
        } catch {
            throw JobStoreError.statusWriteFailed(error.localizedDescription)
        }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw JobStoreError.statusWriteFailed(error.localizedDescription)
        }
    }

    public func read(_ id: String) throws -> Job {
        let resolved = try resolve(id)
        let path = statusPath(resolved)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw JobStoreError.statusReadFailed("no status.json at \(path)")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Job.self, from: data)
        } catch {
            throw JobStoreError.statusReadFailed(error.localizedDescription)
        }
    }

    /// Resolve a full id or prefix to a canonical id. Prefix matches must be
    /// unambiguous — otherwise `ambiguousPrefix` is thrown.
    public func resolve(_ idOrPrefix: String) throws -> String {
        let ids = listIds()
        if ids.contains(idOrPrefix) { return idOrPrefix }
        let matches = ids.filter { $0.hasPrefix(idOrPrefix) }
        if matches.isEmpty { throw JobStoreError.jobNotFound(idOrPrefix) }
        if matches.count == 1 { return matches[0] }
        throw JobStoreError.ambiguousPrefix(idOrPrefix, matches: matches.sorted())
    }

    /// All job ids on disk, sorted by id (ascending — ID prefix encodes
    /// start time so this is chronological).
    public func listIds() -> [String] {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(atPath: root)
        else {
            return []
        }
        return entries
            .filter { FileManager.default.fileExists(atPath: "\(root)/\($0)/status.json") }
            .sorted()
    }

    /// Load every job, silently skipping any whose status.json is malformed
    /// (likely mid-rename from a concurrent writer — caller will see it on
    /// the next invocation).
    public func all() -> [Job] {
        listIds().compactMap { try? read($0) }
    }

    // MARK: Log tails

    public func tailStdout(_ id: String, maxBytes: Int = 4096) -> String {
        tailFile(stdoutPath(id), maxBytes: maxBytes)
    }

    public func tailStderr(_ id: String, maxBytes: Int = 4096) -> String {
        tailFile(stderrPath(id), maxBytes: maxBytes)
    }

    private func tailFile(_ path: String, maxBytes: Int) -> String {
        guard
            let handle = FileHandle(forReadingAtPath: path)
        else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: GC

    /// Remove job dirs whose `ended_at` is older than `cutoff`. Returns the
    /// ids removed. Running jobs are never pruned, even if their `started_at`
    /// predates the cutoff — they're still live.
    @discardableResult
    public func gc(olderThan cutoff: Date) throws -> [String] {
        var removed: [String] = []
        for job in all() {
            guard let ended = job.endedAt, job.status.isTerminal else { continue }
            if ended < cutoff {
                let dir = jobDir(job.id)
                try? FileManager.default.removeItem(atPath: dir)
                removed.append(job.id)
            }
        }
        return removed
    }
}
