import CryptoKit
import Foundation

/// The one way pippin appends a line to a log: `O_APPEND` so concurrent
/// processes cannot interleave or overwrite, mode 0600 because the lines name
/// recipients and targets. Shared by the action log and the Messages audit log.
enum AppendOnlyFile {
    static func append(_ data: Data, to path: String) throws {
        try PrivateFile.ensureDirectory((path as NSString).deletingLastPathComponent)
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
        }
        fchmod(fd, 0o600) // tighten a log created 0644 by an earlier version
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }
}

/// Replace `path` with `data` in one rename; the file is 0600 from creation.
enum PrivateFile {
    /// Create `path` (and parents) and force it to 0700, also when it already
    /// exists with looser bits from an earlier version.
    static func ensureDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        chmod(path, 0o700)
    }

    /// Force an existing file to 0600; a missing one is ignored.
    static func restrict(_ path: String) {
        chmod(path, 0o600)
    }

    static func writeAtomically(_ data: Data, to path: String) throws {
        try ensureDirectory((path as NSString).deletingLastPathComponent)
        let tempPath = "\(path).tmp-\(UUID().uuidString)"
        let fd = open(tempPath, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: tempPath])
        }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(tempPath, path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
            }
        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
            throw error
        }
    }
}

/// Whether, and why, a logged action can be reversed. The inverse itself lives
/// in the `sidecar` file, never in the log line: it can hold a note's body.
struct UndoInfo: Codable, Equatable {
    let supported: Bool
    let reason: String?
    var sidecar: String?

    static func no(_ reason: String) -> UndoInfo {
        UndoInfo(supported: false, reason: reason, sidecar: nil)
    }
}

/// One line of `actions.jsonl`. An action is an `intent` line written before
/// anything runs and an `outcome` line after; `undone` marks a later undo.
struct ActionLogLine: Codable, Equatable {
    var ts: String
    var id: String
    var phase: String
    var tool: String
    var args: JSONValue?
    var rule: String?
    var outcome: String?
    var errorCode: String?
    var undo: UndoInfo?
    var idempotencyKey: String?

    private enum CodingKeys: String, CodingKey {
        case ts, id, phase, tool, args, rule, outcome, undo
        case errorCode = "error_code"
        case idempotencyKey = "idempotency_key"
    }
}

/// An action as `pippin log` shows it: its intent and outcome lines merged.
struct ActionEntry: Codable, Equatable, Sendable {
    let id: String
    let ts: String
    let tool: String
    let args: JSONValue?
    let rule: String?
    /// `outcome_unknown` also covers an intent with no outcome line: the
    /// server died, or is still running the action.
    let outcome: String
    let errorCode: String?
    let finishedAt: String?
    let undo: UndoInfo
    let undone: Bool

    private enum CodingKeys: String, CodingKey {
        case id, ts, tool, args, rule, outcome, undo, undone
        case errorCode = "error_code"
        case finishedAt = "finished_at"
    }
}

/// Append-only JSONL record of every mutating MCP tool call.
struct ActionLog {
    let path: String

    static func defaultPath() -> String {
        SafetyPaths.stateDir() + "/actions.jsonl"
    }

    func append(_ line: ActionLogLine) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try AppendOnlyFile.append(encoder.encode(line) + Data("\n".utf8), to: path)
    }

    /// Every parseable line, oldest first. A torn or foreign line is skipped.
    func lines() -> [ActionLogLine] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? decoder.decode(ActionLogLine.self, from: Data($0.utf8)) }
    }

    /// Actions, newest first.
    func entries() -> [ActionEntry] {
        let all = lines()
        let outcomes = Dictionary(all.filter { $0.phase == "outcome" }.map { ($0.id, $0) }) { _, last in last }
        let undone = Set(all.filter { $0.phase == "undone" }.map(\.id))
        return all.filter { $0.phase == "intent" }.reversed().map { intent in
            let outcome = outcomes[intent.id]
            return ActionEntry(
                id: intent.id, ts: intent.ts, tool: intent.tool, args: intent.args, rule: intent.rule,
                outcome: outcome?.outcome ?? "outcome_unknown", errorCode: outcome?.errorCode, finishedAt: outcome?.ts,
                undo: outcome?.undo ?? .no("the action has no recorded outcome"), undone: undone.contains(intent.id)
            )
        }
    }
}

/// What the log may hold of a tool's arguments. Bodies, free text and secrets
/// become a length and a SHA-256; so does anything the tool's schema does not
/// declare, and any long string.
enum ArgRedactor {
    private static let contentKeys: Set = ["text", "notes", "note", "content", "message", "description", "prompt", "key"]
    private static let secretFragments = ["body", "apikey", "token", "secret", "password", "passwd", "credential"]
    static let maxVerbatimLength = 256

    static func isSensitive(_ key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        return contentKeys.contains(normalized) || secretFragments.contains { normalized.contains($0) }
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func redacted(_ text: String) -> JSONValue {
        .object(["redacted": .bool(true), "length": .int(Int64(text.count)), "sha256": .string(sha256(text))])
    }

    /// One argv-style token. `--body=...` keeps its flag name and loses its value.
    private static func token(_ text: String) -> JSONValue {
        if text.hasPrefix("--"), let equals = text.firstIndex(of: "=") {
            let flag = String(text[..<equals])
            let value = String(text[text.index(after: equals)...])
            if isSensitive(flag) || value.count > maxVerbatimLength {
                return .object(["flag": .string(flag), "value": redacted(value)])
            }
            return .string(text)
        }
        return text.count > maxVerbatimLength ? redacted(text) : .string(text)
    }

    static func redact(_ args: JSONValue?, schema: JSONValue) -> JSONValue {
        guard case let .object(dict)? = args else { return .object([:]) }
        var declared: [String: JSONValue] = [:]
        if case let .object(properties)? = schema["properties"] { declared = properties }
        return .object(dict.reduce(into: [:]) { out, pair in
            let (key, value) = pair
            let hide = isSensitive(key) || declared[key] == nil
            switch value {
            case .null, .bool, .int, .double:
                out[key] = hide && declared[key] == nil ? redacted(canonicalJSON(value)) : value
            case let .string(text):
                out[key] = hide || text.count > maxVerbatimLength ? redacted(text) : value
            case let .array(items) where !hide && items.allSatisfy { $0.stringValue != nil }:
                // Tokens after a bare `--` are free-form positionals.
                var afterSeparator = false
                out[key] = .array(items.compactMap(\.stringValue).map { item in
                    defer { if item == "--" { afterSeparator = true } }
                    return afterSeparator ? redacted(item) : token(item)
                })
            default:
                out[key] = redacted(canonicalJSON(value))
            }
        })
    }

    /// Sorted-key JSON, the form argument hashes are taken over.
    static func canonicalJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
