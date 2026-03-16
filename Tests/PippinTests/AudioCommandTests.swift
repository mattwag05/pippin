@testable import PippinLib
import XCTest

final class AudioCommandTests: XCTestCase {
    // MARK: - AudioCommand Configuration

    func testAudioCommandName() {
        XCTAssertEqual(AudioCommand.configuration.commandName, "audio")
    }

    func testAudioCommandHasExpectedSubcommands() {
        let subcommands = AudioCommand.configuration.subcommands
        let names = subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("speak"))
        XCTAssertTrue(names.contains("transcribe"))
        XCTAssertTrue(names.contains("voices"))
        XCTAssertTrue(names.contains("models"))
    }

    // MARK: - Subcommand Names

    func testSpeakCommandName() {
        XCTAssertEqual(AudioCommand.Speak.configuration.commandName, "speak")
    }

    func testTranscribeCommandName() {
        XCTAssertEqual(AudioCommand.Transcribe.configuration.commandName, "transcribe")
    }

    func testVoicesCommandName() {
        XCTAssertEqual(AudioCommand.Voices.configuration.commandName, "voices")
    }

    func testModelsCommandName() {
        XCTAssertEqual(AudioCommand.Models.configuration.commandName, "models")
    }

    // MARK: - AudioCommand.Speak Parse Tests

    func testSpeakRequiresTextArgument() {
        XCTAssertThrowsError(try AudioCommand.Speak.parse([]))
    }

    func testSpeakParsesTextArgument() throws {
        let cmd = try AudioCommand.Speak.parse(["Hello world"])
        XCTAssertEqual(cmd.text, "Hello world")
    }

    func testSpeakDefaultModel() throws {
        let cmd = try AudioCommand.Speak.parse(["Hello"])
        XCTAssertEqual(cmd.model, "kokoro")
    }

    func testSpeakDefaultVoice() throws {
        let cmd = try AudioCommand.Speak.parse(["Hello"])
        XCTAssertEqual(cmd.voice, "af_heart")
    }

    func testSpeakDefaultOutputFileIsNil() throws {
        let cmd = try AudioCommand.Speak.parse(["Hello"])
        XCTAssertNil(cmd.outputFile)
    }

    func testSpeakCustomModel() throws {
        let cmd = try AudioCommand.Speak.parse(["Hello", "--model", "custom-model"])
        XCTAssertEqual(cmd.model, "custom-model")
    }

    func testSpeakCustomVoice() throws {
        let cmd = try AudioCommand.Speak.parse(["Hello", "--voice", "en_us"])
        XCTAssertEqual(cmd.voice, "en_us")
    }

    func testSpeakOutputFileLongForm() throws {
        let cmd = try AudioCommand.Speak.parse(["Hello", "--output-file", "/tmp/out.wav"])
        XCTAssertEqual(cmd.outputFile, "/tmp/out.wav")
    }

    func testSpeakOutputFileShortForm() throws {
        let cmd = try AudioCommand.Speak.parse(["Hello", "-o", "/tmp/out.wav"])
        XCTAssertEqual(cmd.outputFile, "/tmp/out.wav")
    }

    func testSpeakValidParseNoThrow() {
        XCTAssertNoThrow(try AudioCommand.Speak.parse(["Hello world"]))
    }

    func testSpeakWithAllOptions() throws {
        let cmd = try AudioCommand.Speak.parse([
            "Test text",
            "--model", "custom",
            "--voice", "en_voice",
            "--output-file", "/tmp/speech.wav",
        ])
        XCTAssertEqual(cmd.text, "Test text")
        XCTAssertEqual(cmd.model, "custom")
        XCTAssertEqual(cmd.voice, "en_voice")
        XCTAssertEqual(cmd.outputFile, "/tmp/speech.wav")
    }

    // MARK: - AudioCommand.Transcribe Parse Tests

    func testTranscribeRequiresFileArgument() {
        XCTAssertThrowsError(try AudioCommand.Transcribe.parse([]))
    }

    func testTranscribeParsesFileArgument() throws {
        let cmd = try AudioCommand.Transcribe.parse(["/tmp/audio.m4a"])
        XCTAssertEqual(cmd.file, "/tmp/audio.m4a")
    }

    func testTranscribeDefaultModel() throws {
        let cmd = try AudioCommand.Transcribe.parse(["/tmp/audio.m4a"])
        XCTAssertEqual(cmd.model, "parakeet")
    }

    func testTranscribeDefaultFormat() throws {
        let cmd = try AudioCommand.Transcribe.parse(["/tmp/audio.m4a"])
        XCTAssertEqual(cmd.transcriptionFormat, "text")
    }

    func testTranscribeCustomModel() throws {
        let cmd = try AudioCommand.Transcribe.parse(["/tmp/audio.m4a", "--model", "whisper"])
        XCTAssertEqual(cmd.model, "whisper")
    }

    func testTranscribeCustomFormat() throws {
        let cmd = try AudioCommand.Transcribe.parse(["/tmp/audio.m4a", "--transcription-format", "json"])
        XCTAssertEqual(cmd.transcriptionFormat, "json")
    }

    func testTranscribeValidParseNoThrow() {
        XCTAssertNoThrow(try AudioCommand.Transcribe.parse(["/tmp/audio.m4a"]))
    }

    // MARK: - AudioCommand.Voices Parse Tests

    func testVoicesRequiresNoArguments() {
        XCTAssertNoThrow(try AudioCommand.Voices.parse([]))
    }

    func testVoicesDefaultModel() throws {
        let cmd = try AudioCommand.Voices.parse([])
        XCTAssertEqual(cmd.model, "kokoro")
    }

    func testVoicesCustomModel() throws {
        let cmd = try AudioCommand.Voices.parse(["--model", "custom-tts"])
        XCTAssertEqual(cmd.model, "custom-tts")
    }

    // MARK: - AudioCommand.Models Parse Tests

    func testModelsRequiresNoArguments() {
        XCTAssertNoThrow(try AudioCommand.Models.parse([]))
    }

    // MARK: - AudioBridgeError errorDescription

    func testNotAvailableErrorDescription() {
        let error = AudioBridgeError.notAvailable
        XCTAssertEqual(error.errorDescription, "mlx-audio is not available. Install with: pip install mlx-audio")
    }

    func testProcessFailedErrorDescription() {
        let error = AudioBridgeError.processFailed("stderr output")
        XCTAssertEqual(error.errorDescription, "Audio process failed: stderr output")
    }

    func testTimeoutErrorDescription() {
        let error = AudioBridgeError.timeout
        XCTAssertEqual(error.errorDescription, "Audio process timed out")
    }

    func testDecodingFailedErrorDescription() {
        let error = AudioBridgeError.decodingFailed("bad json")
        XCTAssertEqual(error.errorDescription, "Failed to decode audio output: bad json")
    }
}
