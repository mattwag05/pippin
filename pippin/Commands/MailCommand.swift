import ArgumentParser
import Foundation

public struct MailCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mail",
        abstract: "Interact with Apple Mail.",
        subcommands: [Accounts.self, Mailboxes.self, Search.self, List.self, Activity.self, Show.self, Verify.self, Read.self, Mark.self, Move.self, Send.self, Attachments.self, Reply.self, Forward.self, MailIndex.self, MailSanitize.self, MailExtract.self, MailTriage.self, MailApplyRules.self, Watch.self, Cache.self]
    )

    public init() {}

    /// Tie each message's sender to an Apple Contacts name (`fromContact`),
    /// honoring the command's `--no-contacts` / `--contacts` flags and the
    /// `resolveContacts` config default (ON when unset). See
    /// `ContactResolutionOptions.shouldResolve`.
    ///
    /// When resolution is enabled, builds the Contacts reverse index once and
    /// resolves each `From` header (which `ContactIndex` unwraps from `Name <addr>`
    /// form). Best-effort: an empty index (Contacts not authorized) leaves messages
    /// unchanged. Runs after the JXA bridge fetch — CNContactStore is native Swift,
    /// never in osascript.
    static func enrichContacts(
        _ messages: [MailMessage],
        options: ContactResolutionOptions
    ) async -> [MailMessage] {
        let resolve = options.shouldResolve(config: AIProviderFactory.loadConfig())
        guard resolve, !messages.isEmpty else { return messages }
        // CNContactStore enumeration is synchronous/blocking — hop off the
        // cooperative pool (per ContactsBridge.contactIndex's contract).
        let index = await detachBlocking { ContactsBridge.contactIndex() }
        guard !index.isEmpty else { return messages }
        return messages.map { msg in
            index.displayName(for: msg.from).map { msg.withFromContact($0) } ?? msg
        }
    }

    /// A scan answer with every reason it may be incomplete. `notes` are
    /// truncation advisories: each becomes a warning and marks the envelope
    /// partial, so a clamped request never reads as "no more rows".
    static func incomplete(
        timedOut: Bool, timedOutHint: String, notes: [String?], advisories: [String?] = []
    ) -> (warnings: [String]?, partial: Bool) {
        let truncation = notes.compactMap { $0 }
        let warnings = (timedOut ? [timedOutHint] : []) + truncation + advisories.compactMap { $0 }
        return (warnings.isEmpty ? nil : warnings, timedOut || !truncation.isEmpty)
    }

    /// A paginated request's page size, held to the row cap, with the advisory to show when it was reduced.
    static func cappedPageSize(_ requested: Int) -> (size: Int, note: String?) {
        guard requested > MailBridge.rowCap else { return (requested, nil) }
        return (
            MailBridge.rowCap,
            "--page-size \(requested) is above the \(MailBridge.rowCap)-row cap; this page holds at most \(MailBridge.rowCap) rows, continue with next_cursor"
        )
    }

    static let expectMessageIdHelp: ArgumentHelp =
        "Act only if the id still names the message with this RFC Message-ID (a row's messageIdHeader); otherwise fail with message_identity_mismatch. Mail can reassign ids."

    /// Suffix for soft-timeout hints listing the configured account names, so
    /// an agent can narrow with `--account` without a follow-up `mail accounts`
    /// call. Reads only the on-disk accounts cache (zero Apple Events); empty
    /// string when the cache is absent, leaving the hint unchanged.
    static func accountNamesSuffix(cachePath: String = MailAccountsCache.defaultPath()) -> String {
        let names = MailAccountsCache.load(path: cachePath).accounts.map(\.name)
        guard !names.isEmpty else { return "" }
        return " Configured accounts: \(names.joined(separator: ", "))."
    }

    // MARK: - Accounts

    public struct Accounts: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "accounts",
            abstract: "List configured Mail accounts."
        )

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            // listAccounts spawns a blocking osascript subprocess; hop off the pool.
            let accounts = try await detachBlocking { try MailBridge.listAccounts() }
            return AgentResult(accounts)
        }
    }

    // MARK: - Mailboxes

    public struct Mailboxes: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "mailboxes",
            abstract: "List mailboxes per account."
        )

        @Option(name: .long, help: "Filter by account name.")
        public var account: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let account = self.account
            // listMailboxes may spawn a blocking osascript subprocess; hop off the pool.
            let outcome = try await detachBlocking { try MailBridge.listMailboxes(account: account) }
            return AgentResult(outcome.mailboxes, warnings: outcome.fastPathNote.map { [$0] })
        }
    }

    // MARK: - Search

    public struct Search: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "search",
            abstract: "Search messages by subject or sender. Use --from for sender-only searches; use --body only for slower body-content scans."
        )

        @Argument(help: "Search query (case-insensitive, matches subject/sender).")
        public var query: String

        @Option(name: .long, help: "Filter by account name.")
        public var account: String?

        @Option(name: .long, help: "Restrict search to a single mailbox.")
        public var mailbox: String?

        @Flag(name: .long, help: "Include message body in search (slower).")
        public var body: Bool = false

        @Option(name: .long, help: "Only include messages on or after this day (YYYY-MM-DD, your local time zone).")
        public var after: String?

        @Option(name: .long, help: "Only include messages on or before this day, the whole day included (YYYY-MM-DD, your local time zone).")
        public var before: String?

        @Option(name: .long, help: "Filter by recipient email address.")
        public var to: String?

        @Option(name: .long, help: "Filter by sender (substring match on the From header).")
        public var from: String?

        @Flag(name: .long, help: "Print search diagnostics (accounts/mailboxes scanned, messages examined).")
        public var verbose: Bool = false

        @Option(name: .long, help: "Include a plain-text body preview of up to N chars per hit. Uncached hits cost one batched body fetch (slower).")
        public var preview: Int?

        @OptionGroup public var contactResolution: ContactResolutionOptions

        @Option(name: .long, help: "Maximum number of results to return (default: 10; values above 500 are capped).")
        public var limit: Int = 10

        @Flag(name: .long, help: "Use semantic (embedding-based) search. Requires running `mail index` first.")
        public var semantic: Bool = false

        @Option(name: .customLong("embedding-model"), help: "Embedding model for semantic search (default: ai.embeddings.model, else nomic-embed-text for ollama).")
        public var embeddingModel: String?

        @Option(name: .customLong("ollama-url"), help: "Ollama base URL for semantic search.")
        public var ollamaUrl: String?

        @Option(name: .long, help: "Embedding provider for semantic search: ollama or openai (default: ai.embeddings.provider, else ollama).")
        public var provider: String?

        @OptionGroup public var pagination: PaginationOptions

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard limit >= 1 else {
                throw ValidationError("--limit must be 1 or greater.")
            }
            if let preview, preview <= 0 {
                throw ValidationError("--preview must be a positive integer (chars).")
            }
            if preview != nil, semantic {
                throw ValidationError("--preview cannot be combined with --semantic.")
            }
            if let after = after {
                guard isValidDate(after) else {
                    throw ValidationError("--after must be in YYYY-MM-DD format, got: \(after)")
                }
            }
            if let before = before {
                guard isValidDate(before) else {
                    throw ValidationError("--before must be in YYYY-MM-DD format, got: \(before)")
                }
            }
        }

        public mutating func execute() async throws -> AgentResult {
            if pagination.isActive {
                return try await runPaginated()
            }
            if semantic {
                let embedProvider = try AIProviderFactory.makeEmbeddingProvider(
                    providerFlag: provider, modelFlag: embeddingModel, urlFlag: ollamaUrl
                )
                let store = try EmbeddingStore()

                let messages = try await detachBlocking { [query, limit] in
                    try SemanticSearch.search(
                        query: query,
                        store: store,
                        provider: embedProvider,
                        limit: limit
                    )
                }

                return AgentResult(messages)
            }

            let query = self.query
            let account = self.account
            let mailbox = self.mailbox
            let body = self.body
            let limit = self.limit
            let after = self.after
            let before = self.before
            let to = self.to
            let from = self.from
            let verbose = self.verbose
            let preview = self.preview
            // searchMessages spawns a blocking osascript subprocess (up to 95s
            // cross-account); hop off the cooperative pool so concurrent callers
            // (mcp-server) don't stall.
            let outcome = try await detachBlocking {
                try MailBridge.searchMessages(
                    query: query,
                    account: account,
                    mailbox: mailbox,
                    searchBody: body,
                    limit: limit,
                    offset: 0,
                    after: after,
                    before: before,
                    to: to,
                    from: from,
                    verbose: verbose,
                    preview: preview
                )
            }
            var messages = outcome.messages
            var timedOut = outcome.timedOut
            if let preview {
                let attached = try await detachBlocking { [messages] in
                    try MailBridge.attachSearchPreviews(messages, previewChars: preview, account: account)
                }
                messages = attached.messages
                timedOut = timedOut || attached.timedOut
            }
            try MailBridge.requireCompleteSearch(resultCount: messages.count, timedOut: timedOut)
            return try await emitMessages(
                messages, timedOut: timedOut, fastPathNote: outcome.fastPathNote,
                notes: [outcome.truncationNote, MailBridge.rowCapNote(requested: limit, returned: messages.count)]
            )
        }

        static var timedOutHint: String {
            "search exceeded soft timeout, returning partial results — narrow with --account, --mailbox, --after, or --before for complete results" + MailCommand.accountNamesSuffix()
        }

        private func emitMessages(
            _ messages: [MailMessage], timedOut: Bool, fastPathNote: String? = nil, notes: [String?] = []
        ) async throws -> AgentResult {
            let messages = await MailCommand.enrichContacts(messages, options: contactResolution)
            let state = MailCommand.incomplete(
                timedOut: timedOut, timedOutHint: Self.timedOutHint, notes: notes, advisories: [fastPathNote]
            )
            return AgentResult(
                messages, warnings: state.warnings, fields: FieldProjection.parse(output.fields), partial: state.partial
            )
        }

        private func emitPage(
            _ page: Page<MailMessage>, timedOut: Bool, fastPathNote: String? = nil,
            notes: [String?] = [], advisories: [String?] = []
        ) async throws -> AgentResult {
            let page = Page(items: await MailCommand.enrichContacts(page.items, options: contactResolution), nextCursor: page.nextCursor)
            let state = MailCommand.incomplete(
                timedOut: timedOut, timedOutHint: Self.timedOutHint, notes: notes,
                advisories: advisories + [fastPathNote]
            )
            return .page(
                page, warnings: state.warnings, fields: FieldProjection.parse(output.fields), partial: state.partial
            )
        }

        private func runPaginated() async throws -> AgentResult {
            let hash = Pagination.filterHash([
                "query": query,
                "account": account,
                "mailbox": mailbox,
                "body": body ? "1" : "0",
                "after": after,
                "before": before,
                "to": to,
                "from": from,
                "semantic": semantic ? "1" : "0",
            ])
            let (offset, requestedPageSize) = try Pagination.resolve(
                pagination, defaultPageSize: limit, filterHash: hash
            )
            // Semantic search ranks in memory and has no row cap.
            let capped = semantic
                ? (size: requestedPageSize, note: nil) : MailCommand.cappedPageSize(requestedPageSize)
            let pageSize = capped.size
            let pageSizeNote = capped.note
            let page: Page<MailMessage>
            var paginatedTimedOut = false
            var paginatedFastPathNote: String?
            var truncationNote: String?
            if semantic {
                let embedProvider = try AIProviderFactory.makeEmbeddingProvider(
                    providerFlag: provider, modelFlag: embeddingModel, urlFlag: ollamaUrl
                )
                let store = try EmbeddingStore()
                let searchLimit = offset + pageSize + 1
                let all = try await detachBlocking { [query] in
                    try SemanticSearch.search(
                        query: query,
                        store: store,
                        provider: embedProvider,
                        limit: searchLimit
                    )
                }
                page = try Pagination.paginate(
                    all: all, offset: offset, pageSize: pageSize, filterHash: hash
                )
            } else {
                let query = self.query
                let account = self.account
                let mailbox = self.mailbox
                let body = self.body
                let after = self.after
                let before = self.before
                let to = self.to
                let from = self.from
                let verbose = self.verbose
                let preview = self.preview
                // searchMessages spawns a blocking osascript subprocess; hop off
                // the cooperative pool so concurrent callers don't stall.
                let outcome = try await detachBlocking {
                    try MailBridge.searchMessages(
                        query: query,
                        account: account,
                        mailbox: mailbox,
                        searchBody: body,
                        limit: pageSize + 1,
                        offset: offset,
                        after: after,
                        before: before,
                        to: to,
                        from: from,
                        verbose: verbose,
                        preview: preview,
                        pageSentinel: true
                    )
                }
                paginatedTimedOut = outcome.timedOut
                paginatedFastPathNote = outcome.fastPathNote
                truncationNote = outcome.truncationNote
                var fetched = outcome.messages
                if let preview {
                    let attached = try await detachBlocking { [fetched] in
                        try MailBridge.attachSearchPreviews(fetched, previewChars: preview, account: account)
                    }
                    fetched = attached.messages
                    paginatedTimedOut = paginatedTimedOut || attached.timedOut
                }
                page = try Pagination.pageFromPushdown(
                    fetched: fetched, offset: offset, pageSize: pageSize, filterHash: hash
                )
            }
            try MailBridge.requireCompleteSearch(resultCount: page.items.count, timedOut: paginatedTimedOut)
            return try await emitPage(
                page, timedOut: paginatedTimedOut, fastPathNote: paginatedFastPathNote,
                notes: [truncationNote], advisories: [pageSizeNote]
            )
        }
    }

    // MARK: - List

    public struct List: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List messages. Defaults to INBOX, all messages, limit 20."
        )

        @Option(name: .long, help: "Filter by account name.")
        public var account: String?

        @Option(name: .long, help: "Mailbox name (default: INBOX).")
        public var mailbox: String = "INBOX"

        @Flag(name: .long, help: "Only show unread messages.")
        public var unread: Bool = false

        @Option(name: .long, help: "Only include messages on or after this day (YYYY-MM-DD, your local time zone).")
        public var after: String?

        @Option(name: .long, help: "Only include messages on or before this day, the whole day included (YYYY-MM-DD, your local time zone).")
        public var before: String?

        @Option(name: .long, help: "Maximum number of messages to return (default: 20; values above 500 are capped).")
        public var limit: Int = 20

        @Option(
            name: .long,
            help: "Include a plain-text body preview of up to N chars per message (e.g. --preview 200 for agent scan workflows to avoid N+1 mail_show calls). Forces a per-message IMAP fetch — bumps the timeout to 60s."
        )
        public var preview: Int?

        @Flag(name: .long, help: "Include AI-generated one-liner summaries per message (uses batch AI calls).")
        public var summarize: Bool = false

        @Option(name: .customLong("summarize-provider"), help: "AI provider for summaries.")
        public var summarizeProvider: String?

        @Option(name: .customLong("summarize-model"), help: "Model for summaries.")
        public var summarizeModel: String?

        @Option(name: .customLong("summarize-api-key"), help: "API key for summary provider.")
        public var summarizeApiKey: String?

        @Flag(name: .customLong("no-cache"), help: "Bypass the local body cache when using --preview and force live IMAP fetches.")
        public var noCache: Bool = false

        @OptionGroup public var contactResolution: ContactResolutionOptions

        @OptionGroup public var pagination: PaginationOptions

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard limit >= 1 else {
                throw ValidationError("--limit must be 1 or greater.")
            }
            if let preview, preview <= 0 {
                throw ValidationError("--preview must be a positive integer (chars).")
            }
            if let after = after {
                guard isValidDate(after) else {
                    throw ValidationError("--after must be in YYYY-MM-DD format, got: \(after)")
                }
            }
            if let before = before {
                guard isValidDate(before) else {
                    throw ValidationError("--before must be in YYYY-MM-DD format, got: \(before)")
                }
            }
            if pagination.isActive, summarize {
                throw ValidationError("--summarize cannot be combined with --cursor / --page-size.")
            }
        }

        public mutating func execute() async throws -> AgentResult {
            if pagination.isActive {
                return try await runPaginated()
            }
            let limit = self.limit
            let outcome = try await fetchList(limit: limit, offset: 0)
            let messages = outcome.messages

            if summarize {
                let aiProvider = try AIProviderFactory.make(
                    providerFlag: summarizeProvider, modelFlag: summarizeModel, apiKeyFlag: summarizeApiKey
                )
                // TriageEngine fans out via runConcurrently → provider.complete; both
                // sync and blocking. Hop off the cooperative pool.
                let triaged = try await detachBlocking {
                    try TriageEngine.triageBatchForSummaries(messages: messages, provider: aiProvider)
                }
                let triageMap = Dictionary(triaged.map { ($0.compoundId, $0.oneLiner) }, uniquingKeysWith: { first, _ in first })

                if triageMap.count < messages.count {
                    let missing = messages.count - triageMap.count
                    fputs("Warning: AI summary unavailable for \(missing) message(s).\n", stderr)
                }

                struct MessageWithSummary: Codable {
                    let message: MailMessage
                    let summary: String
                }
                let withSummaries = messages.map { MessageWithSummary(message: $0, summary: triageMap[$0.id] ?? "(summary unavailable)") }

                return .emit(withSummaries, timedOut: outcome.timedOut, timedOutHint: Self.timedOutHint, fields: FieldProjection.parse(output.fields))
            } else {
                return try await emitMessages(
                    messages, timedOut: outcome.timedOut,
                    fastPathNote: outcome.fastPathNote,
                    capNote: MailBridge.rowCapNote(requested: limit, returned: messages.count)
                )
            }
        }

        static var timedOutHint: String {
            "list exceeded soft timeout, returning partial results — narrow with --account, --mailbox, or a smaller --limit for complete results" + MailCommand.accountNamesSuffix()
        }

        private func emitMessages(
            _ messages: [MailMessage], timedOut: Bool, fastPathNote: String? = nil,
            capNote: String? = nil
        ) async throws -> AgentResult {
            let messages = await MailCommand.enrichContacts(messages, options: contactResolution)
            let state = MailCommand.incomplete(
                timedOut: timedOut, timedOutHint: Self.timedOutHint, notes: [capNote], advisories: [fastPathNote]
            )
            return AgentResult(
                messages, warnings: state.warnings, fields: FieldProjection.parse(output.fields), partial: state.partial
            )
        }

        private func emitPage(
            _ page: Page<MailMessage>, timedOut: Bool, fastPathNote: String? = nil, pageSizeNote: String? = nil
        ) async throws -> AgentResult {
            let page = Page(items: await MailCommand.enrichContacts(page.items, options: contactResolution), nextCursor: page.nextCursor)
            return .emitPage(
                page, timedOut: timedOut, timedOutHint: Self.timedOutHint,
                fields: FieldProjection.parse(output.fields),
                extraWarnings: [pageSizeNote, fastPathNote].compactMap { $0 }
            )
        }

        private func runPaginated() async throws -> AgentResult {
            let hash = Pagination.filterHash([
                "account": account,
                "mailbox": mailbox,
                "unread": unread ? "1" : "0",
                "preview": preview.map(String.init),
                "after": after,
                "before": before,
            ])
            let (offset, requestedPageSize) = try Pagination.resolve(
                pagination, defaultPageSize: limit, filterHash: hash
            )
            // The bridge returns at most rowCap rows plus the has-more sentinel,
            // so a larger page would silently lose its next_cursor.
            let (pageSize, pageSizeNote) = MailCommand.cappedPageSize(requestedPageSize)
            let outcome = try await fetchList(
                limit: pageSize + 1, offset: offset, pageSentinel: true, anchor: Pagination.anchor(of: pagination)
            )
            let page = try Pagination.pageFromPushdown(
                fetched: outcome.messages, offset: offset, pageSize: pageSize, filterHash: hash,
                anchor: MailBridge.pageAnchor
            )
            return try await emitPage(
                page, timedOut: outcome.timedOut, fastPathNote: outcome.fastPathNote, pageSizeNote: pageSizeNote
            )
        }

        /// Fetch a list page, routing `--preview N` through the body cache
        /// (`listMessagesCached`, always-on; `--no-cache` opts out) and the
        /// no-preview case through the untouched single-pass `listMessages`.
        /// Both spawn blocking osascript subprocesses (up to 60s cross-account),
        /// so hop off the cooperative pool.
        private func fetchList(
            limit: Int, offset: Int, pageSentinel: Bool = false, anchor: Cursor.Anchor? = nil
        ) async throws -> MailBridge.ListOutcome {
            let account = self.account
            let mailbox = self.mailbox
            let unread = self.unread
            let preview = self.preview
            let noCache = self.noCache
            let after = self.after
            let before = self.before
            return try await detachBlocking {
                if let preview, preview > 0 {
                    return try MailBridge.listMessagesCached(
                        account: account, mailbox: mailbox, unread: unread,
                        limit: limit, offset: offset, preview: preview,
                        after: after, before: before,
                        cache: noCache ? nil : MailBodyCache.shared,
                        pageSentinel: pageSentinel, seekingAfter: anchor
                    )
                }
                return try MailBridge.listMessages(
                    account: account, mailbox: mailbox, unread: unread,
                    limit: limit, offset: offset, preview: preview,
                    after: after, before: before, pageSentinel: pageSentinel, seekingAfter: anchor
                )
            }
        }
    }

    // MARK: - Show (formerly Read)

    public struct Show: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show one or more messages by compound id, or one by subject search.",
            discussion: "With 2+ ids, bodies for cache misses are fetched in a single batched Mail pass and the output is an array (single id keeps the original single-object shape)."
        )

        @Argument(help: "Message id(s) from `pippin mail list` output. 2+ ids batch-fetch in one Mail pass and emit an array.")
        public var messageIds: [String] = []

        @Option(name: .long, help: "Find first message matching this subject and show it.")
        public var subject: String?

        @Flag(name: .long, help: "Scan message body for prompt injection patterns before display.")
        public var sanitize: Bool = false

        @Flag(name: .long, help: "Include AI-assisted scan (requires --sanitize).")
        public var aiAssistedScan: Bool = false

        @Option(name: .long, help: "AI provider for --ai-assisted-scan.")
        public var sanitizeProvider: String?

        @Option(name: .customLong("sanitize-model"), help: "Model for AI-assisted scan.")
        public var sanitizeModel: String?

        @Option(name: .customLong("sanitize-api-key"), help: "API key for Claude provider (scan).")
        public var sanitizeApiKey: String?

        @Flag(name: .long, help: "Include an AI-generated summary.")
        public var summarize: Bool = false

        @Option(name: .customLong("summarize-provider"), help: "AI provider for summary.")
        public var summarizeProvider: String?

        @Option(name: .customLong("summarize-model"), help: "Model for summary.")
        public var summarizeModel: String?

        @Option(name: .customLong("summarize-api-key"), help: "API key for summary provider.")
        public var summarizeApiKey: String?

        @Flag(name: .customLong("no-cache"), help: "Bypass the local body cache and force a live IMAP fetch.")
        public var noCache: Bool = false

        @OptionGroup public var contactResolution: ContactResolutionOptions

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            if !messageIds.isEmpty, subject != nil {
                throw ValidationError("Provide either message ID(s) or --subject, not both.")
            }
            if messageIds.isEmpty, subject == nil {
                throw ValidationError("Provide a message ID or --subject.")
            }
            if messageIds.count > 1, sanitize || summarize {
                throw ValidationError("--sanitize and --summarize work with a single message ID.")
            }
        }

        public mutating func execute() async throws -> AgentResult {
            if messageIds.count > 1 {
                return try await runBatch(compoundIds: messageIds)
            }
            let compoundId: String
            if let subject = subject {
                // searchMessages spawns a blocking osascript subprocess; hop off
                // the cooperative pool so concurrent callers don't stall.
                let outcome = try await detachBlocking { try MailBridge.searchMessages(query: subject, limit: 1) }
                guard let first = outcome.messages.first else {
                    throw ValidationError("No message found matching subject: \(subject)")
                }
                compoundId = first.id
            } else {
                compoundId = messageIds[0]
            }

            // readMessage spawns a blocking osascript subprocess; hop off the pool.
            let useCache = noCache ? nil : MailBodyCache.shared
            let fetched = try await detachBlocking { try MailBridge.readMessage(compoundId: compoundId, cache: useCache) }
            let message = (await MailCommand.enrichContacts([fetched], options: contactResolution)).first ?? fetched

            if summarize {
                let summaryProvider = try AIProviderFactory.make(
                    providerFlag: summarizeProvider, modelFlag: summarizeModel, apiKeyFlag: summarizeApiKey
                )
                let summary = try TriageEngine.summarizeMessage(message: message, provider: summaryProvider)

                struct ShowWithSummary: Codable {
                    let message: MailMessage
                    let summary: String
                }
                return AgentResult(ShowWithSummary(message: message, summary: summary))
            } else if sanitize {
                let body = message.body ?? ""
                let scanResult: ScanResult
                if aiAssistedScan {
                    let aiProvider = try AIProviderFactory.make(
                        providerFlag: sanitizeProvider, modelFlag: sanitizeModel, apiKeyFlag: sanitizeApiKey
                    )
                    // PromptInjectionScanner.scanWithAI calls provider.complete which
                    // blocks via DispatchSemaphore — hop off the cooperative pool.
                    let bodyLocal = body
                    scanResult = try await detachBlocking {
                        try PromptInjectionScanner.scanWithAI(text: bodyLocal, provider: aiProvider)
                    }
                } else {
                    scanResult = PromptInjectionScanner.scan(text: body)
                }

                struct ShowWithScan: Codable {
                    let message: MailMessage
                    let scan: ScanResult
                }
                return AgentResult(ShowWithScan(message: message, scan: scanResult))
            } else {
                return AgentResult(message)
            }
        }

        /// 2+ ids: one batched Mail pass for cache misses (`readMessages`), then
        /// emit an array. Single-id calls keep the original single-object shape.
        private func runBatch(compoundIds: [String]) async throws -> AgentResult {
            let useCache = noCache ? nil : MailBodyCache.shared
            let fetched = try await detachBlocking { try MailBridge.readMessages(compoundIds: compoundIds, cache: useCache) }
            let messages = await MailCommand.enrichContacts(fetched, options: contactResolution)
            return AgentResult(messages, untrimmed: true) // `show` asks for whole messages.
        }
    }

    // MARK: - Verify (pippin-ml9)

    public struct Verify: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "verify",
            abstract: "Inspect a message's headers against the sender's historical baseline (phishing check)."
        )

        @Argument(help: "Message id from `pippin mail list` output.")
        public var messageId: String

        @Flag(name: .customLong("no-cache"), help: "Bypass the local body cache and force a live IMAP fetch.")
        public var noCache: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        struct DimensionReport: Codable {
            let dimension: String
            let name: String
            let current: String
            let prior: [String: Int]
            let deviation: Bool
        }

        struct VerifyReport: Codable {
            let id: String
            let from: String
            let subject: String
            let date: String
            let sender: String?
            let priorMessages: Int
            let dimensions: [DimensionReport]
            let anomalies: [String]?
            /// Full parsed chain from raw source (pippin-fwa); nil when Mail
            /// couldn't produce the source (report degrades to flat headers).
            let authChain: MailAuthChain?
            let verdict: String
        }

        public mutating func execute() async throws -> AgentResult {
            let id = messageId
            let useCache = noCache ? nil : MailBodyCache.shared
            // readMessage spawns a blocking osascript subprocess; hop off the
            // pool. It also runs the anomaly + baseline checks and records
            // this message's fingerprint.
            let message = try await detachBlocking { try MailBridge.readMessage(compoundId: id, cache: useCache) }

            // Deep auth-chain parse (pippin-fwa): the flat allHeaders dict keeps
            // one value per name, destroying Received/Authentication-Results/ARC
            // header SETS. Fetch raw RFC822 source and recover them; best-effort
            // (nil chain on any failure, verify still reports the flat view).
            let authChain = (try? await detachBlocking { try MailBridge.readRawSource(compoundId: id) })
                .flatMap { $0 }
                .map { RawHeaders.authChain(RawHeaders.parse($0)) }

            let sender = HeaderAnomalies.emailAddress(in: message.from)
            let fingerprint = message.headers.map { SenderFingerprint.extract(headers: $0) } ?? [:]
            let baseline = sender.flatMap { SenderBaselineStore.shared?.baseline(sender: $0, excluding: message.id) } ?? [:]

            let dimensions = fingerprint.sorted(by: { $0.key < $1.key }).map { dim, current in
                DimensionReport(
                    dimension: dim,
                    name: SenderFingerprint.dimensionNames[dim] ?? dim,
                    current: current,
                    prior: baseline[dim] ?? [:],
                    deviation: SenderBaselineStore.isDeviation(prior: baseline[dim] ?? [:], current: current)
                )
            }
            let priorMessages = dimensions.map { $0.prior.values.reduce(0, +) }.max() ?? 0

            // Deep-chain warnings share the flat check's phrasing, so a plain
            // string dedup merges the two views without double-reporting.
            let flat = message.headerAnomalies ?? []
            let deep = authChain.map(RawHeaders.deepWarnings) ?? []
            let anomalies = flat + deep.filter { !flat.contains($0) }

            let verdict: String
            if !anomalies.isEmpty {
                verdict = "SUSPICIOUS: \(anomalies.count) warning(s) — verify with the sender out-of-band before acting on this message"
            } else if priorMessages < SenderBaselineStore.minBaselineCount {
                verdict = "INCONCLUSIVE: no structural anomalies, but only \(priorMessages) prior message(s) from this sender — baseline comparison not yet meaningful"
            } else {
                verdict = "CONSISTENT: headers match this sender's baseline (\(priorMessages) prior messages) and no structural anomalies. Not proof of authenticity — a compromised account passes every check."
            }

            let report = VerifyReport(
                id: message.id, from: message.from, subject: message.subject, date: message.date,
                sender: sender, priorMessages: priorMessages, dimensions: dimensions,
                anomalies: anomalies.isEmpty ? nil : anomalies, authChain: authChain, verdict: verdict
            )

            return AgentResult(report)
        }
    }

    // MARK: - Read (hidden alias for backward compat)

    public struct Read: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "read",
            abstract: "Read a message (use 'show' instead).",
            shouldDisplay: false
        )

        @Argument(help: "Message id from `pippin mail list` output.")
        public var messageId: String

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            var show = Show()
            show.messageIds = [messageId]
            show.output = output
            return try await show.execute()
        }
    }

    // MARK: - Mark

    public struct Mark: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "mark",
            abstract: "Mark a message as read or unread."
        )

        @Argument(help: "Message id from `pippin mail list` output.")
        public var messageId: String

        @Option(name: .customLong("expect-message-id"), help: MailCommand.expectMessageIdHelp)
        public var expectMessageId: String?

        @Flag(name: .long, help: "Mark as read.")
        public var read: Bool = false

        @Flag(name: .long, help: "Mark as unread.")
        public var unread: Bool = false

        @Flag(name: .long, help: "Print what would happen without making changes.")
        public var dryRun: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard read != unread else {
                throw ValidationError("Specify exactly one of --read or --unread.")
            }
        }

        public mutating func execute() async throws -> AgentResult {
            let result = try MailBridge.markMessage(
                compoundId: messageId,
                read: read,
                dryRun: dryRun,
                expectMessageId: expectMessageId
            )
            return AgentResult(result)
        }
    }

    // MARK: - Move

    public struct Move: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "move",
            abstract: "Move a message to another mailbox."
        )

        @Argument(help: "Message id from `pippin mail list` output.")
        public var messageId: String

        @Option(name: .customLong("expect-message-id"), help: MailCommand.expectMessageIdHelp)
        public var expectMessageId: String?

        @Option(name: .long, help: "Destination mailbox name.")
        public var to: String

        @Flag(name: .long, help: "Print what would happen without making changes.")
        public var dryRun: Bool = false

        @Flag(name: .customLong("locate-by-message-id"), help: "Find the message in the id's mailbox by --expect-message-id instead of by row id (what `pippin undo` runs after a move).")
        public var locateByMessageId: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            if locateByMessageId, expectMessageId == nil {
                throw ValidationError("--locate-by-message-id needs --expect-message-id.")
            }
        }

        public mutating func execute() async throws -> AgentResult {
            let result = try MailBridge.moveMessage(
                compoundId: messageId,
                toMailbox: to,
                dryRun: dryRun,
                expectMessageId: expectMessageId,
                locateByMessageId: locateByMessageId
            )
            return AgentResult(result)
        }
    }

    // MARK: - Send

    public struct Send: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "send",
            abstract: "Send an email message."
        )

        @Option(name: .long, parsing: .unconditionalSingleValue, help: "Recipient email address (repeatable).")
        public var to: [String] = []

        @Option(name: .long, help: "Message subject.")
        public var subject: String

        @Option(name: .long, help: "Message body text.")
        public var body: String

        @Option(name: .customLong("cc"), parsing: .unconditionalSingleValue, help: "CC recipient (repeatable).")
        public var cc: [String] = []

        @Option(name: .customLong("bcc"), parsing: .unconditionalSingleValue, help: "BCC recipient (repeatable).")
        public var bcc: [String] = []

        @Option(name: .long, help: "Sending account name.")
        public var from: String?

        @Option(name: .customLong("attach"), parsing: .unconditionalSingleValue, help: "Path to file to attach (repeatable).")
        public var attach: [String] = []

        @Flag(name: .long, help: "Preview without sending (the default unless --confirm is passed).")
        public var dryRun: Bool = false

        @Flag(name: .long, help: "Actually send. Without this the command only previews.")
        public var confirm: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard !to.isEmpty else {
                throw ValidationError("At least one --to address is required.")
            }
            try validateEmailAddresses(to, field: "to")
            try validateEmailAddresses(cc, field: "cc")
            try validateEmailAddresses(bcc, field: "bcc")
            try validateAttachmentPaths(attach)
        }

        public mutating func execute() async throws -> AgentResult {
            let result = try MailBridge.sendMessage(
                to: to,
                subject: subject,
                body: body,
                cc: cc,
                bcc: bcc,
                from: from,
                attachmentPaths: attach,
                dryRun: dryRun || !confirm
            )
            return AgentResult(result)
        }
    }

    // MARK: - Attachments

    public struct Attachments: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "attachments",
            abstract: "List (and optionally save) attachments from a message."
        )

        @Argument(help: "Message id from `pippin mail list` output.")
        public var messageId: String

        @Option(name: .customLong("expect-message-id"), help: MailCommand.expectMessageIdHelp)
        public var expectMessageId: String?

        @Option(name: .long, help: "Save attachments to this directory.")
        public var saveDir: String?

        @Flag(name: .long, help: "Save attachments to pippin's default cache directory (~/Library/Caches/pippin/attachments/<msg>/).")
        public var saveToCache: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            if saveDir != nil, saveToCache {
                throw ValidationError("--save-dir and --save-to-cache are mutually exclusive.")
            }
            if let dir = saveDir {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
                    throw ValidationError("--save-dir does not exist or is not a directory: \(dir)")
                }
                guard FileManager.default.isWritableFile(atPath: dir) else {
                    throw ValidationError("--save-dir is not writable: \(dir)")
                }
            }
        }

        public mutating func execute() async throws -> AgentResult {
            // Resolve here, not in validate(): ArgumentParser may invoke validate() more
            // than once, and mutating saveDir there makes the mutual-exclusion check false-fire.
            let effectiveSaveDir = try saveToCache
                ? Attachments.resolveCacheDir(for: messageId)
                : saveDir
            let msgId = messageId
            let expectMessageId = self.expectMessageId
            // listAttachments spawns a blocking osascript subprocess; hop off the pool.
            let attachments = try await detachBlocking {
                try MailBridge.listAttachments(
                    compoundId: msgId, saveDir: effectiveSaveDir, expectMessageId: expectMessageId
                )
            }
            let unsaved = attachments.filter { $0.saveError != nil }.count
            guard unsaved > 0 else { return AgentResult(attachments) }
            return AgentResult(
                attachments,
                warnings: ["\(unsaved) of \(attachments.count) attachment(s) were not saved; each one's saveError says why"],
                partial: true
            )
        }

        /// Per-message cache dir; sanitizes shell/path-hostile chars so Gmail `[Gmail]`
        /// ids don't glob-expand when downstream tools unquote the returned path.
        static func resolveCacheDir(for compoundId: String) throws -> String {
            let sanitized = compoundId
                .replacingOccurrences(of: "||", with: "__")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "\\", with: "_")
                .replacingOccurrences(of: ":", with: "_")
                .replacingOccurrences(of: "[", with: "_")
                .replacingOccurrences(of: "]", with: "_")
                .replacingOccurrences(of: " ", with: "_")
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
            let dir = base
                .appendingPathComponent("pippin")
                .appendingPathComponent("attachments")
                .appendingPathComponent(sanitized)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.path
        }
    }

    // MARK: - Reply

    public struct Reply: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "reply",
            abstract: "Reply to a message."
        )

        @Argument(help: "Message id from `pippin mail list` output.")
        public var messageId: String

        @Option(name: .customLong("expect-message-id"), help: MailCommand.expectMessageIdHelp)
        public var expectMessageId: String?

        @Option(name: .long, help: "Reply body text.")
        public var body: String

        @Option(name: .customLong("to"), parsing: .unconditionalSingleValue, help: "Override reply-to address (repeatable; defaults to original sender).")
        public var to: [String] = []

        @Option(name: .customLong("cc"), parsing: .unconditionalSingleValue, help: "CC recipient (repeatable).")
        public var cc: [String] = []

        @Option(name: .customLong("bcc"), parsing: .unconditionalSingleValue, help: "BCC recipient (repeatable).")
        public var bcc: [String] = []

        @Option(name: .long, help: "Sending account name.")
        public var from: String?

        @Option(name: .customLong("attach"), parsing: .unconditionalSingleValue, help: "Path to file to attach (repeatable).")
        public var attach: [String] = []

        @Flag(name: .long, help: "Preview without sending (the default unless --confirm is passed).")
        public var dryRun: Bool = false

        @Flag(name: .long, help: "Actually send. Without this the command only previews.")
        public var confirm: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            try validateEmailAddresses(to, field: "to")
            try validateEmailAddresses(cc, field: "cc")
            try validateEmailAddresses(bcc, field: "bcc")
            try validateAttachmentPaths(attach)
        }

        public mutating func execute() async throws -> AgentResult {
            let result = try MailBridge.replyToMessage(
                compoundId: messageId,
                body: body,
                to: to.isEmpty ? nil : to,
                cc: cc,
                bcc: bcc,
                from: from,
                attachmentPaths: attach,
                dryRun: dryRun || !confirm,
                expectMessageId: expectMessageId
            )
            return AgentResult(result)
        }
    }

    // MARK: - Forward

    public struct Forward: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "forward",
            abstract: "Forward a message."
        )

        @Argument(help: "Message id from `pippin mail list` output.")
        public var messageId: String

        @Option(name: .customLong("to"), parsing: .unconditionalSingleValue, help: "Recipient address (repeatable).")
        public var to: [String] = []

        @Option(name: .customLong("expect-message-id"), help: MailCommand.expectMessageIdHelp)
        public var expectMessageId: String?

        @Option(name: .long, help: "Additional body text (prepended before forwarded content).")
        public var body: String = ""

        @Option(name: .customLong("cc"), parsing: .unconditionalSingleValue, help: "CC recipient (repeatable).")
        public var cc: [String] = []

        @Option(name: .customLong("bcc"), parsing: .unconditionalSingleValue, help: "BCC recipient (repeatable).")
        public var bcc: [String] = []

        @Option(name: .long, help: "Sending account name.")
        public var from: String?

        @Option(name: .customLong("attach"), parsing: .unconditionalSingleValue, help: "Path to file to attach (repeatable).")
        public var attach: [String] = []

        @Flag(name: .long, help: "Preview without sending (the default unless --confirm is passed).")
        public var dryRun: Bool = false

        @Flag(name: .long, help: "Actually send. Without this the command only previews.")
        public var confirm: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard !to.isEmpty else {
                throw ValidationError("At least one --to address is required.")
            }
            try validateEmailAddresses(to, field: "to")
            try validateEmailAddresses(cc, field: "cc")
            try validateEmailAddresses(bcc, field: "bcc")
            try validateAttachmentPaths(attach)
        }

        public mutating func execute() async throws -> AgentResult {
            let result = try MailBridge.forwardMessage(
                compoundId: messageId,
                to: to,
                body: body,
                cc: cc,
                bcc: bcc,
                from: from,
                attachmentPaths: attach,
                dryRun: dryRun || !confirm,
                expectMessageId: expectMessageId
            )
            return AgentResult(result)
        }
    }
}

// MARK: - Shared Helpers

private let emailPattern = #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#

private let datePattern = #"^\d{4}-\d{2}-\d{2}$"#

private func isValidDate(_ s: String) -> Bool {
    guard s.range(of: datePattern, options: .regularExpression) != nil else { return false }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.date(from: s) != nil
}

private func validateEmailAddresses(_ addrs: [String], field: String) throws {
    for addr in addrs {
        guard addr.range(of: emailPattern, options: .regularExpression) != nil else {
            throw ValidationError("--\(field) '\(addr)' does not look like a valid email address.")
        }
    }
}

private func validateAttachmentPaths(_ paths: [String]) throws {
    for path in paths {
        guard FileManager.default.fileExists(atPath: path) else {
            let filename = URL(fileURLWithPath: path).lastPathComponent
            throw ValidationError("Attachment file not found: \(filename)")
        }
    }
}
