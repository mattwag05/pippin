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

    public struct Speak: AsyncParsableCommand {
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
        public var output: String?

        @OptionGroup public var outputOptions: OutputOptions

        public init() {}

        public mutating func run() async throws {
            guard AudioBridge.isAvailable() else {
                throw AudioCommandError.mlxAudioNotAvailable
            }
            let result = try AudioBridge.speak(
                text: text,
                model: model,
                voice: voice,
                outputPath: output
            )
            if outputOptions.isJSON {
                try printJSON(result)
            } else {
                if let path = result.outputPath {
                    print("Saved to: \(path)")
                } else {
                    print("Played via system audio.")
                }
                print("Model: \(result.modelUsed)  Voice: \(result.voiceUsed)")
            }
        }
    }

    // MARK: - Transcribe

    public struct Transcribe: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "transcribe",
            abstract: "Transcribe an audio file to text using a STT model."
        )

        @Argument(help: "Path to the audio file to transcribe.")
        public var file: String

        @Option(name: .long, help: "STT model to use (default: parakeet).")
        public var model: String = "parakeet"

        @Option(name: .long, help: "Output format: text (default), srt, or json.")
        public var format: String = "text"

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            guard AudioBridge.isAvailable() else {
                throw AudioCommandError.mlxAudioNotAvailable
            }
            let result = try AudioBridge.transcribe(
                filePath: file,
                model: model,
                outputFormat: format
            )
            if output.isJSON {
                try printJSON(result)
            } else {
                print(result.text)
                if let language = result.language {
                    print("Language: \(language)")
                }
                if let duration = result.duration {
                    print("Duration: \(String(format: "%.1f", duration))s")
                }
            }
        }
    }

    // MARK: - Voices

    public struct Voices: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "voices",
            abstract: "List available TTS voices."
        )

        @Option(name: .long, help: "TTS model to list voices for (default: kokoro).")
        public var model: String = "kokoro"

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            guard AudioBridge.isAvailable() else {
                throw AudioCommandError.mlxAudioNotAvailable
            }
            let voices = try AudioBridge.listVoices(model: model)
            if output.isJSON {
                try printJSON(voices)
            } else {
                if voices.isEmpty {
                    print("No voices found for model '\(model)'.")
                    return
                }
                let idWidth = voices.map { $0.id.count }.max() ?? 10
                let nameWidth = voices.map { $0.name.count }.max() ?? 10
                print(String(format: "%-\(idWidth)s  %-\(nameWidth)s  %s", "ID", "Name", "Language"))
                print(String(repeating: "-", count: idWidth + nameWidth + 14))
                for v in voices {
                    print(String(format: "%-\(idWidth)s  %-\(nameWidth)s  %s", v.id, v.name, v.language))
                }
            }
        }
    }

    // MARK: - Models

    public struct Models: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "models",
            abstract: "List available STT/TTS models."
        )

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            guard AudioBridge.isAvailable() else {
                throw AudioCommandError.mlxAudioNotAvailable
            }
            let models = try AudioBridge.listModels()
            if output.isJSON {
                try printJSON(models)
            } else {
                if models.isEmpty {
                    print("No models found.")
                    return
                }
                for m in models {
                    print(m)
                }
            }
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
