import Foundation

// MARK: - AudioBridgeError

public enum AudioBridgeError: LocalizedError, Sendable {
    /// mlx-audio Python package is not installed or importable.
    case notAvailable
    /// The subprocess exited with a non-zero status.
    case processFailed(String)
    /// The subprocess was killed due to exceeding the timeout.
    case timeout
    /// The output could not be decoded into the expected type.
    case decodingFailed(String)
    /// Installed mlx-audio version doesn't match the pinned version.
    /// Surfaces installed-vs-pinned so the remediation can be exact.
    case versionMismatch(installed: String, pinned: String)

    public var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "mlx-audio is not available. Install with: pip install mlx-audio"
        case let .processFailed(stderr):
            return "Audio process failed: \(stderr)"
        case .timeout:
            return "Audio process timed out"
        case let .decodingFailed(detail):
            return "Failed to decode audio output: \(detail)"
        case let .versionMismatch(installed, pinned):
            return """
            mlx-audio version mismatch: installed \(installed), pippin expects \(pinned). \
            Run: pipx install 'mlx-audio==\(pinned)' --force
            """
        }
    }

    /// Raw technical detail for debugging — do not write to stdout
    public var debugDetail: String? {
        switch self {
        case let .processFailed(stderr): return stderr
        case let .decodingFailed(detail): return detail
        default: return nil
        }
    }
}

extension AudioBridgeError: RemediableError {
    public var agentCode: String {
        switch self {
        case .notAvailable: return "not_available"
        case .processFailed: return "process_failed"
        case .timeout: return "timeout"
        case .decodingFailed: return "decoding_failed"
        case .versionMismatch: return "version_mismatch"
        }
    }

    public var nextStep: NextStep {
        switch self {
        case .notAvailable: return .human("Install mlx-audio with `pipx install mlx-audio`.")
        case .processFailed: return .call(tool: "doctor", argv: ["doctor"])
        case .timeout: return .retry(after: 5)
        case .decodingFailed: return .none
        case let .versionMismatch(_, pinned):
            return .human("Run `pipx install 'mlx-audio==\(pinned)' --force`.")
        }
    }
}

// MARK: - Audio Models

/// Result of a speech-to-text transcription.
public struct TranscriptionResult: Codable, Sendable {
    /// The transcribed text.
    public let text: String
    /// Detected or specified language code (e.g. "en").
    public let language: String?
    /// Duration of the audio in seconds.
    public let duration: Double?
    /// The model used for transcription (e.g. "parakeet").
    public let modelUsed: String?

    public init(
        text: String,
        language: String? = nil,
        duration: Double? = nil,
        modelUsed: String? = nil
    ) {
        self.text = text
        self.language = language
        self.duration = duration
        self.modelUsed = modelUsed
    }
}

/// Result of a text-to-speech synthesis operation.
public struct SpeechResult: Codable, Sendable {
    /// Path to the generated audio file, if saved to disk.
    public let outputPath: String?
    /// The model used for synthesis (e.g. "kokoro").
    public let modelUsed: String
    /// The voice used for synthesis (e.g. "af_heart").
    public let voiceUsed: String

    public init(
        outputPath: String? = nil,
        modelUsed: String,
        voiceUsed: String
    ) {
        self.outputPath = outputPath
        self.modelUsed = modelUsed
        self.voiceUsed = voiceUsed
    }
}

/// Information about a single TTS voice.
public struct VoiceInfo: Codable, Sendable {
    /// Voice identifier (e.g. "af_heart").
    public let id: String
    /// Human-readable display name.
    public let name: String
    /// Language code (e.g. "en").
    public let language: String
    /// The model this voice belongs to (e.g. "kokoro").
    public let model: String

    public init(id: String, name: String, language: String, model: String) {
        self.id = id
        self.name = name
        self.language = language
        self.model = model
    }
}
