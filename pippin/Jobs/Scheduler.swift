import ArgumentParser
import Foundation

// MARK: - Errors

public enum ScheduleError: LocalizedError, RemediableError {
    case notFound(String)
    case launchctlFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .notFound(id): return "No schedule '\(id)' in the LaunchAgents directory."
        case let .launchctlFailed(detail): return "launchctl refused the schedule: \(detail)"
        case let .writeFailed(detail): return "Could not write the schedule: \(detail)"
        }
    }

    public var agentCode: String {
        switch self {
        case .notFound: return "schedule_not_found"
        case .launchctlFailed: return "launchctl_failed"
        case .writeFailed: return "schedule_write_failed"
        }
    }

    public var nextStep: NextStep {
        switch self {
        case .notFound: return .call(tool: "job_schedules", argv: ["job", "schedules"])
        case .launchctlFailed, .writeFailed: return .none
        }
    }
}

// MARK: - Trigger

/// When a schedule fires: a fixed interval, or a cron-style calendar match.
public enum ScheduleTrigger: Equatable {
    case every(seconds: Int)
    /// The original five-field expression plus its launchd translation.
    case cron(String, [[String: Int]])

    /// `15m`, `6h`, `1d`. launchd would run anything shorter than a minute hot.
    static func parseEvery(_ input: String) throws -> ScheduleTrigger {
        let seconds = try parseDuration(input)
        guard seconds >= 60 else {
            throw ValidationError("--every must be at least 1m (got '\(input)').")
        }
        return .every(seconds: seconds)
    }

    /// Five fields: minute hour day-of-month month day-of-week. Each is `*`,
    /// a number or a comma list of numbers. Ranges and steps have no direct
    /// launchd form, so they are refused rather than translated wrongly.
    static func parseCron(_ input: String) throws -> ScheduleTrigger {
        let fields = input.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 5 else {
            throw ValidationError("--cron needs 5 fields (minute hour day-of-month month day-of-week), got \(fields.count) in '\(input)'.")
        }
        let spec: [(key: String, range: ClosedRange<Int>)] = [
            ("Minute", 0 ... 59), ("Hour", 0 ... 23), ("Day", 1 ... 31), ("Month", 1 ... 12), ("Weekday", 0 ... 7),
        ]
        var dicts: [[String: Int]] = [[:]]
        for (field, (key, range)) in zip(fields, spec) {
            if field == "*" { continue }
            if field.contains("-") || field.contains("/") {
                throw ValidationError("--cron field '\(field)': ranges (a-b) and steps (*/n) are not supported; use a number, '*' or a comma list like 0,15,30,45.")
            }
            let values = try field.split(separator: ",", omittingEmptySubsequences: false).map { part -> Int in
                guard let n = Int(part), range.contains(n) else {
                    throw ValidationError("--cron \(key.lowercased()) '\(part)' must be a number from \(range.lowerBound) to \(range.upperBound).")
                }
                return n
            }
            dicts = dicts.flatMap { base in Set(values).sorted().map { base.merging([key: $0]) { $1 } } }
        }
        return .cron(fields.joined(separator: " "), dicts)
    }

    var description: String {
        switch self {
        case let .every(seconds):
            if seconds % 86400 == 0 { return "every \(seconds / 86400)d" }
            if seconds % 3600 == 0 { return "every \(seconds / 3600)h" }
            if seconds % 60 == 0 { return "every \(seconds / 60)m" }
            return "every \(seconds)s"
        case let .cron(expr, _): return "cron \(expr)"
        }
    }
}

// MARK: - launchctl

/// Every launchctl call goes through here so tests never touch launchd.
public struct Launchctl: Sendable {
    /// Runs `launchctl <args>`; returns exit status and combined output.
    public var run: @Sendable ([String]) -> (status: Int32, output: String)

    public init(run: @escaping @Sendable ([String]) -> (status: Int32, output: String)) {
        self.run = run
    }

