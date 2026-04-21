import Foundation

// MARK: - JobStatus

/// Lifecycle of a detached `pippin job`. Terminal states are `done`, `error`,
/// `killed` — once set, the status file is never overwritten except by `gc`.
public enum JobStatus: String, Codable, Sendable {
    case running
    case done
    case error
    case killed

    public var isTerminal: Bool {
        self != .running
    }
}

// MARK: - Job

/// On-disk state for a single detached job. Mirrors `status.json` inside the
/// job's cache directory.
public struct Job: Codable, Sendable, Equatable {
    public let v: Int
    public let id: String
    public let argv: [String]
    public var pid: Int32?
    public var status: JobStatus
    public var exitCode: Int32?
    public let startedAt: Date
    public var endedAt: Date?
    public var durationMs: Int?

    enum CodingKeys: String, CodingKey {
        case v, id, argv, pid, status
        case exitCode = "exit_code"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationMs = "duration_ms"
    }

    public init(
        id: String,
        argv: [String],
        pid: Int32? = nil,
        status: JobStatus = .running,
        exitCode: Int32? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        durationMs: Int? = nil
    ) {
        v = 1
        self.id = id
        self.argv = argv
        self.pid = pid
        self.status = status
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMs = durationMs
    }
}

// MARK: - JobId

/// Short, sortable 16-hex-char ID. Millisecond timestamp prefix guarantees
/// chronological sort; 20-bit random suffix drives collision risk to ~1 in
/// 1M for same-ms spawns. Users can prefix-match (git-style) via JobStore.
public enum JobId {
    public static func generate() -> String {
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        let tsHex = String(format: "%011x", ms & 0x00FF_FFFF_FFFF)
        let rand = String(format: "%05x", UInt32.random(in: 0 ... 0xFFFFF))
        return "\(tsHex)\(rand)"
    }
}
