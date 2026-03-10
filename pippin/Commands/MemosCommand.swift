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

        @Option(name: .long, help: "Maximum number of results (default: 20).")
        public var limit: Int = 20

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
            let memos = try db.listMemos(since: sinceDate, limit: limit)

            if output.isJSON {
                try printJSON(memos)
            } else if output.isAgent {
                try printAgentJSON(memos)
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
                try printAgentJSON(memo)
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

        @Option(name: .long, help: "Transcript sidecar format: txt, srt, markdown, rtf (default: txt).")
        public var format: String = "txt"

        @OptionGroup public var outputOptions: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard id != nil || all else {
                throw ValidationError("Provide a memo UUID or --all.")
            }
            let valid = ExportSidecarFormat.allCases.map(\.rawValue)
            guard valid.contains(format) else {
                throw ValidationError("--format must be one of: \(valid.joined(separator: ", "))")
            }
        }

        public mutating func run() async throws {
            let db = try VoiceMemosDB(dbPath: VoiceMemosDB.defaultDBPath())
            let sidecarFormat = ExportSidecarFormat(rawValue: format) ?? .txt
            let transcriber: Transcriber? = transcribe ? TranscriberFactory.makeDefault() : nil

            var results: [ExportResult] = []

            if all {
                let memos = try db.listMemos(limit: allMemosLimit)
                for memo in memos {
                    if !outputOptions.isJSON, !outputOptions.isAgent {
                        print("Exporting: \(memo.title)...", terminator: " ")
                        fflush(stdout)
                    }
                    do {
                        let result = try db.exportMemo(
                            id: memo.id,
                            outputDir: output,
                            transcriber: transcriber,
                            sidecarFormat: sidecarFormat
                        )
                        results.append(result)
                        if !outputOptions.isJSON, !outputOptions.isAgent {
                            print("done")
                        }
                    } catch {
                        if !outputOptions.isJSON, !outputOptions.isAgent {
                            print("FAILED: \(error.localizedDescription)")
                        }
                    }
                }
            } else if let id {
                if !outputOptions.isJSON, !outputOptions.isAgent {
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
                    sidecarFormat: sidecarFormat
                )
                results.append(result)
                if !outputOptions.isJSON, !outputOptions.isAgent {
                    print("done")
                }
            }

            if outputOptions.isJSON {
                try printJSON(results)
            } else if outputOptions.isAgent {
                try printAgentJSON(results)
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

        @OptionGroup public var outputOptions: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard id != nil || all else {
                throw ValidationError("Provide a memo UUID or --all.")
            }
        }

        public mutating func run() async throws {
            let db = try VoiceMemosDB(dbPath: VoiceMemosDB.defaultDBPath())
            let transcriber = TranscriberFactory.makeDefault()
            var results: [TranscribeResult] = []

            if all {
                let memos = try db.listMemos(limit: allMemosLimit)
                for memo in memos {
                    if !outputOptions.isJSON, !outputOptions.isAgent {
                        print("Transcribing: \(memo.title)...", terminator: " ")
                        fflush(stdout)
                    }
                    do {
                        let result = try db.transcribeMemo(
                            id: memo.id, transcriber: transcriber, outputDir: output
                        )
                        results.append(result)
                        if !outputOptions.isJSON, !outputOptions.isAgent {
                            print("done")
                        }
                    } catch {
                        if !outputOptions.isJSON, !outputOptions.isAgent {
                            print("FAILED: \(error.localizedDescription)")
                        }
                    }
                }
            } else if let id {
                guard let memo = try db.getMemoByPrefix(id: id) else {
                    throw VoiceMemosError.memoNotFound(id)
                }
                let result = try db.transcribeMemo(
                    id: memo.id, transcriber: transcriber, outputDir: output
                )
                results.append(result)
            }

            if outputOptions.isJSON {
                try printJSON(results)
            } else if outputOptions.isAgent {
                try printAgentJSON(results)
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

            print("Deleted: \(memo.title)")
            print("  Audio: \(audioPath)")
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