    public static let system = Launchctl { args in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Store

public struct ScheduleInfo: Encodable, Sendable, Equatable {
    public let id: String
    public let argv: [String]
    public let trigger: String
    public let lastRun: Date?
    public let lastStatus: JobStatus?

    enum CodingKeys: String, CodingKey {
        case id, argv, trigger
        case lastRun = "last_run"
        case lastStatus = "last_status"
    }
}

/// One LaunchAgent plist per schedule; launchd holds all the state. A plist is
/// ours when its label is `labelPrefix + id`.
public struct ScheduleStore {
    public static let labelPrefix = "com.mattwag05.pippin.schedule."
    private static let cronKey = "PippinCron"

    public let directory: String
    public let launchctl: Launchctl
    public let uid: uid_t

    public init(directory: String? = nil, launchctl: Launchctl = .system, uid: uid_t = getuid()) {
        self.directory = directory
            ?? ProcessInfo.processInfo.environment["PIPPIN_LAUNCHAGENTS_DIR"]
            ?? NSHomeDirectory() + "/Library/LaunchAgents"
        self.launchctl = launchctl
        self.uid = uid
    }

    static func label(_ id: String) -> String {
        labelPrefix + id
    }

    func plistPath(_ id: String) -> String {
        "\(directory)/\(Self.label(id)).plist"
    }

    static func plist(id: String, trigger: ScheduleTrigger, argv: [String], pippinPath: String, logPath: String) -> [String: Any] {
        var plist: [String: Any] = [
            "Label": label(id),
            "ProgramArguments": [pippinPath, "job", "run", "--wait", "--schedule-id", id, "--"] + argv,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
        switch trigger {
        case let .every(seconds):
            plist["StartInterval"] = seconds
        case let .cron(expr, dicts):
            plist["StartCalendarInterval"] = dicts
            plist[cronKey] = expr
        }
        return plist
    }

    @discardableResult
    public func add(trigger: ScheduleTrigger, argv: [String], pippinPath: String) throws -> String {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let log = (JobStore.defaultRoot as NSString).deletingLastPathComponent + "/schedule-\(id).log"
        let body = Self.plist(id: id, trigger: trigger, argv: argv, pippinPath: pippinPath, logPath: log)
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
            try PrivateFile.writeAtomically(data, to: plistPath(id))
        } catch {
            throw ScheduleError.writeFailed(error.localizedDescription)
        }
        let result = launchctl.run(["bootstrap", "gui/\(uid)", plistPath(id)])
        guard result.status == 0 else {
            try? FileManager.default.removeItem(atPath: plistPath(id))
            throw ScheduleError.launchctlFailed(result.output)
        }
        return id
    }

    public func remove(_ id: String) throws {
        guard FileManager.default.fileExists(atPath: plistPath(id)) else { throw ScheduleError.notFound(id) }
        // A bootout failure usually means the agent was not loaded (logged out, rebooted): still delete the file.
        _ = launchctl.run(["bootout", "gui/\(uid)/\(Self.label(id))"])
        try? FileManager.default.removeItem(atPath: plistPath(id))
    }

    public func list(jobs: [Job]) -> [ScheduleInfo] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasPrefix(Self.labelPrefix) && $0.hasSuffix(".plist") }.sorted().compactMap { name in
            guard
                let dict = NSDictionary(contentsOfFile: "\(directory)/\(name)") as? [String: Any],
                let args = dict["ProgramArguments"] as? [String],
                let label = dict["Label"] as? String, label.hasPrefix(Self.labelPrefix)
            else { return nil }
            let id = String(label.dropFirst(Self.labelPrefix.count))
            let trigger: ScheduleTrigger
            if let seconds = dict["StartInterval"] as? Int {
                trigger = .every(seconds: seconds)
            } else {
                trigger = .cron((dict[Self.cronKey] as? String) ?? "?", [])
            }
            let last = jobs.filter { $0.scheduleId == id }.max { $0.startedAt < $1.startedAt }
            return ScheduleInfo(
                id: id,
                argv: args.firstIndex(of: "--").map { Array(args[($0 + 1)...]) } ?? [],
                trigger: trigger.description,
                lastRun: last?.startedAt,
                lastStatus: last?.status
            )
        }
    }
}
