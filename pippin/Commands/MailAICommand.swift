import ArgumentParser
import CryptoKit
import Foundation

// MARK: - Index

public struct MailIndex: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Build or update the semantic search index for mail messages."
    )

    @Option(name: .long, help: "Filter by account name.")
    public var account: String?

    @Option(name: .long, help: "Mailbox to index (default: INBOX).")
    public var mailbox: String = "INBOX"

    @Option(name: .long, help: "Maximum messages to index per run (default: 500).")
    public var limit: Int = 500

    @Option(name: .long, help: "Embedding provider (only 'ollama' supported).")
    public var provider: String = "ollama"

    @Option(name: .long, help: "Ollama base URL (default: http://localhost:11434).")
    public var ollamaUrl: String?

    @Option(name: .long, help: "Embedding model (default: nomic-embed-text).")
    public var model: String?

    @OptionGroup public var output: OutputOptions

    public init() {}

    public mutating func run() async throws {
        guard provider == "ollama" else {
            throw MailAIError.unsupportedEmbeddingProvider(provider)
        }

        let baseURL = ollamaUrl ?? "http://localhost:11434"
        let embeddingModel = model ?? "nomic-embed-text"
        let embedProvider = OllamaEmbeddingProvider(baseURL: baseURL, model: embeddingModel)
        let store = try EmbeddingStore()

        let messages = try MailBridge.listMessages(
            account: account,
            mailbox: mailbox,
            unread: false,
            limit: limit,
            offset: 0
        )

        var indexed = 0
        var skipped = 0
        let isoFormatter = ISO8601DateFormatter()

        // Phase 1: Identify messages needing indexing (skip already-indexed — email bodies are immutable)
        struct PendingItem {
            let id: String
            let subject: String
            let embedText: String
            let bodyHash: String
        }
        var toIndex: [PendingItem] = []
        for message in messages {
            if store.exists(compoundId: message.id) {
                skipped += 1
                if !output.isStructured {
                    fputs("  skip \(message.id)\n", stderr)
                }
                continue
            }
            let full = try MailBridge.readMessage(compoundId: message.id)
            let body = (full.body ?? "") + full.subject
            let hash = sha256Hex(body)
            let embedText = "Subject: \(message.subject)\nFrom: \(message.from)\nDate: \(message.date)"
            toIndex.append(PendingItem(id: message.id, subject: message.subject, embedText: embedText, bodyHash: hash))
        }

        // Phase 2: Embed in batches (reduces HTTP round-trips vs one-at-a-time)
        let batchSize = 32
        var embeddings: [(id: String, hash: String, floats: [Float])] = []
        let batches = stride(from: 0, to: toIndex.count, by: batchSize).map {
            Array(toIndex[$0 ..< min($0 + batchSize, toIndex.count)])
        }
        for batch in batches {
            let texts = batch.map(\.embedText)
            let batchFloats = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[[Float]], Error>) in
                DispatchQueue.global(qos: .background).async {
                    do {
                        let result = try embedProvider.embedBatch(texts: texts)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            for (item, floats) in zip(batch, batchFloats) {
                embeddings.append((id: item.id, hash: item.bodyHash, floats: floats))
            }
        }

        // Phase 3: Upsert all results
        for embedding in embeddings {
            let record = EmbeddingRecord(
                compoundId: embedding.id,
                embedding: serializeEmbedding(embedding.floats),
                bodyHash: embedding.hash,
                model: embeddingModel,
                indexedAt: isoFormatter.string(from: Date())
            )
            try store.upsert(record)
            indexed += 1
            if !output.isStructured {
                fputs("  index (\(indexed)/\(toIndex.count)) \(embedding.id)\n", stderr)
            }
        }

        let result = IndexResult(indexed: indexed, skipped: skipped, total: messages.count)
        if output.isJSON {
            try printJSON(result)
        } else if output.isAgent {
            try printAgentJSON(result)
        } else {
            print("Indexed \(indexed) messages, skipped \(skipped) (total \(messages.count))")
        }
    }
}

// MARK: - Sanitize

public struct MailSanitize: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sanitize",
        abstract: "Scan a message for prompt injection patterns."
    )

    @Argument(help: "Message ID (from `pippin mail list`).")
    public var messageId: String

    @Flag(name: .long, help: "Include AI-assisted scan in addition to rule-based patterns.")
    public var aiAssisted: Bool = false

    @Option(name: .long, help: "AI provider for --ai-assisted (ollama or claude).")
    public var provider: String?

    @Option(name: .long, help: "Model name.")
    public var model: String?

    @Option(name: .customLong("api-key"), help: "API key for Claude provider.")
    public var apiKey: String?

    @OptionGroup public var output: OutputOptions

    public init() {}

    public mutating func run() async throws {
        let message = try MailBridge.readMessage(compoundId: messageId)
        let body = message.body ?? ""

        let scanResult: ScanResult
        if aiAssisted {
            let aiProvider = try AIProviderFactory.make(
                providerFlag: provider, modelFlag: model, apiKeyFlag: apiKey
            )
            scanResult = try PromptInjectionScanner.scanWithAI(text: body, provider: aiProvider)
        } else {
            scanResult = PromptInjectionScanner.scan(text: body)
        }

        if output.isJSON {
            try printJSON(scanResult)
        } else if output.isAgent {
            try printAgentJSON(scanResult)
        } else {
            print("Risk level: \(scanResult.riskLevel.rawValue.uppercased())")
            print("Threats found: \(scanResult.threats.count)")
            if !scanResult.threats.isEmpty {
                for threat in scanResult.threats {
                    print("  [\(threat.category.rawValue)] confidence=\(String(format: "%.2f", threat.confidence)): \(threat.matchedText)")
                }
            }
        }
    }
}

