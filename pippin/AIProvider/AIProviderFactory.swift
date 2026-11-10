import Foundation

// MARK: - Config file model

public struct PippinConfig: Codable, Sendable {
    public var ai: AIConfig?
    public var messages: MessagesConfig?
    public var mail: MailConfig?

    /// Global default for Apple Contacts name resolution on Mail/Messages output.
    /// When `false`, sender/participant handles are NOT resolved to contact names,
    /// which skips the per-command `CNContactStore` enumeration. Useful for agents
    /// and the morning briefing that call `mail list` once per account + `messages
    /// list` — collapsing what would be N+1 address-book enumerations per run down
    /// to zero, without having to pass `--no-contacts` on every command. `nil` /
    /// absent keeps resolution ON (non-breaking default). A per-command
    /// `--no-contacts` / `--contacts` flag overrides this. Precedence is computed
    /// by `ContactResolutionOptions.shouldResolve`.
    public var resolveContacts: Bool?

    public struct AIConfig: Codable, Sendable {
        public var provider: String?
        public var ollama: OllamaConfig?
        public var claude: ClaudeConfig?
        public var openai: OpenAIConfig?

        public struct OllamaConfig: Codable, Sendable {
            public var url: String?
            public var model: String?
        }

        public struct ClaudeConfig: Codable, Sendable {
            public var model: String?
        }

        /// Any OpenAI-compatible Chat Completions endpoint (OpenAI, OpenRouter,
        /// a homelab gateway, vLLM, LM Studio, Ollama `/v1`, …).
        /// `baseURL` is the API root that `/chat/completions` is appended to
        /// (e.g. `https://ai-gateway.example.com/v1`). `apiKey` is optional —
        /// omit it for local endpoints that don't authenticate.
        public struct OpenAIConfig: Codable, Sendable {
            public var baseURL: String?
            public var model: String?
            public var apiKey: String?
            /// Opt into native JSON mode (`response_format: json_object`) for the
            /// JSON-extraction commands. OFF by default — `response_format` isn't
            /// universally supported across OpenAI-compatible servers, and a
            /// backend that rejects it would 400 a request that otherwise works.
            /// Enable only against a server you've verified accepts it. (pippin-us2)
            public var structuredOutputs: Bool?
        }

        /// Backend for `mail index` and `mail search --semantic` embeddings
        /// (pippin-edjh). Absent = Ollama with `nomic-embed-text`.
        /// `provider`: `ollama` or `openai` (any `/v1/embeddings` endpoint).
        /// For `openai`, an absent `baseURL`/`apiKey` falls back to `ai.openai`.
        public var embeddings: EmbeddingsConfig?

        /// Backend for memo transcription (pippin-edjh). Absent = mlx-audio.
        /// `provider`: `mlx-audio`, `apple` (on-device SpeechAnalyzer, macOS
        /// 26+), or `openai` (any `/v1/audio/transcriptions` endpoint). For
        /// `openai`, an absent `baseURL`/`apiKey` falls back to `ai.openai`.
        public var transcription: TranscriptionConfig?

        public struct EmbeddingsConfig: Codable, Sendable {
            public var provider: String?
            public var model: String?
            public var baseURL: String?
            public var apiKey: String?
        }

        public struct TranscriptionConfig: Codable, Sendable {
            public var provider: String?
            public var model: String?
            public var baseURL: String?
            public var apiKey: String?
            /// BCP 47 locale for `apple` (default: the system locale).
            public var locale: String?
        }
    }

    public struct MessagesConfig: Codable, Sendable {
        public var excludedThreads: [String]?
        public var defaultWindowHours: Int?
        public var autonomousAllowlist: [String]?
    }

    public struct MailConfig: Codable, Sendable {
        /// Envelope Index fast path for `mail list`/`search`/`activity` metadata
        /// (pippin-60x). `nil`/absent = ON (it falls back to JXA silently whenever
        /// the index is unreadable, so the default costs nothing when unavailable).
        /// Set `false` to force the JXA path permanently; the
        /// `PIPPIN_MAIL_FASTPATH=0` env var overrides per-invocation.
        public var fastPath: Bool?
        /// Opt-in (pippin-521): fill `mail list`/`activity` `--preview` snippets
        /// from the Envelope Index `summaries` table (Mail's own snippet text)
        /// instead of fetching bodies over JXA. OFF by default because the
        /// summary is Mail's semantic snippet, NOT the first N chars of the
        /// body (drift for preview-text consumers), and only a fraction of
        /// messages have one (the rest still batch-fetch). When on, previews
        /// served from a summary bypass the MailBodyCache write-through, so a
        /// later `mail show` of that message pays a cold fetch.
        public var previewFromIndex: Bool?
    }
}

/// The config file exists but cannot be used. An absent file is not an error:
/// it means defaults.
public enum ConfigError: LocalizedError, Sendable {
    case invalid(path: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(path, detail):
            return "pippin's config file at \(path) could not be read as valid config: \(detail)"
        }
    }
}

extension ConfigError: RemediableError {
    public var agentCode: String { "invalid_config" }

