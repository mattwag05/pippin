import Foundation

/// Protocol for audio transcription backends.
public protocol Transcriber: Sendable {
    func transcribe(audioPath: String) throws -> TranscriptionResult
}

/// Transcribes audio using the mlx-audio Python package via AudioBridge.
public struct MLXAudioTranscriber: Transcriber {
    public let model: String
    public init(model: String = "parakeet") {
        self.model = model
    }

    public func transcribe(audioPath: String) throws -> TranscriptionResult {
        guard AudioBridge.isAvailable() else {
            throw TranscriberError.notAvailable
        }
        return try AudioBridge.transcribe(filePath: audioPath, model: model, outputFormat: "text")
    }
}

public enum TranscriberError: LocalizedError, Sendable {
    case notAvailable
    case timeout
    case failed(Int, String)
    case emptyOutput

    public var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "mlx-audio not installed. Install with: pip install mlx-audio"
        case .timeout:
            return "Transcription timed out"
        case let .failed(code, detail):
            return "Transcription failed (exit \(code)): \(detail)"
        case .emptyOutput:
            return "Transcription produced no output"
        }
    }
}
