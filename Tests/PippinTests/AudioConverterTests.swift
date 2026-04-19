import AVFoundation
@testable import PippinLib
import XCTest

final class AudioConverterTests: XCTestCase {
    // MARK: - needsConversion

    func testNativeExtensionsSkipConversion() {
        XCTAssertFalse(AudioConverter.needsConversion(path: "/tmp/sample.wav"))
        XCTAssertFalse(AudioConverter.needsConversion(path: "/tmp/sample.m4a"))
        XCTAssertFalse(AudioConverter.needsConversion(path: "/tmp/sample.WAV"))
    }

    func testNonNativeExtensionsNeedConversion() {
        XCTAssertTrue(AudioConverter.needsConversion(path: "/tmp/sample.caf"))
        XCTAssertTrue(AudioConverter.needsConversion(path: "/tmp/sample.mp3"))
        XCTAssertTrue(AudioConverter.needsConversion(path: "/tmp/sample.aiff"))
    }

    // MARK: - convertToWAV16kMono

    /// Synthesize a 1-second 44.1 kHz stereo sine CAF, convert to 16 kHz mono WAV,
    /// then read the output back and assert its format matches the contract.
    func testConvertProducesSixteenKMonoWAV() throws {
        let sourceURL = try writeTestCAF(durationSeconds: 0.5)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let outputURL = try AudioConverter.convertToWAV16kMono(sourcePath: sourceURL.path)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertTrue(outputURL.path.hasSuffix(".wav"))

        let outFile = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(outFile.fileFormat.sampleRate, 16000, accuracy: 0.01)
        XCTAssertEqual(outFile.fileFormat.channelCount, 1)
        XCTAssertTrue(outFile.length > 0, "output file must contain audio frames")
    }

    /// When `keepOutput == false` the caller still owns cleanup; the converter
    /// does not delete the file itself. This test just verifies the return URL
    /// is usable — cleanup behavior lives at the call site (VoiceMemosDB).
    func testConvertReturnsUsablePathRegardlessOfKeepFlag() throws {
        let sourceURL = try writeTestCAF(durationSeconds: 0.2)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let outputURL = try AudioConverter.convertToWAV16kMono(
            sourcePath: sourceURL.path,
            keepOutput: true
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    }

    // MARK: - Helpers

    /// Write a stereo 44.1 kHz sine CAF of the given duration to a temp path.
    private func writeTestCAF(durationSeconds: Double) throws -> URL {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pippin-test-\(UUID().uuidString).caf")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: tempURL,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: 44100,
            channels: 2
        ) else {
            throw NSError(domain: "test", code: 1)
        }

        let frameCount = AVAudioFrameCount(44100 * durationSeconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "test", code: 2)
        }
        buffer.frameLength = frameCount

        // Fill with a 440 Hz sine, same in both channels.
        let data = buffer.floatChannelData!
        for i in 0 ..< Int(frameCount) {
            let sample = Float(sin(2.0 * .pi * 440.0 * Double(i) / 44100.0)) * 0.5
            data[0][i] = sample
            data[1][i] = sample
        }

        try file.write(from: buffer)
        return tempURL
    }
}
