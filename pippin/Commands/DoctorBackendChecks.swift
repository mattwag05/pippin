import Foundation
import Speech

// MARK: - Per-feature AI backend checks (pippin-edjh)

/// Network access for the backend checks, injectable so tests can simulate an
/// unreachable or remote endpoint without a server.
struct BackendProbe: Sendable {
    /// Returns the HTTP status and body, or nil when the request failed.
    var send: @Sendable (URLRequest) -> (Int, Data)?

    static let live = BackendProbe { request in
        guard let (data, response) = try? sendSynchronousRequest(request, waitTimeoutSeconds: 5) else {
            return nil
        }
        return (response.statusCode, data)
    }
}

/// Doctor checks for the three AI-backed features: completions (`ai.provider`),
/// embeddings (`ai.embeddings`), and memo transcription (`ai.transcription`).
/// Each check names the backend the configuration actually selects.
func backendChecks(config: PippinConfig?, probe: BackendProbe = .live) -> [DiagnosticCheck] {
    var checks = [checkOllama(config: config, probe: probe)]
    let completion = (config?.ai?.provider ?? "ollama").lowercased()
    if completion != "ollama" {
        checks.append(checkCompletionProvider(name: completion, config: config, probe: probe))
    }
    checks.append(checkEmbeddings(config: config, probe: probe))
    checks.append(checkTranscription(config: config, probe: probe))
    return checks
}

/// The configured features that call Ollama, for the Ollama check's detail.
func ollamaFeatures(config: PippinConfig?) -> [String] {
    var features: [String] = []
    if (config?.ai?.provider ?? "ollama").lowercased() == "ollama" {
        features.append("AI features (summaries, triage, extract, smart-create, do)")
    }
    if (config?.ai?.embeddings?.provider ?? "ollama").lowercased() == "ollama" {
        features.append("`mail index` and `mail search --semantic`")
    }
    return features
}

/// The endpoint without credentials, query, or fragment, safe to print.
func displayEndpoint(_ raw: String) -> String {
    guard var components = URLComponents(string: raw), components.host != nil else {
        return "the configured endpoint"
    }
    components.user = nil
    components.password = nil
    components.query = nil
    components.fragment = nil
    if components.path.hasSuffix("/") { components.path.removeLast() }
    return components.string ?? "the configured endpoint"
}

func isLocalEndpoint(_ raw: String) -> Bool {
    let host = URLComponents(string: raw)?.host?.lowercased() ?? ""
    return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".localhost")
}

func checkOllama(config: PippinConfig?, probe: BackendProbe) -> DiagnosticCheck {
    let features = ollamaFeatures(config: config)
    guard !features.isEmpty else {
        return DiagnosticCheck(name: "Ollama", status: .skip, detail: "not used by the current configuration")
    }
    let baseURL = config?.ai?.ollama?.url ?? "http://localhost:11434"
    let endpoint = displayEndpoint(baseURL)
    guard let versionURL = URL(string: "\(baseURL)/api/version") else {
        return DiagnosticCheck(name: "Ollama", status: .skip, detail: "invalid URL in ai.ollama.url")
    }
    var request = URLRequest(url: versionURL, timeoutInterval: 3)
    request.httpMethod = "GET"
    guard let (status, _) = probe.send(request), status == 200 else {
        let needed = features.joined(separator: " and ")
        let remediation = isLocalEndpoint(baseURL)
            ? Remediation(
                humanHint: "Ollama is not reachable at \(endpoint). It is optional; only \(needed) use it. Install and start it, or choose another backend in ~/.config/pippin/config.json.",
                doctorCheck: "Ollama",
                shellCommand: "brew install ollama && ollama serve"
            )
            : Remediation(
                humanHint: "The Ollama service configured at \(endpoint) (ai.ollama.url) is not reachable. Check that host and its Ollama service, or change ai.ollama.url. It is optional; only \(needed) use it.",
                doctorCheck: "Ollama",
                shellCommand: "curl -sS \(endpoint)/api/version"
            )
        return DiagnosticCheck(
            name: "Ollama",
            status: .skip,
            detail: "not reachable at \(endpoint); optional, used by \(needed)",
            remediation: remediation
        )
    }
    // Model presence matters only when Ollama serves completions.
    guard (config?.ai?.provider ?? "ollama").lowercased() == "ollama" else {
        return DiagnosticCheck(name: "Ollama", status: .ok, detail: "reachable at \(endpoint)")
    }
    // Default mirrors AIProviderFactory.make.
    let configuredModel = config?.ai?.ollama?.model ?? "llama3.2"
    if let modelStatus = checkOllamaModel(baseURL: baseURL, configuredModel: configuredModel) {
        return modelStatus
    }
    return DiagnosticCheck(name: "Ollama", status: .ok, detail: "reachable at \(endpoint); model \(configuredModel) pulled")
}