// MARK: - Triage

public struct MailTriage: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "triage",
        abstract: "AI-powered triage: classify and prioritize messages using metadata only."
    )

    @Option(name: .long, help: "Filter by account name.")
    public var account: String?

    @Option(name: .long, help: "Mailbox to triage (default: INBOX).")
    public var mailbox: String = "INBOX"

    @Option(name: .long, help: "Maximum messages to triage (default: 20, min: 1).")
    public var limit: Int = 20

    @Option(name: .long, help: "AI provider: ollama or claude.")
    public var provider: String?

    @Option(name: .long, help: "Model name.")
    public var model: String?

    @Option(name: .customLong("api-key"), help: "API key for Claude provider.")
    public var apiKey: String?

    @Flag(name: .long, help: "Skip rule-based pre-pass; send all messages to AI.")
    public var noRules: Bool = false

    @Option(name: .long, help: "Path to triage-rules.json (default: ~/.config/pippin/triage-rules.json).")
    public var rulesFile: String?

    @OptionGroup public var output: OutputOptions

    public init() {}

    public mutating func validate() throws {
        if limit < 1 {
            throw ValidationError("--limit must be at least 1")
        }
    }

    public mutating func run() async throws {
        let messages = try MailBridge.listMessages(
            account: account,
            mailbox: mailbox,
            unread: false,
            limit: limit,
            offset: 0
        )

        // Apply persistent rules before the AI pass to skip token usage on predictable patterns.
        let rules = noRules ? [] : TriageRulesEngine.loadRules(path: rulesFile)
        let (remaining, ruleTriaged) = TriageRulesEngine.apply(rules: rules, to: messages)

        let aiProvider = try AIProviderFactory.make(
            providerFlag: provider, modelFlag: model, apiKeyFlag: apiKey
        )
        let aiResult = try TriageEngine.triage(messages: remaining, provider: aiProvider)

        let result = TriageResult(
            messages: ruleTriaged + aiResult.messages,
            summary: aiResult.summary,
            actionItems: aiResult.actionItems
        )

        if output.isJSON {
            try printJSON(result)
        } else if output.isAgent {
            try printAgentJSON(result)
        } else {
            let rows = result.messages.map { m in
                [m.category.rawValue, "\(m.urgency)", TextFormatter.truncate(m.subject, to: 35), m.oneLiner]
            }
            print(TextFormatter.table(
                headers: ["CATEGORY", "PRI", "SUBJECT", "SUMMARY"],
                rows: rows,
                columnWidths: [15, 4, 36, 40]
            ))
            if !ruleTriaged.isEmpty {
                print("\n\(ruleTriaged.count) message(s) classified by rules (skipped AI)")
            }
            if !result.summary.isEmpty {
                print("\nSummary: \(result.summary)")
            }
            if !result.actionItems.isEmpty {
                print("\nAction items:")
                result.actionItems.forEach { print("  \u{2022} \($0)") }
            }
        }
    }
}

// MARK: - Extract

public struct MailExtract: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "extract",
        abstract: "Extract structured data (dates, amounts, contacts, action items) from a message."
    )

    @Argument(help: "Message ID (from `pippin mail list`).")
    public var messageId: String

    @Option(name: .long, help: "AI provider: ollama or claude (default: ollama).")
    public var provider: String?

    @Option(name: .long, help: "Model name (provider-specific default).")
    public var model: String?

    @Option(name: .customLong("api-key"), help: "API key for Claude provider.")
    public var apiKey: String?

    @OptionGroup public var output: OutputOptions

    public init() {}

    public mutating func run() async throws {
        let message = try MailBridge.readMessage(compoundId: messageId)
        let aiProvider = try AIProviderFactory.make(
            providerFlag: provider,
            modelFlag: model,
            apiKeyFlag: apiKey
        )
        let result = try DataExtractor.extract(
            messageBody: message.body ?? "",
            subject: message.subject,
            provider: aiProvider
        )
        if output.isJSON {
            try printJSON(result)
        } else if output.isAgent {
            try printAgentJSON(result)
        } else {
            if !result.dates.isEmpty {
                print("Dates:")
                result.dates.forEach { print("  \($0.text)" + ($0.isoDate.map { " [\($0)]" } ?? "")) }
            }
            if !result.amounts.isEmpty {
                print("Amounts:")
                result.amounts.forEach { print("  \($0.text)") }
            }
            if !result.trackingNumbers.isEmpty {
                print("Tracking: \(result.trackingNumbers.joined(separator: ", "))")
            }
            if !result.actionItems.isEmpty {
                print("Action items:")
                result.actionItems.forEach { print("  \u{2022} \($0)") }
            }
            if !result.contacts.isEmpty {
                print("Contacts:")
                for c in result.contacts {
                    let parts = [c.name, c.email, c.phone].compactMap { $0 }
                    guard !parts.isEmpty else { continue }
                    print("  \(parts.joined(separator: " | "))")
                }
            }
            if !result.urls.isEmpty {
                print("URLs:")
                result.urls.forEach { print("  \($0)") }
            }
            if result.dates.isEmpty, result.amounts.isEmpty, result.trackingNumbers.isEmpty,
               result.actionItems.isEmpty, result.contacts.isEmpty, result.urls.isEmpty
            {
                print("No structured data found.")
            }
        }
    }
}

// MARK: - Backward-compatibility typealiases

public extension MailCommand {
    typealias Index = MailIndex
    typealias Sanitize = MailSanitize
    typealias Triage = MailTriage
    typealias Extract = MailExtract
}

// MARK: - Private helpers (MailAI-specific)

private func sha256Hex(_ string: String) -> String {
    let data = Data(string.utf8)
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}
