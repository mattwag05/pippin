import AVFoundation
@testable import PippinLib
import XCTest

/// Per-feature AI backends (pippin-edjh): factory selection, wire formats,
/// model-aware embedding index, and doctor reporting.
final class ProviderBackendsTests: XCTestCase {
    private func config(_ json: String) throws -> PippinConfig {
        try JSONDecoder().decode(PippinConfig.self, from: Data(json.utf8))
    }

    // MARK: - Embedding factory

    func testEmbeddingDefaultsToOllamaWithLegacyStoreKey() throws {
        let provider = try AIProviderFactory.makeEmbeddingProvider(config: nil)
        let ollama = try XCTUnwrap(provider as? OllamaEmbeddingProvider)
        XCTAssertEqual(ollama.baseURL, "http://localhost:11434")
        XCTAssertEqual(ollama.model, "nomic-embed-text")
        // Indexes written before pippin-edjh stored the bare model name.
        XCTAssertEqual(provider.storeKey, "nomic-embed-text")
    }

    func testEmbeddingOllamaUsesConfiguredOllamaURL() throws {
        let cfg = try config(#"{"ai":{"ollama":{"url":"http://gpu.example:11434"}}}"#)
        let provider = try XCTUnwrap(AIProviderFactory.makeEmbeddingProvider(config: cfg) as? OllamaEmbeddingProvider)
        XCTAssertEqual(provider.baseURL, "http://gpu.example:11434")
    }

    func testEmbeddingFlagsOverrideConfig() throws {
        let cfg = try config(#"{"ai":{"embeddings":{"provider":"openai","model":"m"}}}"#)
        let provider = try AIProviderFactory.makeEmbeddingProvider(
            providerFlag: "ollama", modelFlag: "mxbai-embed-large", urlFlag: "http://flag:1", config: cfg
        )
        let ollama = try XCTUnwrap(provider as? OllamaEmbeddingProvider)
        XCTAssertEqual(ollama.model, "mxbai-embed-large")
        XCTAssertEqual(ollama.baseURL, "http://flag:1")
    }

    func testEmbeddingOpenAIRequiresModel() throws {
        let cfg = try config(#"{"ai":{"embeddings":{"provider":"openai"}}}"#)
        XCTAssertThrowsError(try AIProviderFactory.makeEmbeddingProvider(config: cfg)) { error in
            guard case MailAIError.embeddingModelRequired = error else {
                return XCTFail("expected embeddingModelRequired, got \(error)")
            }
        }
    }

    func testEmbeddingOpenAIFallsBackToOpenAISection() throws {
        let cfg = try config(#"""
        {"ai":{"openai":{"baseURL":"http://127.0.0.1:8000/v1/","apiKey":"k-123"},
               "embeddings":{"provider":"openai","model":"Qwen3-Embedding-0.6B"}}}
        """#)
        let provider = try XCTUnwrap(AIProviderFactory.makeEmbeddingProvider(config: cfg) as? OpenAIEmbeddingProvider)
        XCTAssertEqual(provider.baseURL, "http://127.0.0.1:8000/v1")
        XCTAssertEqual(provider.storeKey, "openai:Qwen3-Embedding-0.6B")
        let request = try provider.buildRequest(texts: ["a"], timeout: 10)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k-123")
    }

    func testEmbeddingUnknownProviderThrows() throws {
        XCTAssertThrowsError(try AIProviderFactory.makeEmbeddingProvider(providerFlag: "bogus", config: nil)) { error in
            guard case let MailAIError.unsupportedEmbeddingProvider(name) = error else {
                return XCTFail("expected unsupportedEmbeddingProvider, got \(error)")
            }
            XCTAssertEqual(name, "bogus")
        }
    }

    // MARK: - OpenAI-compatible embeddings wire format

    func testOpenAIEmbeddingRequestShape() throws {
        let provider = OpenAIEmbeddingProvider(baseURL: "http://h/v1", model: "m")
        let request = try provider.buildRequest(texts: ["one", "two"], timeout: 10)
        XCTAssertEqual(request.url?.absoluteString, "http://h/v1/embeddings")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "m")
        XCTAssertEqual(body["input"] as? [String], ["one", "two"])
    }

    func testOpenAIEmbeddingParseOrdersByIndex() throws {
        let json = #"{"data":[{"index":1,"embedding":[0.0,1.0]},{"index":0,"embedding":[1.0,0.0]}]}"#
        let vectors = try OpenAIEmbeddingProvider.parseEmbeddings(Data(json.utf8), expected: 2)
        XCTAssertEqual(vectors, [[1, 0], [0, 1]])
    }

    func testOpenAIEmbeddingParseRejectsCountMismatch() {
        let json = #"{"data":[{"index":0,"embedding":[1.0]}]}"#
        XCTAssertThrowsError(try OpenAIEmbeddingProvider.parseEmbeddings(Data(json.utf8), expected: 2))
    }

    // MARK: - Model-aware embedding index

    private func makeStore() throws -> EmbeddingStore {
        try EmbeddingStore(dbPath: NSTemporaryDirectory() + UUID().uuidString + ".db")
    }

    private func record(_ id: String, model: String, vector: [Float]) -> EmbeddingRecord {
        EmbeddingRecord(
            compoundId: id, embedding: serializeEmbedding(vector), bodyHash: "h",
            model: model, indexedAt: "2026-01-01T00:00:00Z", messageDate: "2026-01-01T00:00:00Z"
        )
    }

    func testIsCurrentRequiresMatchingModelWhenGiven() throws {
        let store = try makeStore()
        try store.upsert(record("a", model: "nomic-embed-text", vector: [1, 0]))
        let date = "2026-01-01T00:00:00Z"
        XCTAssertTrue(store.isCurrent(compoundId: "a", messageDate: date))
        XCTAssertTrue(store.isCurrent(compoundId: "a", messageDate: date, model: "nomic-embed-text"))
        XCTAssertFalse(store.isCurrent(compoundId: "a", messageDate: date, model: "openai:embed"))
    }

    private struct KeyedProvider: EmbeddingProvider {
        let key: String
        let vector: [Float]
        var storeKey: String? { key }
        func embed(text _: String) throws -> [Float] {
            vector
        }
    }

    private func loader(_ id: String) throws -> MailMessage {
        MailMessage(
            id: id, account: "acc", mailbox: "INBOX", subject: id, from: "f@example.com",
            to: [], date: "2026-01-01T00:00:00Z", read: false
        )
    }

    func testSemanticSearchRanksOnlySameModelVectors() throws {
        let store = try makeStore()
        // The other-model row would win on raw cosine; it must not be ranked at all.
        try store.upsert(record("other", model: "nomic-embed-text", vector: [1, 0]))
        try store.upsert(record("mine", model: "openai:embed", vector: [0.6, 0.8]))
        let results = try SemanticSearch.search(
            query: "q", store: store, provider: KeyedProvider(key: "openai:embed", vector: [1, 0]),
            limit: 10, messageLoader: loader
        )
        XCTAssertEqual(results.map(\.id), ["mine"])
    }

    func testSemanticSearchThrowsWhenActiveModelHasNoRows() throws {
        let store = try makeStore()
        try store.upsert(record("other", model: "nomic-embed-text", vector: [1, 0]))
        XCTAssertThrowsError(try SemanticSearch.search(
            query: "q", store: store, provider: KeyedProvider(key: "openai:embed", vector: [1, 0]),
            limit: 10, messageLoader: loader
        )) { error in
            guard case let MailAIError.noEmbeddingsForModel(key) = error else {
                return XCTFail("expected noEmbeddingsForModel, got \(error)")
            }
            XCTAssertEqual(key, "openai:embed")
        }
    }

    // MARK: - Transcription factory and wire format

    func testTranscriberDefaultsToMLXAudio() throws {
        let transcriber = try AIProviderFactory.makeTranscriber(config: nil)
        XCTAssertTrue(transcriber is MLXAudioTranscriber)
        XCTAssertEqual(transcriber.cacheProvider, "mlx-audio")
    }

    func testTranscriberSelectsAppleAndOpenAI() throws {
        let apple = try AIProviderFactory.makeTranscriber(
            config: config(#"{"ai":{"transcription":{"provider":"apple","locale":"en-GB"}}}"#)
        )
        XCTAssertEqual((apple as? AppleSpeechTranscriber)?.locale, "en-GB")

        let openai = try AIProviderFactory.makeTranscriber(config: config(#"""
        {"ai":{"openai":{"baseURL":"http://h/v1"},"transcription":{"provider":"openai","model":"whisper-large-v3"}}}
        """#))
        let typed = try XCTUnwrap(openai as? OpenAITranscriber)
        XCTAssertEqual(typed.baseURL, "http://h/v1")
        XCTAssertEqual(typed.cacheProvider, "openai:whisper-large-v3")
    }

    func testTranscriberUnknownProviderThrows() throws {
        XCTAssertThrowsError(try AIProviderFactory.makeTranscriber(
            config: config(#"{"ai":{"transcription":{"provider":"bogus"}}}"#)
        )) { error in
            guard case TranscriberError.unsupportedProvider = error else {
                return XCTFail("expected unsupportedProvider, got \(error)")
            }
        }
    }

    func testOpenAITranscriberMultipartShape() throws {
        let transcriber = OpenAITranscriber(baseURL: "http://h/v1/", model: "whisper-1", apiKey: "k")
        let request = try transcriber.buildRequest(
            audio: Data("RIFF".utf8), fileName: "memo.wav", timeout: 10, boundary: "B"
        )
        XCTAssertEqual(request.url?.absoluteString, "http://h/v1/audio/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=B")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        let body = try XCTUnwrap(String(data: XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nwhisper-1\r\n"))
        XCTAssertTrue(body.contains("filename=\"memo.wav\"\r\nContent-Type: audio/wav\r\n\r\nRIFF\r\n--B--"))

        let m4a = try transcriber.buildRequest(audio: Data(), fileName: "memo.m4a", timeout: 10, boundary: "B")
        XCTAssertTrue(String(decoding: m4a.httpBody ?? Data(), as: UTF8.self).contains("Content-Type: audio/mp4"))
    }

    /// Real on-device transcription of speech synthesized by `say`.
    func testAppleSpeechTranscribesSynthesizedSpeech() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        let path = NSTemporaryDirectory() + UUID().uuidString + ".m4a"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", path, "--file-format=m4af", "Call the dentist on Thursday."]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { throw XCTSkip("say could not synthesize audio") }

        let result: TranscriptionResult
        do {
            result = try AppleSpeechTranscriber(locale: "en-US").transcribe(audioPath: path)
        } catch let TranscriberError.failed(message) {
            throw XCTSkip("on-device speech unavailable: \(message)")
        }
        XCTAssertTrue(result.text.lowercased().contains("dentist"), "got: \(result.text)")
        XCTAssertEqual(result.modelUsed, "apple-speech")
    }

    // MARK: - Doctor

    private func probe(_ responses: [String: (Int, String)]) -> BackendProbe {
        BackendProbe { request in
            let url = request.url?.absoluteString ?? ""
            return responses[url].map { ($0.0, Data($0.1.utf8)) }
        }
    }

    private let unreachable = BackendProbe { _ in nil }

    /// pippin-c2zy: a remote Ollama failure must not send the user to install
    /// a local service on localhost.
    func testOllamaRemoteFailureAdviceNamesConfiguredEndpoint() throws {
        let cfg = try config(#"{"ai":{"ollama":{"url":"http://user:secret@ollama.invalid:11434"}}}"#)
        let check = checkOllama(config: cfg, probe: unreachable)
        XCTAssertEqual(check.status, .skip)
        let hint = try XCTUnwrap(check.remediation?.humanHint)
        XCTAssertTrue(hint.contains("http://ollama.invalid:11434"), hint)
        XCTAssertFalse(hint.contains("localhost"), hint)
        XCTAssertFalse(check.remediation?.shellCommand?.contains("brew install") ?? false)
        XCTAssertFalse(check.detail.contains("secret") || hint.contains("secret"), "credentials leaked")
    }

    func testOllamaLocalFailureAdviceInstallsOllama() {
        let check = checkOllama(config: nil, probe: unreachable)
        XCTAssertEqual(check.remediation?.shellCommand, "brew install ollama && ollama serve")
    }

    func testOllamaSkippedWhenNoFeatureUsesIt() throws {
        let cfg = try config(#"{"ai":{"provider":"openai","embeddings":{"provider":"openai","model":"m"}}}"#)
        let check = checkOllama(config: cfg, probe: unreachable)
        XCTAssertEqual(check.status, .skip)
        XCTAssertNil(check.remediation)
        XCTAssertEqual(check.detail, "not used by the current configuration")
    }

    func testOpenAIModelCheckOutcomes() {
        let models = #"{"data":[{"id":"served-model"}]}"#
        func check(_ responses: [String: (Int, String)], model: String = "served-model") -> DiagnosticCheck {
            checkOpenAIModel(
                checkName: "AI provider", feature: "AI features", baseURL: "http://h/v1", model: model,
                apiKey: nil, modelSetting: "ai.openai.model", probe: probe(responses)
            )
        }
        XCTAssertEqual(check(["http://h/v1/models": (200, models)]).status, .ok)
        let missing = check(["http://h/v1/models": (200, models)], model: "absent")
        XCTAssertEqual(missing.status, .fail)
        XCTAssertTrue(missing.remediation?.humanHint.contains("served-model") ?? false)
        XCTAssertEqual(check(["http://h/v1/models": (401, "")]).status, .fail)
        XCTAssertEqual(check([:]).status, .skip)
    }

    func testBackendChecksNameEachConfiguredFeature() throws {
        let cfg = try config(#"""
        {"ai":{"provider":"openai","openai":{"baseURL":"http://h/v1","model":"chat"},
               "embeddings":{"provider":"openai","model":"embed"},
               "transcription":{"provider":"openai","model":"stt"}}}
        """#)
        let models = #"{"data":[{"id":"chat"},{"id":"embed"},{"id":"stt"}]}"#
        let checks = backendChecks(config: cfg, probe: probe(["http://h/v1/models": (200, models)]))
        XCTAssertEqual(checks.map(\.name), ["Ollama", "AI provider", "Embeddings", "Transcription"])
        XCTAssertEqual(checks.map(\.status), [.skip, .ok, .ok, .ok])
        XCTAssertTrue(checks[2].detail.contains("embed"))
        XCTAssertTrue(checks[3].detail.contains("stt"))
    }

    func testDisplayEndpointStripsCredentialsAndQuery() {
        XCTAssertEqual(displayEndpoint("https://u:p@host.example:8443/v1/?token=x"), "https://host.example:8443/v1")
        XCTAssertEqual(displayEndpoint("not a url"), "the configured endpoint")
    }
}
