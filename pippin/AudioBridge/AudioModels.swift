import Foundation

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
