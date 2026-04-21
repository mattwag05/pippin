import ArgumentParser
import Foundation

public struct MemosCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "memos",
        abstract: "Interact with Voice Memos.",
        subcommands: [List.self, Info.self, Export.self, Transcribe.self, Delete.self, TemplatesCommand.self, SummarizeCommand.self]
    )

    public init() {}

    // MARK: - List

    public struct List: AsyncParsableCommand {
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

        public mutating func run() async throws {
            let db = try VoiceMemosDB(dbPath: VoiceMemosDB.defaultDBPath())
            let sinceDate = since.flatMap { parseDateString($0) }

            if pagination.isActive {
                let hash = Pagination.filterHash(["since": since])
                let (offset, pageSize) = try Pagination.resolve(
                    pagination, defaultPageSize: limit, filterHash: hash
                )
                // Fetch enough to fill (offset + pageSize + 1) — the +1 is a sentinel
                // for whether there are more pages.
                let fetched = try db.listMemos(since: sinceDate, limit: offset + pageSize + 1)
                let page = try Pagination.paginate(
                    all: fetched, offset: offset, pageSize: pageSize, filterHash: hash
                )
                if output.isJSON {
                    try printJSON(page)
                } else if output.isAgent {
                    try output.printAgent(page)
                } else {
                    printMemosTable(page.items)
                    if let cursor = page.nextCursor {
                        print("(more — re-run with --cursor \(cursor))")
                    }
                }
                return
            }

            let memos = try db.listMemos(since: sinceDate, limit: limit)
            if output.isJSON {
                try printJSON(memos)
            } else if output.isAgent {
                try output.printAgent(memos)
            } else {
                printMemosTable(memos)
            }
        }
    }

    // MARK: - Info

    public struct Info: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "info",
            abstract: "Show full metadata for a single recording."
        )

        @Argument(help: "Memo UUID from `pippin memos list` output.")
        public var id: String

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            let db = try VoiceMemosDB(dbPath: VoiceMemosDB.defaultDBPath())
            guard let memo = try db.getMemoByPrefix(id: id) else {
                throw VoiceMemosError.memoNotFound(id)
            }

            if output.isJSON {
                try printJSON(memo)
            } else if output.isAgent {
                try output.printAgent(memo)
            } else {
                printMemoCard(memo)
            }
        }
    }

    // MARK: - Export

    public struct Export: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Copy recording(s) to a directory."
        )

        @Argument(help: "Memo UUID to export (omit with --all).")
        public var id: String?

        @Flag(name: .long, help: "Export every recording.")
        public var all: Bool = false

        @Option(name: .long, help: "Destination directory (created if absent).")
        public var output: String

        @Flag(name: .long, help: "Transcribe audio and write transcript sidecar.")
        public var transcribe: Bool = false

        @Option(name: .customLong("sidecar-format"), help: "Transcript sidecar format: txt, srt, markdown, rtf (default: txt).")
        public var sidecarFormat: String = "txt"

        @Flag(name: .customLong("force-transcribe"), help: "Bypass transcript cache when transcribing.")
        public var forceTranscribe: Bool = false

        @Option(name: .long, help: "Parallel transcription jobs (default: 2).")
        public var jobs: Int = 2

        @OptionGroup public var outputOptions: OutputOptions

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

        public mutating func run() async throws {
            let db = try VoiceMemosDB(dbPath: VoiceMemosDB.defaultDBPath())
            let sidecarFmt = ExportSidecarFormat(rawValue: sidecarFormat) ?? .txt
            let transcriber: (any Transcriber)? = transcribe ? MLXAudioTranscriber() : nil
            let cache: TranscriptCache? = transcribe ? try TranscriptCache() : nil

            var results: [ExportResult] = []

            if all {
                let memos = try db.listMemos(limit: allMemosLimit)
                let chunks = stride(from: 0, to: memos.count, by: jobs).map { i in
                    Array(memos[i ..< min(i + jobs, memos.count)])
                }
                for chunk in chunks {
                    if !outputOptions.isStructured {
                        for memo in chunk {
                            print("Exporting: \(memo.title)...", terminator: " ")
                            fflush(stdout)
                        }
                    }
                    let outputDir = output
                    let sidecarFmtCapture = sidecarFmt
                    let forceT = forceTranscribe
                    let chunkResults: [(Int, Result<ExportResult, Error>)] = await withTaskGroup(
                        of: (Int, Result<ExportResult, Error>).self
                    ) { group in
                        for (i, memo) in chunk.enumerated() {
                            let memoId = memo.id
                            group.addTask {
                                do {
                                    let r = try db.exportMemo(
                                        id: memoId,
                                        outputDir: outputDir,
                                        transcriber: transcriber,
                                        sidecarFormat: sidecarFmtCapture,
                                        cache: cache,
                                        forceTranscribe: forceT
                                    )
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
                    for (_, result) in chunkResults {
                        switch result {
                        case let .success(r):
                            results.append(r)
                            if !outputOptions.isStructured { print("done") }
                        case let .failure(e):
                            if !outputOptions.isStructured { print("FAILED: \(e.localizedDescription)") }
                        }
                    }
                }
            } else if let id {
                if !outputOptions.isStructured {
                    print("Exporting...", terminator: " ")
                    fflush(stdout)
                }
                guard let memo = try db.getMemoByPrefix(id: id) else {
                    throw VoiceMemosError.memoNotFound(id)
                }
                let result = try db.exportMemo(
                    id: memo.id,
                    outputDir: output,
                    transcriber: transcriber,
                    sidecarFormat: sidecarFmt,
                    cache: cache,
                    forceTranscribe: forceTranscribe
                )
                results.append(result)
                if !outputOptions.isStructured {
                    print("done")
                }
            }

            if outputOptions.isJSON {
                try printJSON(results)
            } else if outputOptions.isAgent {
                try outputOptions.printAgent(results)
            } else {
                let noun = results.count == 1 ? "recording" : "recordings"
                print("\nExported \(results.count) \(noun) to \(output)")
            }
        }
    }

    // MARK: - Transcribe

    public struct Transcribe: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "transcribe",
            abstract: "Transcribe voice memo audio to text."
        )

        @Argument(help: "Memo UUID to transcribe (omit with --all).")
        public var id: String?

        @Flag(name: .long, help: "Transcribe every recording.")
        public var all: Bool = false

        @Option(name: .long, help: "Directory to write .txt files (default: print to stdout).")
        public var output: String?

        @Flag(name: .long, help: "Bypass transcript cache.")
        public var force: Bool = false

        @Option(name: .long, help: "Parallel transcription jobs (default: 2).")
        public var jobs: Int = 2

        @Flag(
            name: .customLong("keep-converted"),
            help: "Preserve any temp WAV produced by AudioConverter and print its path (debug)."
        )
        public var keepConverted: Bool = false

        @OptionGroup public var outputOptions: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard id != nil || all else {
                throw ValidationError("Provide a memo UUID or --all.")
            }
            guard jobs >= 1 else {
                throw ValidationError("--jobs must be at least 1.")
            }
        }

        public mutating func run() async throws {
            let db = try VoiceMemosDB(dbPath: VoiceMemosDB.defaultDBPath())
            let transcriber = MLXAudioTranscriber()
            let cache = try TranscriptCache()
            var results: [TranscribeResult] = []
            let keep = keepConverted
            let logConverted: @Sendable (String) -> Void = { path in
                FileHandle.standardError.write(Data("[converted] \(path)\n".utf8))
            }
            let convertedPathLogger: (@Sendable (String) -> Void)? =
                (keep && !outputOptions.isStructured) ? logConverted : nil

            if all {
                let memos = try db.listMemos(limit: allMemosLimit)
                let chunks = stride(from: 0, to: memos.count, by: jobs).map { i in
                    Array(memos[i ..< min(i + jobs, memos.count)])
                }
                for chunk in chunks {
                    if !outputOptions.isStructured {
                        for memo in chunk {
                            print("Transcribing: \(memo.title)...", terminator: " ")
                            fflush(stdout)
                        }
                    }
                    let outputDir = output
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
                                    let r = try db.transcribeMemo(
                                        id: memoId,
                                        transcriber: transcriber,
                                        outputDir: outputDir,
                                        keepConverted: keep,
                                        onConvertedPath: convertedPathLogger
                                    )
                                    try cache.set(memoId: memoId, transcript: r.transcription, provider: "mlx-audio")
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
                        switch result {
                        case let .success(r):
                            results.append(r)
                            if !outputOptions.isStructured { print("done") }
                        case let .failure(e):
                            if !outputOptions.isStructured { print("FAILED: \(e.localizedDescription)") }
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
                        outputDir: output,
                        keepConverted: keepConverted,
                        onConvertedPath: convertedPathLogger
                    )
                    try cache.set(memoId: memo.id, transcript: result.transcription, provider: "mlx-audio")
                    results.append(result)
                }
            }

            if outputOptions.isJSON {
                try printJSON(results)
            } else if outputOptions.isAgent {
                try outputOptions.printAgent(results)
            } else if !all {
                if let result = results.first {
                    print(result.transcription)
                }
            } else {
                print("\nTranscribed \(results.count) recording(s)")
            }
        }
    }

    // MARK: - Delete

    public struct Delete: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete a voice memo (DB row + audio file)."
        )

        @Argument(help: "Memo UUID or prefix to delete.")
        public var id: String

        @Flag(name: .long, help: "Required: confirm deletion without a prompt.")
        public var force: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard force else {
                throw ValidationError("--force is required. This operation cannot be undone.")
            }
        }

        public mutating func run() async throws {
            let db = try VoiceMemosDB(dbPath: VoiceMemosDB.defaultDBPath())

            guard let memo = try db.getMemoByPrefix(id: id) else {
                throw VoiceMemosError.memoNotFound(id)
            }

            // Warn if iCloud-synced
            if try db.isEvicted(id: memo.id) {
                fputs("Warning: '\(memo.title)' has been evicted to iCloud. Deleting the DB row only.\n", stderr)
            }

            let audioPath = try VoiceMemosDB.deleteMemo(id: memo.id)

            // Clear cached transcript
            if let cache = try? TranscriptCache() {
                try? cache.delete(memoId: memo.id)
            }

            let result = MemosActionResult(
                success: true, action: "deleted",
                details: ["title": memo.title, "audioPath": audioPath]
            )
            if output.isJSON {
                try printJSON(result)
            } else if output.isAgent {
                try output.printAgent(result)
            } else {
                print("Deleted: \(memo.title)")
                print("  Audio: \(audioPath)")
            }
        }
    }
}