/// `ai.provider` when it is not Ollama.
func checkCompletionProvider(name: String, config: PippinConfig?, probe: BackendProbe) -> DiagnosticCheck {
    let checkName = "AI provider"
    switch name {
    case "claude":
        return DiagnosticCheck(name: checkName, status: .ok, detail: "claude \(config?.ai?.claude?.model ?? "claude-sonnet-4-6") (API key checked at use)")
    case "openai", "openai-compatible":
        let section = config?.ai?.openai
        return checkOpenAIModel(
            checkName: checkName, feature: "AI features",
            baseURL: section?.baseURL ?? "http://localhost:11434/v1",
            model: section?.model ?? "gpt-4o-mini", apiKey: section?.apiKey,
            modelSetting: "ai.openai.model", probe: probe
        )
    default:
        return DiagnosticCheck(
            name: checkName, status: .fail, detail: "unknown ai.provider '\(name)'",
            remediation: Remediation(
                humanHint: "Set ai.provider in ~/.config/pippin/config.json to ollama, claude, or openai.",
                doctorCheck: checkName
            )
        )
    }
}

func checkEmbeddings(config: PippinConfig?, probe: BackendProbe) -> DiagnosticCheck {
    let checkName = "Embeddings"
    let section = config?.ai?.embeddings
    let name = (section?.provider ?? "ollama").lowercased()
    switch name {
    case "ollama":
        let model = section?.model ?? "nomic-embed-text"
        let url = section?.baseURL ?? config?.ai?.ollama?.url ?? "http://localhost:11434"
        guard let probeURL = URL(string: "\(url)/api/version"),
              let (status, _) = probe.send(URLRequest(url: probeURL, timeoutInterval: 3)), status == 200
        else {
            return DiagnosticCheck(
                name: checkName, status: .skip,
                detail: "ollama \(model) at \(displayEndpoint(url)) not reachable; see the Ollama check, or set ai.embeddings.provider to openai"
            )
        }
        return DiagnosticCheck(name: checkName, status: .ok, detail: "ollama \(model) at \(displayEndpoint(url))")
    case "openai", "openai-compatible":
        guard let model = section?.model else {
            return DiagnosticCheck(
                name: checkName, status: .fail, detail: "openai embeddings need ai.embeddings.model",
                remediation: Remediation(
                    humanHint: MailAIError.embeddingModelRequired(name).errorDescription ?? "",
                    doctorCheck: checkName
                )
            )
        }
        return checkOpenAIModel(
            checkName: checkName, feature: "`mail index` and `mail search --semantic`",
            baseURL: section?.baseURL ?? config?.ai?.openai?.baseURL ?? "http://localhost:11434/v1",
            model: model, apiKey: section?.apiKey ?? config?.ai?.openai?.apiKey,
            modelSetting: "ai.embeddings.model", probe: probe
        )
    default:
        return DiagnosticCheck(
            name: checkName, status: .fail, detail: "unknown ai.embeddings.provider '\(name)'",
            remediation: Remediation(
                humanHint: MailAIError.unsupportedEmbeddingProvider(name).errorDescription ?? "",
                doctorCheck: checkName
            )
        )
    }
}

