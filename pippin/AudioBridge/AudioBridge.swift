import Foundation

// MARK: - AudioBridge

/// Process runner that shells out to the mlx-audio Python package via subprocess.
/// Follows the same pattern as MailBridge's osascript runner.
public enum AudioBridge {
    // MARK: - Public API

    /// Synthesize speech from text using the specified TTS model and voice.
    ///
    /// - Parameters:
    ///   - text: The text to synthesize.
    ///   - model: The TTS model to use (default: "kokoro").
    ///   - voice: The voice identifier to use (default: "af_heart").
    ///   - outputPath: Optional path to save the generated audio file.
    /// - Returns: A `SpeechResult` describing what was produced.
    public static func speak(
        text: String,
        model: String = "kokoro",
        voice: String = "af_heart",
        outputPath: String? = nil
    ) throws -> SpeechResult {
        var args = [
            "-m", "mlx_audio.tts",
            "--text", text,
            "--model", model,
            "--voice", voice,
        ]
        if let path = outputPath {
            args += ["--output", path]
        }

        let stdout = try runPython(args, timeoutSeconds: 120)

        // Attempt to parse JSON from stdout first; fall back to treating as plain text.
        if let data = stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            let resolvedPath = json["output_path"] as? String ?? outputPath
            let resolvedModel = json["model"] as? String ?? model
            let resolvedVoice = json["voice"] as? String ?? voice
            return SpeechResult(outputPath: resolvedPath, modelUsed: resolvedModel, voiceUsed: resolvedVoice)
        }

        // Plain-text output: extract a path if we can find one in stdout.
        let detectedPath = extractPath(from: stdout) ?? outputPath
        return SpeechResult(outputPath: detectedPath, modelUsed: model, voiceUsed: voice)
    }

    /// Transcribe an audio file using the specified STT model.
    ///
    /// - Parameters:
    ///   - filePath: Path to the audio file to transcribe.
    ///   - model: The STT model to use (default: "parakeet").
    ///   - outputFormat: Output format hint passed to mlx-audio ("text", "srt", "json").
    /// - Returns: A `TranscriptionResult` with the transcribed text and metadata.
    public static func transcribe(
        filePath: String,
        model: String = "parakeet",
        outputFormat: String = "text"
    ) throws -> TranscriptionResult {
        let args = [
            "-m", "mlx_audio.stt",
            filePath,
            "--model", model,
            "--format", outputFormat,
        ]

        let stdout = try runPython(args, timeoutSeconds: 300)

        // Attempt JSON decode first.
        if outputFormat == "json",
           let data = stdout.data(using: .utf8)
        {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let text = json["text"] as? String ?? stdout
                let language = json["language"] as? String
                let duration = json["duration"] as? Double
                return TranscriptionResult(text: text, language: language, duration: duration, modelUsed: model)
            }
            // JSON format requested but output wasn't valid JSON — fall through to plain text.
        }

        // Plain text or SRT: return raw output as text.
        return TranscriptionResult(text: stdout, modelUsed: model)
    }

    /// List available voices for a given TTS model.
    ///
    /// - Parameter model: The TTS model to query (default: "kokoro").
    /// - Returns: Array of `VoiceInfo` describing the available voices.
    public static func listVoices(model: String = "kokoro") throws -> [VoiceInfo] {
        let args = [
            "-m", "mlx_audio.tts",
            "--list-voices",
            "--model", model,
        ]

        let stdout = try runPython(args, timeoutSeconds: 30)

        // Attempt JSON array decode first.
        if let data = stdout.data(using: .utf8),
           let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        {
            return jsonArray.compactMap { dict in
                guard let id = dict["id"] as? String else { return nil }
                let name = dict["name"] as? String ?? id
                let language = dict["language"] as? String ?? "en"
                let voiceModel = dict["model"] as? String ?? model
                return VoiceInfo(id: id, name: name, language: language, model: voiceModel)
            }
        }

        // Fall back to newline-delimited voice IDs.
        let lines = stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return lines.map { VoiceInfo(id: $0, name: $0, language: "en", model: model) }
    }

    /// List available mlx-audio model names.
    ///
    /// - Returns: Array of model name strings.
    public static func listModels() throws -> [String] {
        let args = [
            "-m", "mlx_audio",
            "--list-models",
        ]

        let stdout = try runPython(args, timeoutSeconds: 30)

        // Attempt JSON array decode first.
        if let data = stdout.data(using: .utf8),
           let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [String]
        {
            return jsonArray
        }

        // Fall back to newline-delimited model names.
        return stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Check whether the mlx-audio Python package is importable.
    ///
    /// - Returns: `true` if `python3 -c "import mlx_audio"` exits 0.
    public static func isAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import mlx_audio"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Private Helpers

    /// Run a python3 subprocess with the given arguments, capturing stdout.
    ///
    /// Drains both stdout and stderr concurrently to avoid deadlock on large output
    /// (>64 KB pipe buffer). The `nonisolated(unsafe)` vars are each written exactly
    /// once by a single GCD block; `group.wait()` provides the happens-before guarantee.
    private static func runPython(_ arguments: [String], timeoutSeconds: Int) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw AudioBridgeError.processFailed("Failed to launch python3: \(error.localizedDescription)")
        }

        // Drain both pipes concurrently to avoid deadlock on large output (>64KB pipe buffer)
        // nonisolated(unsafe): each var is written once by one GCD block; group.wait() provides happens-before
        nonisolated(unsafe) var stdoutData = Data()
        nonisolated(unsafe) var stderrData = Data()
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

        let timeoutItem = DispatchWorkItem {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: timeoutItem)

        process.waitUntilExit()
        timeoutItem.cancel()
        group.wait()

        if process.terminationReason == .uncaughtSignal {
            throw AudioBridgeError.timeout
        }

        let stdoutStr = (String(data: stdoutData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let stderrStr = (String(data: stderrData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            let detail = stderrStr.isEmpty ? stdoutStr : stderrStr
            throw AudioBridgeError.processFailed(detail)
        }

        return stdoutStr
    }

    /// Attempt to extract a file path from a line of text output.
    /// Looks for lines containing common audio extensions.
    private static func extractPath(from output: String) -> String? {
        let audioExtensions = [".wav", ".mp3", ".aiff", ".flac", ".m4a", ".ogg"]
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for ext in audioExtensions where trimmed.lowercased().hasSuffix(ext) {
                return trimmed
            }
        }
        return nil
    }
}
