import ArgumentParser
import Foundation

public struct MemosCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "memos",
        abstract: "Interact with Voice Memos.",
        subcommands: [List.self, Info.self, Export.self, Transcribe.self, Delete.self, TemplatesCommand.self, SummarizeCommand.self, MemosCaptureCommand.self]
    )

    public init() {}

    // MARK: - List

    public struct List: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List voice memo recordings."
        )

        @Option(name: .long, help: "Only return recordings on or after YYYY-MM-DD.")
        public var since: String?

        @Option(name: .long, help: "Maximum number of results (default: 20). Ignored when --cursor or --page-size is set.")
        public var limit: Int = 20

        @OptionGroup public var pagination: PaginationOptions

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            if let since {
                guard parseDateString(since) != nil else {
                    throw ValidationError("--since must be in YYYY-MM-DD format.")
                }
            }
            guard limit > 0 else {
                throw ValidationError("--limit must be positive.")
            }
        }

        public mutating func execute() async throws -> AgentResult {
            let db = try VoiceMemosDB(dbPath: VoiceMemosDB.defaultDBPath())
            let sinceDate = since.flatMap { parseDateString($0) }

            if pagination.isActive {
                let hash = Pagination.filterHash(["since": since])
                let (offset, pageSize) = try Pagination.resolve(
                    pagination, defaultPageSize: limit, filterHash: hash
                )
                let fetched = try markCachedTranscripts(db.listMemos(since: sinceDate, limit: offset + pageSize + 1))
                let page = try Pagination.paginate(
                    all: fetched, offset: offset, pageSize: pageSize, filterHash: hash
                )
                return .page(page)
            }

            let memos = try markCachedTranscripts(db.listMemos(since: sinceDate, limit: limit))
            return AgentResult(memos)
        }
    }

    // MARK: - Info

    public struct Info: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "info",
            abstract: "Show full metadata for a single recording."
        )

        @Argument(help: "Memo UUID from `pippin memos list` output.")
        public var id: String

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let db = try VoiceMemosDB(dbPath: VoiceMemosDB.defaultDBPath())
            guard var memo = try db.getMemoByPrefix(id: id) else {
                throw VoiceMemosError.memoNotFound(id)
            }
            // Surface a cached transcript honestly (best effort — a missing or
            // unreadable cache just leaves transcription null).
            if let cached = try? TranscriptCache().get(memoId: memo.id) {
                memo.transcription = cached.transcript
                memo.hasTranscript = true
            }

            return AgentResult(memo)
        }
    }

    // MARK: - Export

    public struct Export: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Copy recording(s) to a directory."
        )

        @Argument(help: "Memo UUID to export (omit with --all).")
        public var id: String?

        @Flag(name: .long, help: "Export every recording.")
        public var all: Bool = false

        @Option(name: .customLong("output"), help: ArgumentHelp("Destination directory (created if absent).", valueName: "output"))
        public var outputDir: String

        @Flag(name: .long, help: "Transcribe audio and write transcript sidecar.")
        public var transcribe: Bool = false

        @Option(name: .customLong("sidecar-format"), help: "Transcript sidecar format: txt, srt, markdown, rtf (default: txt).")
        public var sidecarFormat: String = "txt"

        @Flag(name: .customLong("force-transcribe"), help: "Bypass transcript cache when transcribing.")
        public var forceTranscribe: Bool = false

        @Option(name: .long, help: "Parallel transcription jobs (default: 2).")
        public var jobs: Int = 2

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard id != nil || all else {
                throw ValidationError("Provide a memo UUID or --all.")
            }
            let valid = ExportSidecarFormat.allCases.map(\.rawValue)
            guard valid.contains(sidecarFormat) else {
                throw ValidationError("--sidecar-format must be one of: \(valid.joined(separator: ", "))")
            }
            guard jobs >= 1 else {
                throw ValidationError("--jobs must be at least 1.")
            }
        }

        public mutating func execute() async throws -> AgentResult {
            let db = try VoiceMemosDB(dbPath: VoiceMemosDB.defaultDBPath())
            let sidecarFmt = ExportSidecarFormat(rawValue: sidecarFormat) ?? .txt
            let transcriber: (any Transcriber)? = transcribe ? try AIProviderFactory.makeTranscriber() : nil
            let cache: TranscriptCache? = transcribe ? try TranscriptCache() : nil

            var results: [ExportResult] = []
            var exportWarnings: [String] = []

            var batchTimedOut = false
            if all {
                let memos = try db.listMemos(limit: allMemosLimit)
                let chunks = stride(from: 0, to: memos.count, by: jobs).map { i in
                    Array(memos[i ..< min(i + jobs, memos.count)])
                }
                let budget = BatchBudget.forCurrentContext()
                var failures: [String] = []
                for chunk in chunks {
                    if budget.exceeded {
                        batchTimedOut = true
                        break
                    }
                    let outputDir = self.outputDir
                    let sidecarFmtCapture = sidecarFmt
                    let forceT = forceTranscribe
                    let chunkResults: [(Int, Result<ExportResult, Error>)] = await withTaskGroup(
                        of: (Int, Result<ExportResult, Error>).self
                    ) { group in
                        for (i, memo) in chunk.enumerated() {
                            let memoId = memo.id
                            group.addTask {
                                do {
                                    // Off the cooperative pool: concurrent Apple
                                    // transcriptions would otherwise exhaust it.
                                    let r = try await detachBlocking {
                                        try db.exportMemo(
                                            id: memoId,
                                            outputDir: outputDir,
                                            transcriber: transcriber,
                                            sidecarFormat: sidecarFmtCapture,
                                            cache: cache,
                                            forceTranscribe: forceT
                                        )
                                    }
                                    return (i, .success(r))
                                } catch {
                                    return (i, .failure(error))
                                }
                            }
                        }
                        var out: [(Int, Result<ExportResult, Error>)] = []
                        for await result in group {
                            out.append(result)
                        }
                        return out.sorted { $0.0 < $1.0 }
                    }
                    for (i, result) in chunkResults {
                        switch result {
                        case let .success(r):
                            results.append(r)
                        case let .failure(e):
                            let title = i < chunk.count ? chunk[i].title : "(unknown)"
                            failures.append("\(title): \(e.localizedDescription)")
                        }
                    }
                }
                // Surface per-item failures and budget exhaustion as envelope
                // warnings: they are the ONLY signal a caller gets. Without them
                // a batch where every memo failed would return an empty result
                // set with status "ok" and exit 0, indistinguishable from
                // "nothing to export".
                exportWarnings = Self.exportWarnings(
                    failures: failures,
                    totalMemos: memos.count,
                    exported: results.count,
                    batchTimedOut: batchTimedOut,
                    budgetSeconds: budget.softTimeoutMs / 1000
                )
            } else if let id {
                guard let memo = try db.getMemoByPrefix(id: id) else {
                    throw VoiceMemosError.memoNotFound(id)
                }
                let result = try db.exportMemo(
                    id: memo.id,
                    outputDir: outputDir,
                    transcriber: transcriber,
                    sidecarFormat: sidecarFmt,
                    cache: cache,
                    forceTranscribe: forceTranscribe
                )
                results.append(result)
            }

            return AgentResult(results, warnings: exportWarnings.isEmpty ? nil : exportWarnings)
        }

        /// Assemble non-fatal warnings for a batch export. Pure so it can be
        /// unit-tested without driving the whole command. Failures are capped to
        /// keep the envelope bounded; the leading summary always carries the
        /// full count.
        static func exportWarnings(
            failures: [String],
            totalMemos: Int,
            exported: Int,
            batchTimedOut: Bool,
            budgetSeconds: Int
        ) -> [String] {
            var warnings: [String] = []
            if !failures.isEmpty {
                warnings.append("\(failures.count) of \(totalMemos) recordings failed to export")
                warnings.append(contentsOf: failures.prefix(10))
            }
            if batchTimedOut {
                warnings.append(
                    "export batch budget (\(budgetSeconds)s) exceeded — \(exported)/\(totalMemos) recordings exported; narrow with smaller --jobs or per-memo invocations for the rest"
                )
            }
            return warnings
        }
    }

    // MARK: - Transcribe

    public struct Transcribe: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "transcribe",
            abstract: "Transcribe voice memo audio to text."
        )

        @Argument(help: "Memo UUID to transcribe (omit with --all).")
        public var id: String?

        @Flag(name: .long, help: "Transcribe every recording.")
        public var all: Bool = false

        @Option(name: .customLong("output"), help: ArgumentHelp("Directory to write .txt files (default: transcript only in the envelope).", valueName: "output"))
        public var outputDir: String?

        @Flag(name: .long, help: "Bypass transcript cache.")
        public var force: Bool = false

        @Option(name: .long, help: "Parallel transcription jobs (default: 2).")
        public var jobs: Int = 2

        @Flag(
            name: .customLong("keep-converted"),
            help: "Preserve any temp WAV produced by AudioConverter and log its path to stderr (debug)."
        )
        public var keepConverted: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard id != nil || all else {
                throw ValidationError("Provide a memo UUID or --all.")
            }
            guard jobs >= 1 else {
                throw ValidationError("--jobs must be at least 1.")
            }
        }

        public mutating func execute() async throws -> AgentResult {
            let db = try VoiceMemosDB(dbPath: VoiceMemosDB.defaultDBPath())
            let transcriber = try AIProviderFactory.makeTranscriber()
            let cache = try TranscriptCache()
            var results: [TranscribeResult] = []
            let keep = keepConverted
            let logConverted: @Sendable (String) -> Void = { path in
                FileHandle.standardError.write(Data("[converted] \(path)\n".utf8))
            }
            // stderr only: stdout carries the envelope.
            let convertedPathLogger: (@Sendable (String) -> Void)? = keep ? logConverted : nil

            var batchTimedOut = false
            var totalMemoCount = 0
            if all {
                let memos = try db.listMemos(limit: allMemosLimit)
                totalMemoCount = memos.count
                let chunks = stride(from: 0, to: memos.count, by: jobs).map { i in
                    Array(memos[i ..< min(i + jobs, memos.count)])
                }
                let budget = BatchBudget.forCurrentContext()
                for chunk in chunks {
                    if budget.exceeded {
                        batchTimedOut = true
                        break
                    }
                    let outputDir = self.outputDir
                    let forceFlag = force
                    let chunkResults: [(Int, Result<TranscribeResult, Error>)] = await withTaskGroup(
                        of: (Int, Result<TranscribeResult, Error>).self
                    ) { group in
                        for (i, memo) in chunk.enumerated() {
                            let memoId = memo.id
                            let memoTitle = memo.title
                            group.addTask {
                                do {
                                    if !forceFlag, let cached = try cache.get(memoId: memoId) {
                                        return (i, .success(TranscribeResult(
                                            id: memoId, title: memoTitle,
                                            transcription: cached.transcript, outputFile: nil
                                        )))
                                    }
                                    // Off the cooperative pool: concurrent Apple
                                    // transcriptions would otherwise exhaust it.
                                    let r = try await detachBlocking {
                                        try db.transcribeMemo(
                                            id: memoId,
                                            transcriber: transcriber,
                                            outputDir: outputDir,
                                            keepConverted: keep,
                                            onConvertedPath: convertedPathLogger
                                        )
                                    }
                                    try cache.set(memoId: memoId, transcript: r.transcription, provider: transcriber.cacheProvider)
                                    return (i, .success(r))
                                } catch {
                                    return (i, .failure(error))
                                }
                            }
                        }
                        var out: [(Int, Result<TranscribeResult, Error>)] = []
                        for await result in group {
                            out.append(result)
                        }
                        return out.sorted { $0.0 < $1.0 }
                    }
                    for (_, result) in chunkResults {
                        if case let .success(r) = result {
                            results.append(r)
                        }
                    }
                }
            } else if let id {
                guard let memo = try db.getMemoByPrefix(id: id) else {
                    throw VoiceMemosError.memoNotFound(id)
                }
                if !force, let cached = try cache.get(memoId: memo.id) {
                    results.append(TranscribeResult(
                        id: memo.id, title: memo.title,
                        transcription: cached.transcript, outputFile: nil
                    ))
                } else {
                    let result = try db.transcribeMemo(
                        id: memo.id,
                        transcriber: transcriber,
                        outputDir: outputDir,
                        keepConverted: keepConverted,
                        onConvertedPath: convertedPathLogger
                    )
                    try cache.set(memoId: memo.id, transcript: result.transcription, provider: transcriber.cacheProvider)
                    results.append(result)
                }
            }

            if batchTimedOut {
                let budgetSec = BatchBudget.forCurrentContext().softTimeoutMs / 1000
                fputs(
                    "warning: transcribe batch budget (\(budgetSec)s) exceeded — \(results.count)/\(totalMemoCount) memos transcribed; re-run for the remainder or process per-memo\n",
                    stderr
                )
            }

            return AgentResult(results)
        }
    }

    // MARK: - Delete

    public struct Delete: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete a voice memo: its audio file moves to the Trash and its DB row is removed. Quit Voice Memos first."
        )

        @Argument(help: "Memo UUID or unambiguous prefix to delete.")
        public var id: String

        @Flag(name: .long, help: "Required: confirm deletion without a prompt.")
        public var force: Bool = false

        @Flag(name: .long, help: "Report which recording would be deleted without changing anything (no --force needed).")
        public var dryRun: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard force || dryRun else {
                throw ValidationError("--force is required. The audio file moves to the Trash, but the recording's entry cannot be restored.")
            }
        }

        public mutating func execute() async throws -> AgentResult {
            let db = try VoiceMemosDB(dbPath: VoiceMemosDB.defaultDBPath())

            guard let memo = try db.getMemoByPrefix(id: id) else {
                throw VoiceMemosError.memoNotFound(id)
            }

            // Warn if iCloud-synced
            if try db.isEvicted(id: memo.id) {
                fputs("Warning: '\(memo.title)' has been evicted to iCloud. Deleting the DB row only.\n", stderr)
            }

            if dryRun {
                return AgentResult(BridgeActionResult(
                    success: true, action: "would_delete",
                    details: [
                        "id": memo.id, "title": memo.title, "audioPath": memo.filePath,
                        "voiceMemosRunning": String(VoiceMemosDB.voiceMemosIsRunning()),
                    ]
                ))
            }

            let deleted = try VoiceMemosDB.deleteMemo(id: memo.id)

            // Clear cached transcript
            if let cache = try? TranscriptCache() {
                try? cache.delete(memoId: memo.id)
            }

            var details = ["id": memo.id, "title": memo.title, "audioPath": deleted.audioPath]
            details["trashedTo"] = deleted.trashedTo
            return AgentResult(BridgeActionResult(success: true, action: "deleted", details: details))
        }
    }
}

/// Mark `hasTranscript` on each memo from a single transcript-cache query.
/// Best effort: any cache failure leaves the flags false.
private func markCachedTranscripts(_ memos: [VoiceMemo]) -> [VoiceMemo] {
    guard let ids = try? TranscriptCache().cachedMemoIds(), !ids.isEmpty else { return memos }
    return memos.map { memo in
        var memo = memo
        memo.hasTranscript = ids.contains(memo.id)
        return memo
    }
}

let allMemosLimit = 10000

/// Parse a YYYY-MM-DD string into a Date at midnight UTC.
func parseDateString(_ s: String) -> Date? {
    let formatter = DateFormatter()
    // en_US_POSIX pins the calendar/era so a non-Gregorian device calendar
    // (Thai Buddhist, Japanese era, …) can't misparse "yyyy" — the canonical
    // rule for fixed-format DateFormatters, used elsewhere in this codebase.
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.date(from: s)
}
