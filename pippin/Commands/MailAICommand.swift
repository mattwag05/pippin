import ArgumentParser
import CryptoKit
import Foundation

// MARK: - Index

public struct MailIndex: AgentCommand {
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

    @Option(name: .long, help: "Embedding provider: ollama or openai (default: ai.embeddings.provider, else ollama).")
    public var provider: String?

    @Option(name: .long, help: "Ollama base URL (default: ai.ollama.url, else http://localhost:11434).")
    public var ollamaUrl: String?

    @Option(name: .long, help: "Embedding model (default: ai.embeddings.model, else nomic-embed-text for ollama).")
    public var model: String?

    @OptionGroup public var output: OutputOptions

    public init() {}

    public mutating func execute() async throws -> AgentResult {
        let embedProvider = try AIProviderFactory.makeEmbeddingProvider(
            providerFlag: provider, modelFlag: model, urlFlag: ollamaUrl
        )
        let storeKey = embedProvider.storeKey
        let store = try EmbeddingStore()

        // Phase 1: Identify messages needing indexing. Skip ids that already
        // embed this same message (email bodies are immutable); an id Mail
        // reassigned to another message is re-embedded (pippin-log5).
        struct PendingItem: Sendable {
            let id: String
            let date: String
            let subject: String
            let embedText: String
            let bodyHash: String
        }

        let account = self.account
        let mailbox = self.mailbox
        let limit = self.limit
        // listMessages and the per-message readMessage loop both spawn blocking
        // osascript subprocesses, and store.exists hits SQLite — hop the whole
        // scan+read phase off the cooperative pool.
        let (indexOutcome, toIndex, skipped) = try await detachBlocking {
            () -> (MailBridge.ListOutcome, [PendingItem], Int) in
            let indexOutcome = try MailBridge.listMessages(
                account: account,
                mailbox: mailbox,
                unread: false,
                limit: limit,
                offset: 0
            )
            var toIndex: [PendingItem] = []
            var skipped = 0
            for message in indexOutcome.messages {
                if store.isCurrent(compoundId: message.id, messageDate: message.date, model: storeKey) {
                    skipped += 1
                    continue
                }
                let full = try MailBridge.readMessage(row: message)
                let body = (full.body ?? "") + full.subject
                let hash = sha256Hex(body)
                let embedText = "Subject: \(message.subject)\nFrom: \(message.from)\nDate: \(message.date)"
                toIndex.append(PendingItem(id: message.id, date: message.date, subject: message.subject, embedText: embedText, bodyHash: hash))
            }
            return (indexOutcome, toIndex, skipped)
        }
        if indexOutcome.timedOut {
            fputs("warning: mail scan timed out — only the messages returned before the soft cap will be indexed; re-run with a narrower --account/--mailbox or smaller --limit for full coverage\n", stderr)
        }
        let messages = indexOutcome.messages

        var indexed = 0
        let isoFormatter = ISO8601DateFormatter()

        // Phase 2: Embed in batches (reduces HTTP round-trips vs one-at-a-time)
        let batchSize = 32
        var embeddings: [(id: String, date: String, hash: String, floats: [Float])] = []
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
                embeddings.append((id: item.id, date: item.date, hash: item.bodyHash, floats: floats))
            }
        }

        // Phase 3: Upsert all results
        for embedding in embeddings {
            let record = EmbeddingRecord(
                compoundId: embedding.id,
                embedding: serializeEmbedding(embedding.floats),
                bodyHash: embedding.hash,
                model: storeKey ?? "unknown",
                indexedAt: isoFormatter.string(from: Date()),
                messageDate: embedding.date
            )
            try store.upsert(record)
            indexed += 1
        }

        let result = IndexResult(indexed: indexed, skipped: skipped, total: messages.count)
        return .emit(result, timedOut: indexOutcome.timedOut, timedOutHint: "mailbox scan timed out — index will be partial")
    }
}

// MARK: - Sanitize

