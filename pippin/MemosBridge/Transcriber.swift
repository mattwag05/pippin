import Foundation

/// Protocol for audio transcription backends.
public protocol Transcriber {
    func transcribe(audioPath: String) throws -> String
}

/// Transcribes audio using the `parakeet-mlx` CLI tool.
/// Shells out to the binary with a 300-second timeout.
public struct ParakeetTranscriber: Transcriber {
    public init() {}

    public func transcribe(audioPath: String) throws -> String {
        guard let binary = Self.findBinary() else {
            throw TranscriberError.binaryNotFound("parakeet-mlx")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [audioPath]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Drain both pipes concurrently to avoid deadlock on large output
        var stdoutData = Data()
        var stderrData = Data()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        // 300s timeout for transcription (can be slow on long recordings)
        let timeoutItem = DispatchWorkItem {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .seconds(300),
            execute: timeoutItem
        )

        process.waitUntilExit()
        timeoutItem.cancel()
        group.wait()

        if process.terminationReason == .uncaughtSignal {
            throw TranscriberError.timeout
        }

        guard process.terminationStatus == 0 else {
            let detail = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw TranscriberError.failed(Int(process.terminationStatus), detail)
        }

        let text = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw TranscriberError.emptyOutput
        }
        return text
    }

    /// Find the parakeet-mlx binary: check Homebrew path first, then PATH.
    static func findBinary() -> String? {
        let knownPaths = [
            "/opt/homebrew/bin/parakeet-mlx",
            "/usr/local/bin/parakeet-mlx",
        ]
        for path in knownPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Fallback: search PATH via `which`
        return whichBinary("parakeet-mlx")
    }
}

/// Transcribes audio using Apple's Speech framework (SFSpeechRecognizer).
/// Note: First call requires interactive authorization prompt.
public struct SpeechFrameworkTranscriber: Transcriber {
    public init() {}

    public func transcribe(audioPath _: String) throws -> String {
        // SFSpeechRecognizer requires the Speech framework and user authorization.
        // Import is deferred to avoid linking Speech.framework when not needed.
        // For now, this falls back to an error directing users to install parakeet-mlx.
        throw TranscriberError.speechFrameworkUnavailable
    }
}

public enum TranscriberError: LocalizedError {
    case binaryNotFound(String)
    case timeout
    case failed(Int, String)
    case emptyOutput
    case speechFrameworkUnavailable

    public var errorDescription: String? {
        switch self {
        case let .binaryNotFound(name):
            return "\(name) not found. Install with: brew install parakeet-mlx"
        case .timeout:
            return "Transcription timed out after 300 seconds"
        case let .failed(code, detail):
            return "Transcription failed (exit \(code)): \(detail)"
        case .emptyOutput:
            return "Transcription produced no output"
        case .speechFrameworkUnavailable:
            return "Speech framework transcription not yet implemented. Install parakeet-mlx: brew install parakeet-mlx"
        }
    }
}

public enum TranscriberFactory {
    /// Auto-detect best available transcriber: parakeet-mlx if on PATH, else SFSpeechRecognizer.
    public static func makeDefault() -> Transcriber {
        if isParakeetAvailable() {
            return ParakeetTranscriber()
        }
        return SpeechFrameworkTranscriber()
    }

    /// Check whether parakeet-mlx is available.
    public static func isParakeetAvailable() -> Bool {
        ParakeetTranscriber.findBinary() != nil
    }
}

/// Search PATH for a binary using /usr/bin/which.
func whichBinary(_ name: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    process.arguments = [name]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    if process.terminationStatus == 0 {
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !out.isEmpty { return out }
    }
    return nil
}
