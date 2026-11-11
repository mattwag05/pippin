import ArgumentParser
import Foundation

// MARK: - JobStatus

/// Lifecycle of a detached `pippin job`. Terminal states are `done`, `error`,
/// `killed` and `skipped` (a scheduled fire that found the previous one still
/// running; `error_code` is `overlap`). Once set, the status file is never overwritten except by `gc`.
/// A `running` job whose runner process is gone is rewritten on read as
/// `error` with `error_code: "runner_lost"` (see `JobStore.readCanonical`).
public enum JobStatus: String, Codable, Sendable, CaseIterable, ExpressibleByArgument {
    case running
    case done
    case error
    case killed
    case skipped

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
    /// Why a job is `error` when no exit code explains it (`runner_lost`), or
    /// `skipped` (`overlap`).
    public var errorCode: String?
    /// The `pippin job schedule` entry that fired this job, if any.
    public var scheduleId: String?

    /// Derived from `endedAt - startedAt`. Serialized as `duration_ms` on
    /// terminal states; nil while the job is still running.
    public var durationMs: Int? {
        guard let endedAt else { return nil }
        return Int(endedAt.timeIntervalSince(startedAt) * 1000)
    }

    enum CodingKeys: String, CodingKey {
        case v, id, argv, pid, status
        case exitCode = "exit_code"
        case errorCode = "error_code"
        case scheduleId = "schedule_id"
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
        scheduleId: String? = nil
    ) {
        v = 1
        self.id = id
        self.argv = argv
        self.pid = pid
        self.status = status
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.scheduleId = scheduleId
    }

    /// Record how the child ended. A signal death is `killed`, never `done`.
    public mutating func finish(
        exitStatus: Int32, reason: Process.TerminationReason, at date: Date = Date()
    ) {
        endedAt = date
        exitCode = exitStatus
        switch reason {
        case .exit: status = exitStatus == 0 ? .done : .error
        case .uncaughtSignal: status = .killed
        @unknown default: status = .error
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encode(id, forKey: .id)
        try container.encode(argv, forKey: .argv)
        try container.encodeIfPresent(pid, forKey: .pid)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(exitCode, forKey: .exitCode)
        try container.encodeIfPresent(errorCode, forKey: .errorCode)
        try container.encodeIfPresent(scheduleId, forKey: .scheduleId)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(endedAt, forKey: .endedAt)
        try container.encodeIfPresent(durationMs, forKey: .durationMs)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        id = try c.decode(String.self, forKey: .id)
        argv = try c.decode([String].self, forKey: .argv)
        pid = try c.decodeIfPresent(Int32.self, forKey: .pid)
        status = try c.decode(JobStatus.self, forKey: .status)
        exitCode = try c.decodeIfPresent(Int32.self, forKey: .exitCode)
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode)
        scheduleId = try c.decodeIfPresent(String.self, forKey: .scheduleId)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        // duration_ms is derived from endedAt; ignore any persisted value.
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
