@testable import PippinLib
import XCTest

/// Tests for native structured-output (JSON) mode across providers (pippin-us2).
/// Body/request shape is verified directly (no network).
final class StructuredOutputTests: XCTestCase {
    private func bodyObject(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - AICompletionOptions

    func testCompletionOptionsDefaultsToNoJSON() {
        XCTAssertFalse(AICompletionOptions().jsonMode)
        XCTAssertTrue(AICompletionOptions(jsonMode: true).jsonMode)
        XCTAssertNil(AICompletionOptions().temperature)
        XCTAssertEqual(AICompletionOptions(temperature: 0).temperature, 0)
    }

    // MARK: - Ollama: format: "json"

    func testOllamaAddsFormatJSONWhenJSONMode() {
        let p = OllamaProvider(model: "gemma4:latest")
        let body = p.requestBody(prompt: "x", system: "y", jsonMode: true)
        XCTAssertEqual(body["format"] as? String, "json")
    }

    func testOllamaOmitsFormatWhenNotJSONMode() {
        let p = OllamaProvider(model: "gemma4:latest")
        let body = p.requestBody(prompt: "x", system: "y", jsonMode: false)
        XCTAssertNil(body["format"], "no format key on a free-text completion")
    }

    func testOllamaSerializesTemperatureOnlyWhenSupplied() {
        let provider = OllamaProvider(model: "gemma4:latest")
        XCTAssertNil(provider.requestBody(prompt: "x", system: "y", options: AICompletionOptions())["options"])
        let body = provider.requestBody(
            prompt: "x", system: "y", options: AICompletionOptions(temperature: 0)
        )
        let options = body["options"] as? [String: Any]
        XCTAssertEqual(options?["temperature"] as? Double, 0)
    }

    // MARK: - OpenAI: response_format (config-gated + prompt-guarded)

    func testOpenAIAddsResponseFormatWhenOptedInAndPromptMentionsJSON() throws {
        let p = OpenAIProvider(baseURL: "https://api.example/v1", model: "m", structuredOutputs: true)
        let req = try p.buildRequest(prompt: "Return ONLY a JSON object.", system: "be terse", jsonMode: true)
        let body = try bodyObject(req)
        let rf = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual(rf["type"] as? String, "json_object")
    }

    func testOpenAIOmitsResponseFormatWhenConfigNotOptedIn() throws {
        // jsonMode requested + prompt mentions json, but structuredOutputs is OFF.
        let p = OpenAIProvider(baseURL: "https://api.example/v1", model: "m", structuredOutputs: false)
        let req = try p.buildRequest(prompt: "Return ONLY JSON.", system: "", jsonMode: true)
        XCTAssertNil(try bodyObject(req)["response_format"], "config opt-in defaults OFF")
    }

    func testOpenAIOmitsResponseFormatWhenPromptLacksJSONWord() throws {
        // Opted in + jsonMode, but neither prompt nor system contains "json" —
        // sending response_format would 400, so it must be withheld.
        let p = OpenAIProvider(baseURL: "https://api.example/v1", model: "m", structuredOutputs: true)
        let req = try p.buildRequest(prompt: "Summarize this.", system: "be terse", jsonMode: true)
        XCTAssertNil(try bodyObject(req)["response_format"])
    }

    func testOpenAIOmitsResponseFormatWhenNotJSONMode() throws {
        let p = OpenAIProvider(baseURL: "https://api.example/v1", model: "m", structuredOutputs: true)
        let req = try p.buildRequest(prompt: "Return JSON.", system: "", jsonMode: false)
        XCTAssertNil(try bodyObject(req)["response_format"])
    }

    func testOpenAISerializesTemperatureOnlyWhenSupplied() throws {
        let provider = OpenAIProvider(baseURL: "https://api.example/v1", model: "m")
        let omitted = try bodyObject(provider.buildRequest(
            prompt: "x", system: "", options: AICompletionOptions()
        ))
        XCTAssertNil(omitted["temperature"])
        let supplied = try bodyObject(provider.buildRequest(
            prompt: "x", system: "", options: AICompletionOptions(temperature: 0)
        ))
        XCTAssertEqual(supplied["temperature"] as? Double, 0)
    }

    func testClaudeSerializesTemperatureOnlyWhenSupplied() throws {
        let provider = ClaudeProvider(model: "claude-sonnet-4-6", apiKey: "test")
        let omitted = try JSONSerialization.jsonObject(
            with: provider.requestBody(prompt: "x", system: "", options: AICompletionOptions())
        ) as? [String: Any]
        XCTAssertNil(omitted?["temperature"])
        let supplied = try JSONSerialization.jsonObject(
            with: provider.requestBody(
                prompt: "x", system: "", options: AICompletionOptions(temperature: 0)
            )
        ) as? [String: Any]
        XCTAssertEqual(supplied?["temperature"] as? Double, 0)
    }

    func testMentionsJSONIsCaseInsensitiveAcrossPromptAndSystem() {
        XCTAssertTrue(OpenAIProvider.mentionsJSON(prompt: "give me JSON", system: ""))
        XCTAssertTrue(OpenAIProvider.mentionsJSON(prompt: "x", system: "reply as json"))
        XCTAssertFalse(OpenAIProvider.mentionsJSON(prompt: "summarize", system: "be brief"))
    }

    // MARK: - Protocol default forwards (mocks / Claude get a no-op options path)

    private struct PlainProvider: AIProvider {
        let onComplete: @Sendable (String, String) -> String
        func complete(prompt: String, system: String) throws -> String {
            onComplete(prompt, system)
        }
    }

    func testOptionsDefaultForwardsToPlainComplete() throws {
        // A provider that implements only the 2-arg `complete` still satisfies the
        // options-taking requirement via the extension default (jsonMode ignored).
        let p = PlainProvider { prompt, _ in "got:\(prompt)" }
        let out = try p.complete(prompt: "hi", system: "", options: AICompletionOptions(jsonMode: true))
        XCTAssertEqual(out, "got:hi")
    }
}
