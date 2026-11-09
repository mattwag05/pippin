import ArgumentParser
import Foundation

public struct AudioCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "audio",
        abstract: "Text-to-speech, speech-to-text, and audio model management.",
        subcommands: [Speak.self, Transcribe.self, Voices.self, Models.self]
    )

    public init() {}

    // MARK: - Speak

    public struct Speak: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "speak",
            abstract: "Synthesize speech from text using a TTS model."
        )

        @Argument(help: "Text to synthesize.")
        public var text: String

        @Option(name: .long, help: "TTS model to use (default: kokoro).")
        public var model: String = "kokoro"

        @Option(name: .long, help: "Voice identifier (default: af_heart).")
        public var voice: String = "af_heart"

        @Option(name: .shortAndLong, help: "Output file path. Omit to play via system audio.")
        public var outputFile: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            // isAvailable() probes via `which` + `python3 -c "import mlx_audio"`
            // subprocesses (Python startup can take ~1-2s); hop off the pool.
            guard await detachBlocking({ AudioBridge.isAvailable() }) else {
                throw AudioCommandError.mlxAudioNotAvailable
            }
            let result = try await detachBlocking {
                [text, model, voice, outputFile] in
                try AudioBridge.speak(
                    text: text,
                    model: model,
                    voice: voice,
                    outputPath: outputFile
                )
            }
            return AgentResult(result)
        }
    }

    // MARK: - Transcribe

    public struct Transcribe: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "transcribe",
            abstract: "Transcribe an audio file to text using a STT model."
        )

        @Argument(help: "Path to the audio file to transcribe.")
        public var file: String

        @Option(name: .long, help: "STT model to use (default: parakeet).")
        public var model: String = "parakeet"

        @Option(name: .long, help: "Transcription format: text (default), srt, or json.")
        public var transcriptionFormat: String = "text"

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            // isAvailable() probes via `which` + `python3 -c "import mlx_audio"`
            // subprocesses (Python startup can take ~1-2s); hop off the pool.
            guard await detachBlocking({ AudioBridge.isAvailable() }) else {
                throw AudioCommandError.mlxAudioNotAvailable
            }
            guard ["text", "srt", "json"].contains(transcriptionFormat) else {
                throw AudioCommandError(
                    errorDescription: "Invalid format '\(transcriptionFormat)'. Supported: text, srt, json."
                )
            }
            let result = try await detachBlocking {
                [file, model, transcriptionFormat] in
                try AudioBridge.transcribe(
                    filePath: file,
                    model: model,
                    outputFormat: transcriptionFormat
                )
            }
            return AgentResult(result)
        }
    }

    // MARK: - Voices

    public struct Voices: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "voices",
            abstract: "List available TTS voices."
        )

        @Option(name: .long, help: "TTS model to list voices for (default: kokoro).")
        public var model: String = "kokoro"

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            // isAvailable() probes via `which` + `python3 -c "import mlx_audio"`
            // subprocesses (Python startup can take ~1-2s); hop off the pool.
            guard await detachBlocking({ AudioBridge.isAvailable() }) else {
                throw AudioCommandError.mlxAudioNotAvailable
            }
            let voices = try await detachBlocking { [model] in
                try AudioBridge.listVoices(model: model)
            }
            return AgentResult(voices)
        }
    }

    // MARK: - Models

    public struct Models: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "models",
            abstract: "List available STT/TTS models."
        )

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            // isAvailable() probes via `which` + `python3 -c "import mlx_audio"`
            // subprocesses (Python startup can take ~1-2s); hop off the pool.
            guard await detachBlocking({ AudioBridge.isAvailable() }) else {
                throw AudioCommandError.mlxAudioNotAvailable
            }
            let models = try await detachBlocking { try AudioBridge.listModels() }
            return AgentResult(models)
        }
    }
}

// MARK: - AudioCommandError

private struct AudioCommandError: LocalizedError {
    let errorDescription: String?

    static let mlxAudioNotAvailable = AudioCommandError(
        errorDescription: "mlx-audio is not available. Install with: pip install mlx-audio"
    )
}