    public var nextStep: NextStep {
        switch self {
        case let .invalid(path, _):
            return .human("Fix the JSON in \(path), or move that file aside to run on defaults. pippin leaves the file untouched until it parses.")
        }
    }
}

// MARK: - Factory

public enum AIProviderFactory {
    /// Default config file path. `PIPPIN_CONFIG` overrides it, so tests and
    /// e2e checks can select backends without editing the user's config.
    public static func defaultConfigPath() -> String {
        if let override = ProcessInfo.processInfo.environment["PIPPIN_CONFIG"], !override.isEmpty {
            return override
        }
        let home = NSHomeDirectory()
        return "\(home)/.config/pippin/config.json"
    }

    /// Load config from disk: nil when the file is absent (defaults apply),
    /// `ConfigError.invalid` when it exists but cannot be read or parsed.
    /// Anything that enforces a setting (the Messages exclude list and
    /// allowlist), rewrites the file, or picks an AI backend must use this, so a
    /// typo in the file is never mistaken for "no settings".
    public static func loadConfigOrThrow(path: String? = nil) throws -> PippinConfig? {
        let configPath = path ?? defaultConfigPath()
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            throw ConfigError.invalid(path: configPath, detail: error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(PippinConfig.self, from: data)
        } catch {
            // Not "\(error)": a DecodingError can quote values, and the file may hold an API key.
            throw ConfigError.invalid(path: configPath, detail: error.localizedDescription)
        }
    }

    /// Lenient load: nil if the file is absent OR unparseable. Only for callers
    /// where falling back to defaults is harmless (display and performance
    /// preferences). Never use it to read a setting that restricts access.
    public static func loadConfig(path: String? = nil) -> PippinConfig? {
        try? loadConfigOrThrow(path: path)
    }

