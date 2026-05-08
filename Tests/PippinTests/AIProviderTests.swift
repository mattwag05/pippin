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
