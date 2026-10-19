import AVFoundation
import Foundation
import Speech

/// Protocol for audio transcription backends.
public protocol Transcriber: Sendable {
    func transcribe(audioPath: String) throws -> TranscriptionResult
    /// Backend name recorded with each cached transcript.
    var cacheProvider: String { get }
}

public extension Transcriber {
    var cacheProvider: String { "custom" }
}

/// Transcribes audio using the mlx-audio Python package via AudioBridge.
public struct MLXAudioTranscriber: Transcriber {
    public let model: String
    public init(model: String = "parakeet") {
        self.model = model
    }

    public var cacheProvider: String { "mlx-audio" }

    public func transcribe(audioPath: String) throws -> TranscriptionResult {
        guard AudioBridge.isAvailable() else {
            throw TranscriberError.notAvailable
        }
        return try AudioBridge.transcribe(filePath: audioPath, model: model, outputFormat: "text")
    }
}

/// On-device transcription with Apple's SpeechAnalyzer (macOS 26+). Needs no
/// server or key. If the locale's speech model is missing, macOS downloads it
/// on first use.
public struct AppleSpeechTranscriber: Transcriber {
    /// BCP 47 identifier; nil uses the system locale.
    public let locale: String?

    public init(locale: String? = nil) {
        self.locale = locale
    }

    public var cacheProvider: String { "apple" }

    public func transcribe(audioPath: String) throws -> TranscriptionResult {
        guard #available(macOS 26, *) else {
            throw TranscriberError.failed("Apple on-device transcription requires macOS 26 or later.")
        }
        let requested = locale.map(Locale.init(identifier:)) ?? Locale.current
        // Memos run up to hours; the CLI allows 30 minutes, MCP its usual budget.
        let timeout: TimeInterval = isMCPContext() ? aiRequestTimeoutSeconds() : 1800
        let (text, localeId) = try waitForAsync(timeoutSeconds: timeout) {
            guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
                throw TranscriberError.failed("Apple on-device transcription does not support locale \(requested.identifier).")
            }
            let module = SpeechTranscriber(locale: supported, preset: .transcription)
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await install.downloadAndInstall()
            }
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
            let analyzer = SpeechAnalyzer(modules: [module])
            let collector = Task {
                var text = ""
                for try await result in module.results {
                    text += String(result.text.characters)
                }
                return text
            }
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            return try await (collector.value, supported.identifier)
        }
        return TranscriptionResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            language: localeId,
            modelUsed: "apple-speech"
        )
    }
}

/// Transcription through any OpenAI-compatible
/// `POST {baseURL}/audio/transcriptions` endpoint (OpenAI, oMLX, a homelab
/// gateway). Sends the audio file as multipart form data.
public struct OpenAITranscriber: Transcriber {
    public let baseURL: String
    public let model: String
    private let apiKey: String?

    public init(baseURL: String, model: String = "whisper-1", apiKey: String? = nil) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.model = model
        self.apiKey = (apiKey?.isEmpty == false) ? apiKey : nil
    }

    public var cacheProvider: String { "openai:\(model)" }

    public func transcribe(audioPath: String) throws -> TranscriptionResult {
        let audio = try Data(contentsOf: URL(fileURLWithPath: audioPath))
        let timeout: TimeInterval = isMCPContext() ? aiRequestTimeoutSeconds() : 600
        let request = try buildRequest(audio: audio, fileName: (audioPath as NSString).lastPathComponent, timeout: timeout)
        let (data, response) = try sendSynchronousRequest(request, waitTimeoutSeconds: Int(timeout) + 5)
        guard response.statusCode == 200 else {
            throw OpenAIProvider.errorForHTTPStatus(response.statusCode, data: data, model: model, baseURL: baseURL)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String
        else {
            throw TranscriberError.failed("Missing text in OpenAI-compatible transcription response")
        }
        return TranscriptionResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            language: json["language"] as? String,
            duration: json["duration"] as? Double,
            modelUsed: model
        )
    }

    /// Pure multipart request builder, for unit tests.
    func buildRequest(audio: Data, fileName: String, timeout: TimeInterval, boundary: String = UUID().uuidString) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)/audio/transcriptions") else {
            throw TranscriberError.failed("Invalid OpenAI-compatible base URL: \(baseURL)")
        }
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("response_format", "json")
        // `memos transcribe` sends converted WAV; `memos export --transcribe` sends the original m4a.
        let contentType = fileName.lowercased().hasSuffix(".wav") ? "audio/wav" : "audio/mp4"
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        return request
    }
}

public enum TranscriberError: LocalizedError, Sendable {
    case notAvailable
    case unsupportedProvider(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "mlx-audio not installed. Install with: pip install mlx-audio"
        case let .unsupportedProvider(name):
            return "Unsupported transcription provider '\(name)'. Use 'mlx-audio', 'apple', or 'openai'."
        case let .failed(message):
            return message
        }
    }
}
