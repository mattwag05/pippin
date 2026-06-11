@testable import PippinLib
import XCTest

final class AIProviderTests: XCTestCase {
    // MARK: - OllamaProvider

    func testOllamaProviderInit() {
        let p = OllamaProvider()
        XCTAssertEqual(p.baseURL, "http://localhost:11434")
        XCTAssertEqual(p.model, "llama3.2")
    }

    func testOllamaProviderCustomInit() {
        let p = OllamaProvider(baseURL: "http://myhost:1234", model: "mistral")
        XCTAssertEqual(p.baseURL, "http://myhost:1234")
        XCTAssertEqual(p.model, "mistral")
    }

    // MARK: - ClaudeProvider

    func testClaudeProviderInit() {
        let p = ClaudeProvider(model: "claude-sonnet-4-6", apiKey: "test-key")
        XCTAssertEqual(p.model, "claude-sonnet-4-6")
    }

    // MARK: - AIProviderFactory config loading

    func testLoadConfigMissingFile() {
        let config = AIProviderFactory.loadConfig(path: "/nonexistent/path/config.json")
        XCTAssertNil(config)
    }

    func testLoadConfigValidJSON() throws {
        let tmpFile = NSTemporaryDirectory() + UUID().uuidString + ".json"
        let json = """
        {
          "ai": {
            "provider": "ollama",
            "ollama": { "url": "http://custom:11434", "model": "phi4" },
            "claude": { "model": "claude-opus-4-6" }
          }
        }
        """
        try json.write(toFile: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        let config = AIProviderFactory.loadConfig(path: tmpFile)
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.ai?.provider, "ollama")
        XCTAssertEqual(config?.ai?.ollama?.url, "http://custom:11434")
        XCTAssertEqual(config?.ai?.ollama?.model, "phi4")
        XCTAssertEqual(config?.ai?.claude?.model, "claude-opus-4-6")
    }

