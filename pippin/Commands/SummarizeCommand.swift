import ArgumentParser
import Foundation

public struct SummarizeCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "summarize",
        abstract: "Summarize a voice memo using AI."
    )

    @Argument(help: "Memo UUID or prefix (omit with --all).")
    public var id: String?

    @Flag(name: .long, help: "Summarize all recordings.")
    public var all: Bool = false

    @Option(name: .long, help: "Template to use (e.g. meeting-notes, summary, action-items).")
    public var template: String?

    @Option(name: .long, help: "Free-form prompt (overrides --template).")
    public var prompt: String?

    @Option(name: .long, help: "AI provider: ollama or claude (default: ollama).")
    public var provider: String?

    @Option(name: .long, help: "Model name (provider-specific default).")
    public var model: String?

    @Option(name: .long, help: "API key for Claude provider.")
    public var apiKey: String?

    @Option(name: [.customLong("since")], help: "Only summarize memos on or after YYYY-MM-DD (with --all).")
    public var since: String?

    @Option(name: .long, help: "Write output to a directory instead of stdout.")
    public var output: String?

    @OptionGroup public var outputOptions: OutputOptions

    public init() {}

    public mutating func validate() throws {
        guard id != nil || all else {
            throw ValidationError("Provide a memo UUID/prefix or --all.")
        }
        if template != nil, prompt != nil {
            throw ValidationError("Use either --template or --prompt, not both.")
        }
        if let since {
            guard parseSinceDateString(since) != nil else {
                throw ValidationError("--since must be in YYYY-MM-DD format.")
            }
        }
    }

    public mutating func run() async throws {
        let db = try VoiceMemosDB(dbPath: VoiceMemosDB.defaultDBPath())
        let cache = try TranscriptCache()
        let aiProvider = try AIProviderFactory.make(
            providerFlag: provider,
            modelFlag: model,
            apiKeyFlag: apiKey
        )

        let systemPrompt = try resolveSystemPrompt()

        if all {
            let sinceDate = since.flatMap { parseSinceDateString($0) }
            let memos = try db.listMemos(since: sinceDate, limit: 10000)
            var results: [SummarizeResult] = []

            for memo in memos {
                if !outputOptions.isJSON {
                    print("Summarizing: \(memo.title)...", terminator: " ")
                    fflush(stdout)
                }
                do {
                    let result = try summarizeMemo(
                        memo: memo,
                        db: db,
                        cache: cache,
                        aiProvider: aiProvider,
                        systemPrompt: systemPrompt
                    )
                    results.append(result)
                    if let outputDir = output {
                        try writeResult(result, toDir: outputDir)
                        if !outputOptions.isJSON { print("done") }
                    } else if !outputOptions.isJSON {
                        print("done")
                    }
                } catch {
                    if !outputOptions.isJSON {
                        print("FAILED: \(error.localizedDescription)")
                    }
                }
            }

            if outputOptions.isJSON {
                try printJSON(results)
            } else if output == nil {
                for result in results {
                    printSummaryText(result)
                    print("")
                }
            } else {
                print("\nSummarized \(results.count) recording(s) → \(output!)")
            }

        } else if let id {
            guard let memo = try db.getMemoByPrefix(id: id) else {
                throw VoiceMemosError.memoNotFound(id)
            }
            let result = try summarizeMemo(
                memo: memo,
                db: db,
                cache: cache,
                aiProvider: aiProvider,
                systemPrompt: systemPrompt
            )

            if let outputDir = output {
                let path = try writeResult(result, toDir: outputDir)
                if !outputOptions.isJSON {
                    print("Summary written to: \(path)")
                } else {
                    try printJSON(result)
                }
            } else if outputOptions.isJSON {
                try printJSON(result)
            } else {
                printSummaryText(result)
            }
        }
    }

    // MARK: - Private

    private func resolveSystemPrompt() throws -> String {
        if let prompt { return prompt }
        let templateName = template ?? "summary"
        let manager = TemplateManager()
        let tmpl = try manager.resolve(name: templateName)
        return tmpl.content
    }

    private func summarizeMemo(
        memo: VoiceMemo,
        db: VoiceMemosDB,
        cache: TranscriptCache,
        aiProvider: any AIProvider,
        systemPrompt: String
    ) throws -> SummarizeResult {
        // 1. Get transcript — from cache or transcribe
        let transcriptText: String
        if let cached = try cache.get(memoId: memo.id) {
            transcriptText = cached.transcript
        } else {
            let transcriber = TranscriberFactory.makeDefault()
            let result = try db.transcribeMemo(id: memo.id, transcriber: transcriber)
            transcriptText = result.transcription
            let providerName = "parakeet-mlx"
            try cache.set(memoId: memo.id, transcript: transcriptText, provider: providerName)
        }

        // 2. Build user prompt
        let userPrompt = """
        Title: \(memo.title)
        Duration: \(formatDuration(memo.durationSeconds))
        Date: \(formatDate(memo.createdAt))

        Transcript:
        \(transcriptText)
        """

        // 3. Call AI provider
        let summary = try aiProvider.complete(prompt: userPrompt, system: systemPrompt)

        let resolvedProviderName: String
        if let provider = provider {
            resolvedProviderName = provider
        } else {
            resolvedProviderName = String(describing: type(of: aiProvider))
        }

        return SummarizeResult(
            id: memo.id,
            title: memo.title,
            createdAt: memo.createdAt,
            summary: summary,
            template: template ?? (promptIsSet ? nil : "summary"),
            provider: resolvedProviderName
        )
    }

    private var promptIsSet: Bool {
        prompt != nil
    }

    @discardableResult
    private func writeResult(_ result: SummarizeResult, toDir dir: String) throws -> String {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dateStr = VoiceMemosDB.exportDatePrefix(result.createdAt)
        let sanitized = VoiceMemosDB.sanitizeFilename(result.title)
        let ext = outputOptions.isJSON ? "json" : "md"
        let baseName = "\(dateStr)_\(sanitized)"
        let path = VoiceMemosDB.resolveCollision(dir: dir, baseName: baseName, ext: ext)

        if outputOptions.isJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(result)
            try data.write(to: URL(fileURLWithPath: path))
        } else {
            let markdown = "# \(result.title)\n\n\(result.summary)\n"
            try markdown.write(toFile: path, atomically: true, encoding: .utf8)
        }
        return path
    }

    private func printSummaryText(_ result: SummarizeResult) {
        let card = TextFormatter.card(fields: [
            ("Title", result.title),
            ("ID", String(result.id.prefix(8))),
        ])
        print(card)
        print(result.summary)
    }
}

// MARK: - Result model

public struct SummarizeResult: Codable, Sendable {
    public let id: String
    public let title: String
    public let createdAt: Date
    public let summary: String
    public let template: String?
    public let provider: String
}

// MARK: - Helpers

private func formatDuration(_ seconds: Double) -> String {
    TextFormatter.duration(seconds)
}

private func formatDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

private func parseSinceDateString(_ s: String) -> Date? {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.date(from: s)
}