func checkTranscription(config: PippinConfig?, probe: BackendProbe) -> DiagnosticCheck {
    let checkName = "Transcription"
    let section = config?.ai?.transcription
    let name = (section?.provider ?? "mlx-audio").lowercased()
    switch name {
    case "mlx-audio", "mlx":
        return checkMLXAudio()
    case "apple":
        guard #available(macOS 26, *) else {
            return DiagnosticCheck(name: checkName, status: .fail, detail: "apple transcription requires macOS 26 or later")
        }
        let requested = section?.locale.map(Locale.init(identifier:)) ?? Locale.current
        let supported = try? waitForAsync(timeoutSeconds: 5) {
            await SpeechTranscriber.supportedLocale(equivalentTo: requested)?.identifier
        }
        guard let locale = supported ?? nil else {
            return DiagnosticCheck(
                name: checkName, status: .fail,
                detail: "apple (SpeechAnalyzer) does not support locale \(requested.identifier)",
                remediation: Remediation(
                    humanHint: "Set ai.transcription.locale in ~/.config/pippin/config.json to a supported locale such as en-US.",
                    doctorCheck: checkName
                )
            )
        }
        return DiagnosticCheck(name: checkName, status: .ok, detail: "apple (SpeechAnalyzer, on-device), locale \(locale)")
    case "openai", "openai-compatible":
        return checkOpenAIModel(
            checkName: checkName, feature: "memo transcription",
            baseURL: section?.baseURL ?? config?.ai?.openai?.baseURL ?? "http://localhost:11434/v1",
            model: section?.model ?? "whisper-1", apiKey: section?.apiKey ?? config?.ai?.openai?.apiKey,
            modelSetting: "ai.transcription.model", probe: probe
        )
    default:
        return DiagnosticCheck(
            name: checkName, status: .fail, detail: "unknown ai.transcription.provider '\(name)'",
            remediation: Remediation(
                humanHint: TranscriberError.unsupportedProvider(name).errorDescription ?? "",
                doctorCheck: checkName
            )
        )
    }
}

/// `GET {baseURL}/models` and confirm `model` is served. Unreachable is a
/// skip (the feature is optional); a reachable server that lacks the model
/// is a failure, because every call would then fail.
func checkOpenAIModel(
    checkName: String,
    feature: String,
    baseURL: String,
    model: String,
    apiKey: String?,
    modelSetting: String,
    probe: BackendProbe
) -> DiagnosticCheck {
    let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
    let endpoint = displayEndpoint(base)
    guard let url = URL(string: "\(base)/models") else {
        return DiagnosticCheck(name: checkName, status: .fail, detail: "invalid base URL for \(feature)")
    }
    var request = URLRequest(url: url, timeoutInterval: 3)
    request.httpMethod = "GET"
    if let apiKey, !apiKey.isEmpty {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    guard let (status, data) = probe.send(request) else {
        return DiagnosticCheck(
            name: checkName, status: .skip,
            detail: "openai-compatible endpoint \(endpoint) not reachable; optional, used by \(feature)",
            remediation: Remediation(
                humanHint: "Start the OpenAI-compatible server at \(endpoint), or point \(feature) at another backend in ~/.config/pippin/config.json.",
                doctorCheck: checkName
            )
        )
    }
    guard status == 200 else {
        let auth = status == 401 || status == 403
        return DiagnosticCheck(
            name: checkName, status: .fail,
            detail: "openai-compatible endpoint \(endpoint) returned HTTP \(status)",
            remediation: Remediation(
                humanHint: auth
                    ? "The endpoint at \(endpoint) rejected the API key. Update the apiKey for \(feature) in ~/.config/pippin/config.json."
                    : "The endpoint at \(endpoint) failed its model listing. Check the server.",
                doctorCheck: checkName
            )
        )
    }
    let served = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]])?
        .compactMap { $0["id"] as? String }
    if let served, !served.contains(model) {
        return DiagnosticCheck(
            name: checkName, status: .fail,
            detail: "openai-compatible \(endpoint) does not serve \(model)",
            remediation: Remediation(
                humanHint: "Set \(modelSetting) in ~/.config/pippin/config.json to a model the server lists: \(served.sorted().prefix(5).joined(separator: ", ")).",
                doctorCheck: checkName,
                shellCommand: "curl -s \(endpoint)/models"
            )
        )
    }
    return DiagnosticCheck(name: checkName, status: .ok, detail: "openai-compatible \(model) at \(endpoint)")
}