    func testLoadConfigInvalidJSON() throws {
        let tmpFile = NSTemporaryDirectory() + UUID().uuidString + ".json"
        try "not valid json {{{".write(toFile: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        let config = AIProviderFactory.loadConfig(path: tmpFile)
        XCTAssertNil(config)
    }

    func testMakeOllamaProvider() throws {
        let provider = try AIProviderFactory.make(providerFlag: "ollama", modelFlag: "llama3.2")
        XCTAssertTrue(provider is OllamaProvider)
        let ollama = try XCTUnwrap(provider as? OllamaProvider)
        XCTAssertEqual(ollama.model, "llama3.2")
    }

    func testMakeUnknownProviderThrows() {
        XCTAssertThrowsError(try AIProviderFactory.make(providerFlag: "grok")) { error in
            XCTAssertTrue(error is AIProviderError)
        }
    }

    // MARK: - OpenAIProvider (configurable OpenAI-compatible endpoints)

    func testOpenAIProviderInitDefaults() {
        let p = OpenAIProvider()
        XCTAssertEqual(p.baseURL, "http://localhost:11434/v1")
        XCTAssertEqual(p.model, "gpt-4o-mini")
    }

    func testOpenAIProviderTrimsTrailingSlash() {
        // "<base>/" + "/chat/completions" must not double up the slash.
        let p = OpenAIProvider(baseURL: "https://manifest.example/v1/", model: "x")
        XCTAssertEqual(p.baseURL, "https://manifest.example/v1")
    }

    func testOpenAIBuildRequestEndpointHeadersAndBody() throws {
        let p = OpenAIProvider(baseURL: "https://api.example/v1", model: "gpt-4o-mini", apiKey: "sk-test")
        let req = try p.buildRequest(prompt: "hello", system: "be brief")
        XCTAssertEqual(req.url?.absoluteString, "https://api.example/v1/chat/completions")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(req.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-4o-mini")
        XCTAssertEqual(json["stream"] as? Bool, false)
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"], "system")
        XCTAssertEqual(messages[0]["content"], "be brief")
        XCTAssertEqual(messages[1]["role"], "user")
        XCTAssertEqual(messages[1]["content"], "hello")
    }

    func testOpenAIBuildRequestOmitsAuthAndSystemWhenEmpty() throws {
        // Local endpoints (oMLX, llama.cpp, Ollama /v1) need no auth header.
        let p = OpenAIProvider(baseURL: "http://localhost:8080/v1", model: "local", apiKey: nil)
        let req = try p.buildRequest(prompt: "hi", system: "")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 1, "empty system → only the user message")
        XCTAssertEqual(messages[0]["role"], "user")
    }

    func testOpenAIEmptyApiKeyTreatedAsNoAuth() throws {
        let p = OpenAIProvider(baseURL: "http://x/v1", model: "m", apiKey: "")
        let req = try p.buildRequest(prompt: "hi", system: "")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"), "empty key must not send an Authorization header")
    }

    func testOpenAIParseCompletion() throws {
        let data = #"{"choices":[{"message":{"role":"assistant","content":"  Hello there.  "}}]}"#.data(using: .utf8)!
        XCTAssertEqual(try OpenAIProvider.parseCompletion(data), "Hello there.")
    }

    func testOpenAIParseCompletionMalformedThrows() {
        let data = #"{"choices":[]}"#.data(using: .utf8)!
        XCTAssertThrowsError(try OpenAIProvider.parseCompletion(data))
    }

    func testMakeOpenAIProvider() throws {
        let provider = try AIProviderFactory.make(providerFlag: "openai", modelFlag: "gpt-4o-mini")
        XCTAssertTrue(provider is OpenAIProvider)
        let o = try XCTUnwrap(provider as? OpenAIProvider)
        XCTAssertEqual(o.model, "gpt-4o-mini")
    }

    func testLoadConfigOpenAIBlock() throws {
        let tmpFile = NSTemporaryDirectory() + UUID().uuidString + ".json"
        let json = """
        {"ai":{"provider":"openai","openai":{"baseURL":"https://manifest.tail.ts.net/v1","model":"gpt-oss-120b","apiKey":"mnfst_x"}}}
        """
        try json.write(toFile: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }
        let config = AIProviderFactory.loadConfig(path: tmpFile)
        XCTAssertEqual(config?.ai?.provider, "openai")
        XCTAssertEqual(config?.ai?.openai?.baseURL, "https://manifest.tail.ts.net/v1")
        XCTAssertEqual(config?.ai?.openai?.model, "gpt-oss-120b")
        XCTAssertEqual(config?.ai?.openai?.apiKey, "mnfst_x")
    }

    // MARK: - resolveContacts config + precedence (pippin-1jm)

    func testLoadConfigResolveContactsFalse() throws {
        let tmpFile = NSTemporaryDirectory() + UUID().uuidString + ".json"
        try #"{"resolveContacts": false}"#.write(toFile: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }
        let config = AIProviderFactory.loadConfig(path: tmpFile)
        XCTAssertEqual(config?.resolveContacts, false)
    }

    func testResolveContactsDefaultsOnWhenConfigAbsent() {
        // No config and no flags → resolution ON (non-breaking default).
        XCTAssertTrue(AIProviderFactory.shouldResolveContacts(noContactsFlag: false))
    }

    func testResolveContactsDefaultsOnWhenConfigUnset() {
        // Config present but resolveContacts unset → ON.
        let config = PippinConfig(ai: nil, messages: nil, resolveContacts: nil)
        XCTAssertTrue(AIProviderFactory.shouldResolveContacts(noContactsFlag: false, config: config))
    }

    func testResolveContactsConfigFalseDisables() {
        let config = PippinConfig(ai: nil, messages: nil, resolveContacts: false)
        XCTAssertFalse(AIProviderFactory.shouldResolveContacts(noContactsFlag: false, config: config))
    }

    func testResolveContactsConfigTrueEnables() {
        let config = PippinConfig(ai: nil, messages: nil, resolveContacts: true)
        XCTAssertTrue(AIProviderFactory.shouldResolveContacts(noContactsFlag: false, config: config))
    }

    func testResolveContactsNoContactsFlagOverridesConfigTrue() {
        // --no-contacts wins over a config that enables resolution.
        let config = PippinConfig(ai: nil, messages: nil, resolveContacts: true)
        XCTAssertFalse(
            AIProviderFactory.shouldResolveContacts(noContactsFlag: true, contactsFlag: false, config: config)
        )
    }

    func testResolveContactsFlagOverridesConfigFalse() {
        // --contacts wins over a config that disables resolution.
        let config = PippinConfig(ai: nil, messages: nil, resolveContacts: false)
        XCTAssertTrue(
            AIProviderFactory.shouldResolveContacts(noContactsFlag: false, contactsFlag: true, config: config)
        )
    }

    func testResolveContactsNoContactsBeatsContactsWhenBothSet() {
        // If both flags are somehow set, OFF (the cheap/safe choice) wins.
        XCTAssertFalse(
            AIProviderFactory.shouldResolveContacts(noContactsFlag: true, contactsFlag: true, config: nil)
        )
    }

    // MARK: - AIProviderError descriptions

    func testErrorDescriptions() {
        XCTAssertNotNil(AIProviderError.networkError("oops").errorDescription)
        XCTAssertNotNil(AIProviderError.apiError(401, "unauthorized").errorDescription)
        XCTAssertNotNil(AIProviderError.timeout.errorDescription)
        XCTAssertNotNil(AIProviderError.decodingFailed("bad json").errorDescription)
        XCTAssertNotNil(AIProviderError.missingAPIKey.errorDescription)
        XCTAssertEqual(
            AIProviderError.providerUnreachable("ollama down").errorDescription,
            "ollama down"
        )
    }

    // MARK: - MCP context detection (pippin-5et)

    func testIsMCPContextDefaultsFalse() {
        // Tests don't run under PIPPIN_MCP=1 in this environment.
        XCTAssertFalse(isMCPContext())
    }

    func testAIRequestTimeoutSecondsRespectsMode() {
        // CLI default: long budget.
        XCTAssertEqual(aiRequestTimeoutSeconds(), 120)
    }

    // MARK: - Embedding request timeout policy

    //
    // Regression: OllamaEmbeddingProvider hardcoded 120s (single) / 300s (batch)
    // and ignored MCP context, so under PIPPIN_MCP=1 a slow embedding server
    // blew past MCPServerRuntime's 60s child cap → SIGKILL misreported as a
    // protocol error. requestTimeout(batch:) is now the single source of truth:
    // MCP → aiRequestTimeoutSeconds() (50s, < 60); CLI → 120s/300s.

    func testEmbeddingRequestTimeoutCLIBudgets() {
        XCTAssertFalse(isMCPContext(), "precondition: tests run outside MCP")
        XCTAssertEqual(OllamaEmbeddingProvider.requestTimeout(batch: false), 120,
                       "CLI single embed keeps the standard 120s budget")
        XCTAssertEqual(OllamaEmbeddingProvider.requestTimeout(batch: true), 300,
                       "CLI batch keeps the generous 300s budget")
    }

    func testEmbeddingRequestTimeoutRoutesThroughMCPAwareBudgetUnderMCP() throws {
        // Exercise the MCP branch by flipping the env var, restoring it after so
        // sibling tests (e.g. testIsMCPContextDefaultsFalse) are unaffected.
        let had = getenv("PIPPIN_MCP") != nil
        setenv("PIPPIN_MCP", "1", 1)
        defer { if !had { unsetenv("PIPPIN_MCP") } }
        guard isMCPContext() else {
            // ProcessInfo may snapshot env on some platforms; skip rather than flake.
            throw XCTSkip("env mutation not observed by ProcessInfo in this runtime")
        }
        let single = OllamaEmbeddingProvider.requestTimeout(batch: false)
        let batch = OllamaEmbeddingProvider.requestTimeout(batch: true)
        XCTAssertEqual(single, aiRequestTimeoutSeconds(), "MCP single uses the MCP-aware budget")
        XCTAssertEqual(batch, aiRequestTimeoutSeconds(), "MCP batch clamps to the MCP-aware budget")
        // The +5 semaphore slack in sendSynchronousRequest must still clear the cap.
        XCTAssertLessThan(Int(batch) + 5, 60, "MCP embedding budget must stay under the 60s child cap")
    }

    func testOllamaPreflightFailsFastWhenServerDown() throws {
        // Point at a port nothing is listening on; preflight must fail quickly
        // with a typed providerUnreachable error rather than waiting the full
        // request budget.
        let provider = OllamaProvider(baseURL: "http://127.0.0.1:1", model: "x")
        let start = Date()
        do {
            _ = try provider.complete(prompt: "hi", system: "")
            XCTFail("Expected preflight to throw")
        } catch let error as AIProviderError {
            switch error {
            case .providerUnreachable:
                break // expected
            default:
                XCTFail("Expected .providerUnreachable, got \(error)")
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 10, "Preflight must fail in well under 10s; took \(elapsed)s")
    }
}