public struct MailSanitize: AgentCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sanitize",
        abstract: "Scan a message for prompt injection patterns."
    )

    @Argument(help: "Message ID (from `pippin mail list`).")
    public var messageId: String

    @Flag(name: .long, help: "Include AI-assisted scan in addition to rule-based patterns.")
    public var aiAssisted: Bool = false

    @Option(name: .long, help: "AI provider for --ai-assisted (ollama, claude, openai, or apple).")
    public var provider: String?

    @Option(name: .long, help: "Model name.")
    public var model: String?

    @Option(name: .customLong("api-key"), help: "API key for Claude provider.")
    public var apiKey: String?

    @OptionGroup public var output: OutputOptions

    public init() {}

    public mutating func execute() async throws -> AgentResult {
        let messageId = self.messageId
        let aiAssisted = self.aiAssisted
        let provider = self.provider
        let model = self.model
        let apiKey = self.apiKey
        // readMessage spawns an osascript subprocess and scanWithAI blocks via
        // DispatchSemaphore (sendSynchronousRequest); hop off the cooperative pool.
        let scanResult = try await detachBlocking { () -> ScanResult in
            let message = try MailBridge.readMessage(compoundId: messageId)
            let body = message.body ?? ""
            if aiAssisted {
                let aiProvider = try AIProviderFactory.make(
                    providerFlag: provider, modelFlag: model, apiKeyFlag: apiKey
                )
                return try PromptInjectionScanner.scanWithAI(text: body, provider: aiProvider)
            } else {
                return PromptInjectionScanner.scan(text: body)
            }
        }

        return AgentResult(scanResult)
    }
}

// MARK: - Triage

public struct MailTriage: AgentCommand {
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

    @Option(name: .long, help: "AI provider: ollama, claude, openai, or apple.")
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

    public mutating func execute() async throws -> AgentResult {
        let account = self.account
        let mailbox = self.mailbox
        let limit = self.limit
        let noRules = self.noRules
        let rulesFile = self.rulesFile
        let provider = self.provider
        let model = self.model
        let apiKey = self.apiKey
        // listMessages spawns osascript and TriageEngine.triage blocks via
        // DispatchSemaphore (AI provider); hop off the cooperative pool.
        let (triageOutcome, result) = try await detachBlocking {
            () -> (MailBridge.ListOutcome, TriageResult) in
            let triageOutcome = try MailBridge.listMessages(
                account: account,
                mailbox: mailbox,
                unread: false,
                limit: limit,
                offset: 0
            )
            let messages = triageOutcome.messages

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
            return (triageOutcome, result)
        }
        if triageOutcome.timedOut {
            fputs("warning: mail scan timed out — triage operating on partial results; some unread messages may be missed\n", stderr)
        }

        return .emit(result, timedOut: triageOutcome.timedOut, timedOutHint: "mailbox scan timed out — triage results will be partial")
    }
}

// MARK: - Extract

public struct MailExtract: AgentCommand, AIFlagged {
    public static let configuration = CommandConfiguration(
        commandName: "extract",
        abstract: "Extract structured data (dates, amounts, contacts, action items) from a message."
    )

    @Argument(help: "Message ID (from `pippin mail list`).")
    public var messageId: String

    @OptionGroup public var ai: AIOptions

    @OptionGroup public var output: OutputOptions

    public init() {}

    public mutating func execute() async throws -> AgentResult {
        let messageId = self.messageId
        let provider = self.provider
        let model = self.model
        let apiKey = self.apiKey
        // readMessage spawns osascript and DataExtractor.extract blocks via
        // DispatchSemaphore (AI provider); hop off the cooperative pool.
        let result = try await detachBlocking { () -> ExtractionResult in
            let message = try MailBridge.readMessage(compoundId: messageId)
            let aiProvider = try AIProviderFactory.make(
                providerFlag: provider,
                modelFlag: model,
                apiKeyFlag: apiKey
            )
            return try DataExtractor.extract(
                messageBody: message.body ?? "",
                subject: message.subject,
                provider: aiProvider
            )
        }
        return AgentResult(result)
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
