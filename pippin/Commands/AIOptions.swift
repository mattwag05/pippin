import ArgumentParser

/// The provider, model and API key flags of an AI-backed command, declared
/// once. Commands whose flags carry different help text (`do`, `mail triage`,
/// `mail sanitize`, `mail list --summarize`) keep their own declarations.
public struct AIOptions: ParsableArguments, Sendable {
    @Option(name: .long, help: "AI provider: ollama, claude, openai, or apple (default: ollama).")
    public var provider: String?

    @Option(name: .long, help: "Model name (provider-specific default).")
    public var model: String?

    @Option(name: .long, help: "API key for Claude provider.")
    public var apiKey: String?

    public init() {}
}

/// A command that takes `AIOptions`. The forwarding properties let its body
/// read `provider`, `model` and `apiKey` as if they were declared on it.
public protocol AIFlagged {
    var ai: AIOptions { get }
}

public extension AIFlagged {
    var provider: String? {
        ai.provider
    }

    var model: String? {
        ai.model
    }

    var apiKey: String? {
        ai.apiKey
    }
}
