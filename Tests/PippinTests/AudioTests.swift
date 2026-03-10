@testable import PippinLib
import XCTest

final class AudioTests: XCTestCase {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    // MARK: - TranscriptionResult

    func testTranscriptionResultAllFields() throws {
        let result = TranscriptionResult(
            text: "Hello world",
            language: "en",
            duration: 3.5,
            modelUsed: "parakeet"
        )
        let data = try encoder.encode(result)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["text"] as? String, "Hello world")
        XCTAssertEqual(json["language"] as? String, "en")
        XCTAssertEqual(json["duration"] as? Double, 3.5)
        XCTAssertEqual(json["modelUsed"] as? String, "parakeet")
    }

    func testTranscriptionResultMinimalFields() throws {
        let result = TranscriptionResult(text: "Just the text")
        let data = try encoder.encode(result)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["text"] as? String, "Just the text")
        // Optional fields should encode as null or be absent — either is acceptable.
        // They must at least not crash.
        _ = json["language"]
        _ = json["duration"]
        _ = json["modelUsed"]
    }

    func testTranscriptionResultRoundTrip() throws {
        let original = TranscriptionResult(
            text: "Round trip test",
            language: "fr",
            duration: 10.25,
            modelUsed: "parakeet"
        )
        let data = try encoder.encode(original)
        let decoded = try decode(TranscriptionResult.self, from: data)

        XCTAssertEqual(decoded.text, original.text)
        XCTAssertEqual(decoded.language, original.language)
        XCTAssertEqual(decoded.duration, original.duration)
        XCTAssertEqual(decoded.modelUsed, original.modelUsed)
    }

    func testTranscriptionResultOptionalFieldsNilRoundTrip() throws {
        let original = TranscriptionResult(text: "No metadata")
        let data = try encoder.encode(original)
        let decoded = try decode(TranscriptionResult.self, from: data)

        XCTAssertEqual(decoded.text, "No metadata")
        XCTAssertNil(decoded.language)
        XCTAssertNil(decoded.duration)
        XCTAssertNil(decoded.modelUsed)
    }

    // MARK: - SpeechResult

    func testSpeechResultWithOutputPath() throws {
        let result = SpeechResult(
            outputPath: "/tmp/speech.wav",
            modelUsed: "kokoro",
            voiceUsed: "af_heart"
        )
        let data = try encoder.encode(result)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["outputPath"] as? String, "/tmp/speech.wav")
        XCTAssertEqual(json["modelUsed"] as? String, "kokoro")
        XCTAssertEqual(json["voiceUsed"] as? String, "af_heart")
    }

    func testSpeechResultNilOutputPath() throws {
        // When no output file is specified (audio plays to speaker), outputPath is nil.
        // Auto-synthesized Codable uses encodeIfPresent, so the key is absent when nil.
        let result = SpeechResult(modelUsed: "kokoro", voiceUsed: "af_sky")
        let data = try encoder.encode(result)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertFalse(json.keys.contains("outputPath"), "outputPath key is absent when nil (encodeIfPresent)")
        XCTAssertEqual(json["modelUsed"] as? String, "kokoro")
        XCTAssertEqual(json["voiceUsed"] as? String, "af_sky")
    }

    func testSpeechResultRoundTrip() throws {
        let original = SpeechResult(outputPath: "/out/result.wav", modelUsed: "kokoro", voiceUsed: "af_heart")
        let data = try encoder.encode(original)
        let decoded = try decode(SpeechResult.self, from: data)

        XCTAssertEqual(decoded.outputPath, original.outputPath)
        XCTAssertEqual(decoded.modelUsed, original.modelUsed)
        XCTAssertEqual(decoded.voiceUsed, original.voiceUsed)
    }

    func testSpeechResultRoundTripNilPath() throws {
        let original = SpeechResult(modelUsed: "kokoro", voiceUsed: "af_heart")
        let data = try encoder.encode(original)
        let decoded = try decode(SpeechResult.self, from: data)

        XCTAssertNil(decoded.outputPath)
        XCTAssertEqual(decoded.modelUsed, "kokoro")
        XCTAssertEqual(decoded.voiceUsed, "af_heart")
    }

    // MARK: - VoiceInfo

    func testVoiceInfoAllFields() throws {
        let voice = VoiceInfo(id: "af_heart", name: "Heart", language: "en", model: "kokoro")
        let data = try encoder.encode(voice)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["id"] as? String, "af_heart")
        XCTAssertEqual(json["name"] as? String, "Heart")
        XCTAssertEqual(json["language"] as? String, "en")
        XCTAssertEqual(json["model"] as? String, "kokoro")
    }

    func testVoiceInfoRoundTrip() throws {
        let original = VoiceInfo(id: "af_sky", name: "Sky", language: "en", model: "kokoro")
        let data = try encoder.encode(original)
        let decoded = try decode(VoiceInfo.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.language, original.language)
        XCTAssertEqual(decoded.model, original.model)
    }

    func testVoiceInfoArrayEncoding() throws {
        let voices = [
            VoiceInfo(id: "af_heart", name: "Heart", language: "en", model: "kokoro"),
            VoiceInfo(id: "bf_emma", name: "Emma", language: "en-GB", model: "kokoro"),
        ]
        let data = try encoder.encode(voices)
        let jsonArray = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )

        XCTAssertEqual(jsonArray.count, 2)
        XCTAssertEqual(jsonArray[0]["id"] as? String, "af_heart")
        XCTAssertEqual(jsonArray[1]["id"] as? String, "bf_emma")
        XCTAssertEqual(jsonArray[1]["language"] as? String, "en-GB")
    }

    func testVoiceInfoFromJSON() throws {
        let jsonStr = """
        {"id":"af_heart","language":"en","model":"kokoro","name":"Heart"}
        """
        let data = try XCTUnwrap(jsonStr.data(using: .utf8))
        let voice = try decode(VoiceInfo.self, from: data)

        XCTAssertEqual(voice.id, "af_heart")
        XCTAssertEqual(voice.name, "Heart")
        XCTAssertEqual(voice.language, "en")
        XCTAssertEqual(voice.model, "kokoro")
    }

    // MARK: - Codable conformance edge cases

    func testTranscriptionResultFromJSONWithAllOptionalsMissing() throws {
        let jsonStr = """
        {"text":"Minimal"}
        """
        let data = try XCTUnwrap(jsonStr.data(using: .utf8))
        let result = try decode(TranscriptionResult.self, from: data)

        XCTAssertEqual(result.text, "Minimal")
        XCTAssertNil(result.language)
        XCTAssertNil(result.duration)
        XCTAssertNil(result.modelUsed)
    }

    func testSpeechResultFromJSONWithNullOutputPath() throws {
        let jsonStr = """
        {"modelUsed":"kokoro","outputPath":null,"voiceUsed":"af_heart"}
        """
        let data = try XCTUnwrap(jsonStr.data(using: .utf8))
        let result = try decode(SpeechResult.self, from: data)

        XCTAssertNil(result.outputPath)
        XCTAssertEqual(result.modelUsed, "kokoro")
        XCTAssertEqual(result.voiceUsed, "af_heart")
    }
}