// MARK: - Text output helpers

private func printMemosTable(_ memos: [VoiceMemo]) {
    if memos.isEmpty {
        print("No recordings found.")
        return
    }
    // Column widths: ID(10), DATE(18), DURATION(10), TITLE(remaining)
    let rows = memos.map { memo -> [String] in
        let shortId = String(memo.id.prefix(8))
        let date = TextFormatter.compactDate(memo.createdAt)
        let dur = TextFormatter.duration(memo.durationSeconds)
        return [shortId, date, dur, memo.title]
    }
    let table = TextFormatter.table(
        headers: ["ID", "DATE", "DURATION", "TITLE"],
        rows: rows,
        columnWidths: [10, 18, 10, 42]
    )
    print(table)
}

private func printMemoCard(_ memo: VoiceMemo) {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let card = TextFormatter.card(fields: [
        ("ID", memo.id),
        ("Title", memo.title),
        ("Duration", TextFormatter.duration(memo.durationSeconds)),
        ("Created", TextFormatter.compactDate(memo.createdAt)),
        ("File", memo.filePath),
    ])
    print(card)
}

let allMemosLimit = 10000

/// Parse a YYYY-MM-DD string into a Date at midnight UTC.
func parseDateString(_ s: String) -> Date? {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.date(from: s)
}
