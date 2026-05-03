import ArgumentParser
import Foundation

public struct MemosCaptureCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "capture",
        abstract: "Transcribe a voice memo, extract action items, create Reminders."
    )

    @Option(name: .long, help: "Memo UUID or prefix (default: most recent recording).")
    public var memo: String?

    @Flag(name: .customLong("to-reminders"), help: "Required: commit action items to Reminders. Present for future --to-notes etc.")
    public var toReminders: Bool = false

    @Option(name: .long, help: "Reminder list name (default: Inbox).")
    public var list: String?

    @Flag(name: .long, help: "Preview items without creating reminders. Auto-on when stdout is a TTY.")
    public var dryRun: Bool = false

    @Option(name: .long, help: "AI provider: ollama or claude (default: ollama).")
    public var provider: String?

    @Option(name: .long, help: "Model name (provider-specific default).")
    public var model: String?

    @Option(name: .long, help: "API key for Claude provider.")
    public var apiKey: String?

    @OptionGroup public var outputOptions: OutputOptions

    private static let defaultCaptureList = "Inbox"

    public init() {}

    public mutating func validate() throws {
        guard toReminders else {
            throw ValidationError("--to-reminders is required.")
        }
    }

    public mutating func run() async throws {
        let effectiveDryRun = dryRun || shouldDefaultDryRun()

        let db = try VoiceMemosDB(dbPath: VoiceMemosDB.defaultDBPath())
        let cache = try TranscriptCache()
        let aiProvider = try AIProviderFactory.make(
            providerFlag: provider, modelFlag: model, apiKeyFlag: apiKey
        )

        let targetMemo = try resolveMemo(db: db)
        let transcript = try transcribe(memo: targetMemo, db: db, cache: cache)
        guard transcript.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4 else {
            throw MemosCaptureError.memoTooShort(memoId: targetMemo.id)
        }

        let rawResponse = try aiProvider.complete(
            prompt: transcript,
            system: renderSystemPrompt(now: Date())
        )
        let items = try parseItems(from: rawResponse)

        let listName = list ?? Self.defaultCaptureList
        let bridge = RemindersBridge()
        let resolvedListId = try await resolveListId(named: listName, bridge: bridge)

        var created: [CapturedItem] = []
        if !effectiveDryRun, !items.isEmpty {
            for item in items {
                let result = try await bridge.createReminder(
                    title: item.title,
                    listId: resolvedListId,
                    dueDate: item.dueHint.flatMap { parseCalendarDate($0) },
                    notes: item.notes
                )
                let reminderId = result.details["id"]
                created.append(CapturedItem(
                    title: item.title,
                    dueHint: item.dueHint,
                    notes: item.notes,
                    reminderId: reminderId
                ))
            }
        } else {
            created = items.map { item in
                CapturedItem(
                    title: item.title,
                    dueHint: item.dueHint,
                    notes: item.notes,
                    reminderId: nil
                )
            }
        }

        let payload = MemosCaptureResult(
            memo: CapturedMemo(
                id: targetMemo.id,
                title: targetMemo.title,
                durationSeconds: targetMemo.durationSeconds
            ),
            transcriptionChars: transcript.count,
            items: created,
            createdCount: effectiveDryRun ? 0 : created.count,
            list: listName,
            dryRun: effectiveDryRun
        )

        if outputOptions.isJSON {
            try printJSON(payload)
        } else if outputOptions.isAgent {
            try outputOptions.printAgent(payload)
        } else {
            printText(payload)
        }
    }

    // MARK: - Private

    private func shouldDefaultDryRun() -> Bool {
        // Only auto-engage dry-run for human-facing text output. Structured
        // formats (json + agent) are typically scripted/automated callers
        // who expect commit-by-default — anything else makes piping awkward
        // (e.g. `pippin … --format json | jq` would silently produce a
        // preview). Matches the CHANGELOG wording: "auto-on for TTY text".
        if outputOptions.isStructured { return false }
        return isatty(fileno(stdout)) != 0
    }

    private func resolveMemo(db: VoiceMemosDB) throws -> VoiceMemo {
        if let memo {
            guard let found = try db.getMemoByPrefix(id: memo) else {
                throw VoiceMemosError.memoNotFound(memo)
            }
            return found
        }
        let recent = try db.listMemos(limit: 1)
        guard let first = recent.first else {
            throw MemosCaptureError.noRecordings
        }
        return first
    }

    private func transcribe(
        memo: VoiceMemo,
        db: VoiceMemosDB,
        cache: TranscriptCache
    ) throws -> String {
        if let cached = try cache.get(memoId: memo.id) {
            return cached.transcript
        }
        let transcriber = MLXAudioTranscriber()
        let result = try db.transcribeMemo(id: memo.id, transcriber: transcriber)
        try cache.set(memoId: memo.id, transcript: result.transcription, provider: "mlx-audio")
        return result.transcription
    }

    private func renderSystemPrompt(now: Date) -> String {
        let dateFmt = DateFormatter()
        dateFmt.locale = Locale(identifier: "en_US_POSIX")
        dateFmt.dateFormat = "yyyy-MM-dd"
        let timeFmt = DateFormatter()
        timeFmt.locale = Locale(identifier: "en_US_POSIX")
        timeFmt.dateFormat = "HH:mm"
        return BuiltInTemplates.captureActionItems.content
            .replacingOccurrences(of: "{{CURRENT_DATE}}", with: dateFmt.string(from: now))
            .replacingOccurrences(of: "{{CURRENT_TIME}}", with: timeFmt.string(from: now))
    }

    private func parseItems(from response: String) throws -> [LLMActionItem] {
        guard let data = extractJSON(from: response) else {
            throw MemosCaptureError.malformedAIResponse(String(response.prefix(300)))
        }
        do {
            let parsed = try JSONDecoder().decode(LLMActionItemsResponse.self, from: data)
            return parsed.items
        } catch {
            throw MemosCaptureError.malformedAIResponse(String(response.prefix(300)))
        }
    }

    private func resolveListId(named name: String, bridge: RemindersBridge) async throws -> String {
        let lists = try await bridge.listReminderLists()
        if let match = lists.first(where: { $0.title.lowercased() == name.lowercased() }) {
            return match.id
        }
        let available = lists.map(\.title).joined(separator: ", ")
        throw MemosCaptureError.listNotFound(name: name, available: available)
    }

    private func printText(_ payload: MemosCaptureResult) {
        let header = TextFormatter.card(fields: [
            ("Memo", payload.memo.title),
            ("ID", String(payload.memo.id.prefix(8))),
            ("Transcript", "\(payload.transcriptionChars) chars"),
            ("List", payload.list),
            ("Mode", payload.dryRun ? "dry-run" : "committed"),
        ])
        print(header)
        if payload.items.isEmpty {
            print("No action items extracted.")
            return
        }
        for item in payload.items {
            var line = "  • \(item.title)"
            if let due = item.dueHint { line += "  [due: \(due)]" }
            print(line)
            if let notes = item.notes, !notes.isEmpty {
                print("      \"\(notes)\"")
            }
        }
        if payload.dryRun {
            print("")
            print("(dry run — re-run without --dry-run or from a non-TTY to commit)")
        } else {
            print("")
            print("Created \(payload.createdCount) reminder(s) in \(payload.list).")
        }
    }
}

