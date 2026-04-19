import AVFoundation
import Foundation

/// Normalizes audio files to the format the STT backend is happiest with
/// (16 kHz mono PCM WAV). Voice Memos ships `.m4a` natively, which mlx-audio
/// handles without help — non-native formats get transcoded into a short-lived
/// temp file that the caller is expected to clean up.
public enum AudioConverter {
    /// Extensions that the mlx-audio STT backend accepts directly. Anything
    /// else triggers a conversion pass before transcription. `wav` and `m4a`
    /// cover the 99% case (WAV is the target format; `m4a` is what Voice
    /// Memos stores).
    public static let nativeExtensions: Set<String> = ["wav", "m4a"]

    /// Returns `true` when the file extension sits outside the native set
    /// and a conversion pass is warranted.
    public static func needsConversion(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return !nativeExtensions.contains(ext)
    }

    /// Convert an audio file to 16 kHz mono 16-bit PCM WAV at a temporary
    /// path. The caller owns cleanup unless they set `keepOutput` — in which
    /// case the path is retained and printed via the debug flag in the CLI.
    ///
    /// - Parameters:
    ///   - sourcePath: Absolute path to the input audio file.
    ///   - keepOutput: If `true`, caller must clean up manually; when `false`,
    ///     caller should `defer { try? FileManager.default.removeItem }`.
    /// - Returns: URL of the freshly written WAV file under `NSTemporaryDirectory()`.
    public static func convertToWAV16kMono(
        sourcePath: String,
        keepOutput _: Bool = false
    ) throws -> URL {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pippin-audio-\(UUID().uuidString).wav")

        let inputFile = try AVAudioFile(forReading: sourceURL)
        let inputFormat = inputFile.processingFormat

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioConverterError.formatUnsupported("cannot build 16kHz mono Int16 output format")
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioConverterError.formatUnsupported(
                "no AVAudioConverter from \(inputFormat) to \(outputFormat)"
            )
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let outputFile = try AVAudioFile(
            forWriting: tempURL,
            settings: outputSettings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        let inputFrameCapacity: AVAudioFrameCount = 4096
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: inputFrameCapacity
        ) else {
            throw AudioConverterError.bufferAllocationFailed
        }

        while inputFile.framePosition < inputFile.length {
            try inputFile.read(into: inputBuffer)
            if inputBuffer.frameLength == 0 { break }

            // Scale output capacity by sample-rate ratio to avoid truncation.
            let ratio = outputFormat.sampleRate / inputFormat.sampleRate
            let outCapacity = AVAudioFrameCount(
                Double(inputBuffer.frameLength) * ratio + 1024
            )
            guard let outBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outCapacity
            ) else {
                throw AudioConverterError.bufferAllocationFailed
            }

            var fed = false
            var err: NSError?
            let status = converter.convert(to: outBuffer, error: &err) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return inputBuffer
            }

            if status == .error, let err {
                throw AudioConverterError.conversionFailed(err.localizedDescription)
            }

            if outBuffer.frameLength > 0 {
                try outputFile.write(from: outBuffer)
            }
        }

        return tempURL
    }
}

public enum AudioConverterError: LocalizedError, Sendable {
    case formatUnsupported(String)
    case bufferAllocationFailed
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .formatUnsupported(detail): return "Audio format unsupported: \(detail)"
        case .bufferAllocationFailed: return "Failed to allocate audio buffer"
        case let .conversionFailed(detail): return "Audio conversion failed: \(detail)"
        }
    }
}
