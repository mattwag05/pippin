import Foundation

// MARK: - Config file model

public struct PippinConfig: Codable, Sendable {
    public var ai: AIConfig?
    public var messages: MessagesConfig?

    /// Global default for Apple Contacts name resolution on Mail/Messages output.
    /// When `false`, sender/participant handles are NOT resolved to contact names,
    /// which skips the per-command `CNContactStore` enumeration. Useful for agents
    /// and the morning briefing that call `mail list` once per account + `messages
    /// list` — collapsing what would be N+1 address-book enumerations per run down
    /// to zero, without having to pass `--no-contacts` on every command. `nil` /
    /// absent keeps resolution ON (non-breaking default). A per-command
    /// `--no-contacts` / `--contacts` flag overrides this. Precedence is computed
    /// by `AIProviderFactory.shouldResolveContacts`.
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
        /// a homelab gateway, oMLX, vLLM, LM Studio, Ollama `/v1`, …).
        /// `baseURL` is the API root that `/chat/completions` is appended to
        /// (e.g. `https://manifest.tail6e035b.ts.net/v1`). `apiKey` is optional —
        /// omit it for local endpoints that don't authenticate.
        public struct OpenAIConfig: Codable, Sendable {
            public var baseURL: String?
            public var model: String?
            public var apiKey: String?
        }
    }

    public struct MessagesConfig: Codable, Sendable {
        public var excludedThreads: [String]?
        public var defaultWindowHours: Int?
        public var autonomousAllowlist: [String]?
    }
}

// MARK: - Factory

public enum AIProviderFactory {
    /// Default config file path.
    public static func defaultConfigPath() -> String {
        let home = NSHomeDirectory()
        return "\(home)/.config/pippin/config.json"
    }

    /// Load config from disk. Returns nil if file absent or unparseable.
    public static func loadConfig(path: String? = nil) -> PippinConfig? {
        let configPath = path ?? defaultConfigPath()
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
            let config = try? JSONDecoder().decode(PippinConfig.self, from: data)
        else {
            return nil
        }
        return config
    }

    /// Decide whether Mail/Messages output should resolve handles to Apple
    /// Contacts names, honoring precedence: explicit CLI flag > config > built-in
    /// default (ON).
    ///
    /// - Parameters:
    ///   - noContactsFlag: `true` when `--no-contacts` was passed (force OFF).
    ///   - contactsFlag:   `true` when `--contacts` was passed (force ON).
    ///   - config: Loaded config, or `nil`. `resolveContacts == false` disables.
    /// - Returns: `true` to build the contact index, `false` to skip it.
    ///
    /// `--no-contacts` wins over `--contacts` if both are somehow set (OFF is the
    /// safe/cheap choice). When neither flag is set, the config default applies;
    /// when the config is absent or `resolveContacts` is unset, resolution is ON.
    public static func shouldResolveContacts(
        noContactsFlag: Bool,
        contactsFlag: Bool = false,
        config: PippinConfig? = nil
    ) -> Bool {
        if noContactsFlag { return false }
        if contactsFlag { return true }
        return config?.resolveContacts ?? true
    }

    /// Persist a config to disk, creating parent directories as needed.
    public static func saveConfig(_ config: PippinConfig, path: String? = nil) throws {
        let configPath = path ?? defaultConfigPath()
        let dir = (configPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
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
        let config = loadConfig()
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
            // Optional: local endpoints (oMLX, llama.cpp, Ollama /v1) need no key.
            let key = resolveOpenAIAPIKey(flagValue: apiKeyFlag, configKey: config?.ai?.openai?.apiKey)
            return OpenAIProvider(baseURL: base, model: model, apiKey: key)

        default:
            throw AIProviderError.networkError(
                "Unknown provider '\(providerName)'. Use 'ollama', 'claude', or 'openai'."
            )
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