    /// Persist a config to disk, creating parent directories as needed. The
    /// file is replaced in one rename and is always mode 0600 (it can hold an
    /// API key).
    /// shortcut: no cross-process lock, so two concurrent edits can lose one; add an flock if writers multiply.
    public static func saveConfig(_ config: PippinConfig, path: String? = nil) throws {
        // Resolve symlinks so a linked config (dotfiles) is updated in place, not replaced by a regular file.
        let configPath = URL(fileURLWithPath: path ?? defaultConfigPath()).resolvingSymlinksInPath().path
        let dir = (configPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)

        let tempPath = "\(configPath).tmp-\(UUID().uuidString)"
        let fd = open(tempPath, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: tempPath])
        }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(tempPath, configPath) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: configPath])
            }
        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
            throw error
        }
    }

    /// Create the appropriate AIProvider from CLI flags, falling back to config file then defaults.
    /// - Parameters:
    ///   - providerFlag: Value of --provider CLI flag (nil if not set)
    ///   - modelFlag: Value of --model CLI flag (nil if not set)
    ///   - apiKeyFlag: Value of --api-key CLI flag (nil if not set)
    public static func make(
        providerFlag: String? = nil,
        modelFlag: String? = nil,
        apiKeyFlag: String? = nil
    ) throws -> any AIProvider {
        let config = try loadConfigOrThrow()
        let providerName = providerFlag ?? config?.ai?.provider ?? "ollama"

        switch providerName.lowercased() {
        case "ollama":
            let url = config?.ai?.ollama?.url ?? "http://localhost:11434"
            let model = modelFlag ?? config?.ai?.ollama?.model ?? "llama3.2"
            return OllamaProvider(baseURL: url, model: model)

        case "claude":
            let model = modelFlag ?? config?.ai?.claude?.model ?? "claude-sonnet-4-6"
            let key = try resolveClaudeAPIKey(flagValue: apiKeyFlag)
            return ClaudeProvider(model: model, apiKey: key)

        case "openai", "openai-compatible":
            let base = config?.ai?.openai?.baseURL ?? "http://localhost:11434/v1"
            let model = modelFlag ?? config?.ai?.openai?.model ?? "gpt-4o-mini"
            // Optional: local endpoints (llama.cpp, Ollama /v1, ...) need no key.
            let key = resolveOpenAIAPIKey(flagValue: apiKeyFlag, configKey: config?.ai?.openai?.apiKey)
            return OpenAIProvider(
                baseURL: base, model: model, apiKey: key,
                structuredOutputs: config?.ai?.openai?.structuredOutputs ?? false
            )

        default:
            throw AIProviderError.invalidProvider(providerName)
        }
    }

    /// Embedding backend names accepted by `ai.embeddings.provider` and `--provider`.
    public static let embeddingProviders = ["ollama", "openai"]

    /// Create the embedding backend for `mail index` / `mail search --semantic`.
    /// Precedence: CLI flags, then `ai.embeddings`, then Ollama defaults.
    /// `urlFlag` is the legacy `--ollama-url`; it applies only to Ollama.
    public static func makeEmbeddingProvider(
        providerFlag: String? = nil,
        modelFlag: String? = nil,
        urlFlag: String? = nil
    ) throws -> any EmbeddingProvider {
        try makeEmbeddingProvider(
            providerFlag: providerFlag, modelFlag: modelFlag, urlFlag: urlFlag, config: loadConfigOrThrow()
        )
    }

    /// As above with an already-loaded config (a default argument cannot throw).
    public static func makeEmbeddingProvider(
        providerFlag: String? = nil,
        modelFlag: String? = nil,
        urlFlag: String? = nil,
        config: PippinConfig?
    ) throws -> any EmbeddingProvider {
        let section = config?.ai?.embeddings
        let name = (providerFlag ?? section?.provider ?? "ollama").lowercased()
        switch name {
        case "ollama":
            let url = urlFlag ?? section?.baseURL ?? config?.ai?.ollama?.url ?? "http://localhost:11434"
            return OllamaEmbeddingProvider(baseURL: url, model: modelFlag ?? section?.model ?? "nomic-embed-text")
        case "openai", "openai-compatible":
            guard let model = modelFlag ?? section?.model else {
                throw MailAIError.embeddingModelRequired(name)
            }
            let base = section?.baseURL ?? config?.ai?.openai?.baseURL ?? "http://localhost:11434/v1"
            let key = resolveOpenAIAPIKey(
                flagValue: nil, configKey: section?.apiKey ?? config?.ai?.openai?.apiKey
            )
            return OpenAIEmbeddingProvider(baseURL: base, model: model, apiKey: key)
        default:
            throw MailAIError.unsupportedEmbeddingProvider(name)
        }
    }

    /// Transcription backend names accepted by `ai.transcription.provider`.
    public static let transcriptionProviders = ["mlx-audio", "apple", "openai"]

    /// Create the memo transcription backend from `ai.transcription`, defaulting to mlx-audio.
    public static func makeTranscriber() throws -> any Transcriber {
        try makeTranscriber(config: loadConfigOrThrow())
    }

    public static func makeTranscriber(config: PippinConfig?) throws -> any Transcriber {
        let section = config?.ai?.transcription
        let name = (section?.provider ?? "mlx-audio").lowercased()
        switch name {
        case "mlx-audio", "mlx":
            return section?.model.map { MLXAudioTranscriber(model: $0) } ?? MLXAudioTranscriber()
        case "apple":
            return AppleSpeechTranscriber(locale: section?.locale)
        case "openai", "openai-compatible":
            let base = section?.baseURL ?? config?.ai?.openai?.baseURL ?? "http://localhost:11434/v1"
            let key = resolveOpenAIAPIKey(
                flagValue: nil, configKey: section?.apiKey ?? config?.ai?.openai?.apiKey
            )
            return OpenAITranscriber(baseURL: base, model: section?.model ?? "whisper-1", apiKey: key)
        default:
            throw TranscriberError.unsupportedProvider(name)
        }
    }

    // MARK: - Private

    private static func resolveClaudeAPIKey(flagValue: String?) throws -> String {
        // 1. CLI flag
        if let key = flagValue, !key.isEmpty { return key }
        // 2. Environment variable
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty { return key }
        // 3. Vaultwarden via get-secret helper
        if let key = tryGetSecret("Anthropic API"), !key.isEmpty { return key }
        throw AIProviderError.missingAPIKey
    }

    /// Resolve the (optional) OpenAI-compatible API key: `--api-key` flag, then
    /// config `ai.openai.apiKey`, then `OPENAI_API_KEY`. Returns nil when none
    /// is set — local endpoints that don't authenticate are valid, so this
    /// never throws.
    private static func resolveOpenAIAPIKey(flagValue: String?, configKey: String?) -> String? {
        if let key = flagValue, !key.isEmpty { return key }
        if let key = configKey, !key.isEmpty { return key }
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty { return key }
        return nil
    }

    /// Try to retrieve a secret from Vaultwarden via the get-secret shell script.
    /// Returns nil if the script is not found or exits non-zero.
    private static func tryGetSecret(_ itemName: String) -> String? {
        let knownPaths = [
            "\(NSHomeDirectory())/.local/bin/get-secret",
        ]
        guard let binary = knownPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [itemName]
        let pipe = Pipe()
        process.standardOutput = pipe
        // Discard stderr at the OS level. Previously this was an undrained
        // Pipe(): a chatty get-secret (>64KB of stderr) would block on a full
        // pipe buffer and never exit, hanging waitUntilExit() forever.
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain stdout concurrently (so a large secret value can't deadlock on
        // the 64KB stdout buffer) and bound the wait so a wedged get-secret
        // (e.g. a vault prompt) can't hang the caller forever.
        nonisolated(unsafe) var outData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outData = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let timeoutItem = DispatchWorkItem {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(10), execute: timeoutItem)

        process.waitUntilExit()
        timeoutItem.cancel()
        group.wait()

        // Non-zero exit, launch failure, or SIGTERM/SIGKILL from the timeout
        // all surface as "no secret".
        guard process.terminationStatus == 0, process.terminationReason != .uncaughtSignal else { return nil }
        let output = (String(data: outData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }
}
