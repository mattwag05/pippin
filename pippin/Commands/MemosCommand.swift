import ArgumentParser
import Foundation

public struct MemosCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "memos",
        abstract: "Interact with Voice Memos.",
        subcommands: [List.self, Info.self, Export.self]
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
            guard let memo = try db.getMemo(id: id) else {
                throw VoiceMemosError.memoNotFound(id)
            }

            if output.isJSON {
                try printJSON(memo)
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

        @Flag(name: .long, help: "Transcribe audio and write .txt sidecar.")
        public var transcribe: Bool = false

        @OptionGroup public var outputOptions: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard id != nil || all else {
                throw ValidationError("Provide a memo UUID or --all.")
            }
        }

        public mutating func run() async throws {
            let db = try VoiceMemosDB(dbPath: VoiceMemosDB.defaultDBPath())
            let transcriber: Transcriber? = transcribe ? TranscriberFactory.makeDefault() : nil

            var results: [ExportResult] = []

            if all {
                let memos = try db.listMemos(limit: 10000)
                for memo in memos {
                    if !outputOptions.isJSON {
                        print("Exporting: \(memo.title)...", terminator: " ")
                        fflush(stdout)
                    }
                    do {
                        let result = try db.exportMemo(
                            id: memo.id,
                            outputDir: output,
                            transcriber: transcriber
                        )
                        results.append(result)
                        if !outputOptions.isJSON {
                            print("done")
                        }
                    } catch {
                        if !outputOptions.isJSON {
                            print("FAILED: \(error.localizedDescription)")
                        }
                    }
                }
            } else if let id {
                if !outputOptions.isJSON {
                    print("Exporting...", terminator: " ")
                    fflush(stdout)
                }
                let result = try db.exportMemo(
                    id: id,
                    outputDir: output,
                    transcriber: transcriber
                )
                results.append(result)
                if !outputOptions.isJSON {
                    print("done")
                }
            }

            if outputOptions.isJSON {
                try printJSON(results)
            } else {
                let noun = results.count == 1 ? "recording" : "recordings"
                print("\nExported \(results.count) \(noun) to \(output)")
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

/// Parse a YYYY-MM-DD string into a Date at midnight UTC.
private func parseDateString(_ s: String) -> Date? {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.date(from: s)
}
