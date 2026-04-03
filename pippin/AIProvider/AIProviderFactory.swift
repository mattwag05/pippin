import Foundation

// MARK: - Config file model

public struct PippinConfig: Codable, Sendable {
    public var ai: AIConfig?

    public struct AIConfig: Codable, Sendable {
        public var provider: String?
        public var ollama: OllamaConfig?
        public var claude: ClaudeConfig?

        public struct OllamaConfig: Codable, Sendable {
            public var url: String?
            public var model: String?
        }

        public struct ClaudeConfig: Codable, Sendable {
            public var model: String?
        }
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

        default:
            throw AIProviderError.networkError("Unknown provider '\(providerName)'. Use 'ollama' or 'claude'.")
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
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.isEmpty ? nil : output
    }
}