// MARK: - Envelope payload

public struct MemosCaptureResult: Codable, Sendable {
    public let memo: CapturedMemo
    public let transcriptionChars: Int
    public let items: [CapturedItem]
    public let createdCount: Int
    public let list: String
    public let dryRun: Bool

    private enum CodingKeys: String, CodingKey {
        case memo
        case transcriptionChars = "transcription_chars"
        case items
        case createdCount = "created_count"
        case list
        case dryRun = "dry_run"
    }
}

public struct CapturedMemo: Codable, Sendable {
    public let id: String
    public let title: String
    public let durationSeconds: Double

    private enum CodingKeys: String, CodingKey {
        case id, title
        case durationSeconds = "duration_seconds"
    }
}

public struct CapturedItem: Codable, Sendable {
    public let title: String
    public let dueHint: String?
    public let notes: String?
    public let reminderId: String?

    private enum CodingKeys: String, CodingKey {
        case title
        case dueHint = "due_hint"
        case notes
        case reminderId = "reminder_id"
    }
}

// MARK: - LLM response model

struct LLMActionItemsResponse: Decodable {
    let items: [LLMActionItem]
}

struct LLMActionItem: Decodable {
    let title: String
    let dueHint: String?
    let notes: String?

    private enum CodingKeys: String, CodingKey {
        case title
        case dueHint = "due_hint"
        case notes
    }
}

// MARK: - Errors

public enum MemosCaptureError: LocalizedError, Sendable {
    case noRecordings
    case memoTooShort(memoId: String)
    case malformedAIResponse(String)
    case listNotFound(name: String, available: String)

    public var errorDescription: String? {
        switch self {
        case .noRecordings:
            return "No voice memos found. Record one in the Voice Memos app, then retry."
        case let .memoTooShort(memoId):
            return "Memo '\(memoId.prefix(8))' transcript is too short to extract action items."
        case let .malformedAIResponse(raw):
            return "LLM response was not valid JSON for action items. Raw (truncated): \(raw)"
        case let .listNotFound(name, available):
            return """
            Reminders list '\(name)' not found. Create it in the Reminders app, or pass --list with one of: \(available).
            """
        }
    }
}
