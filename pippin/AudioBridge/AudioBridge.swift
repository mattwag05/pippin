import Foundation

// MARK: - AudioBridge

/// Process runner that shells out to the mlx-audio Python package via subprocess.
/// Follows the same pattern as MailBridge's osascript runner.
public enum AudioBridge {
    // MARK: - Version Pinning

    /// The mlx-audio version pippin was built and tested against. Bumped together
    /// with the Homebrew tap's `post_install` pipx pin. Keep in sync.
    public static let pinnedMLXAudioVersion = "0.4.2"

    // MARK: - STT Entry Resolution

    /// Describes how to invoke mlx-audio's STT entry point. Three-tier fallback:
    /// 1. A pipx-exposed console-script binary (`~/.local/bin/mlx_audio.stt.generate`).
    /// 2. `-m mlx_audio.stt.generate` via the discovered python interpreter (0.4.2+).
    /// 3. `-m mlx_audio.stt` via the discovered python interpreter (pre-0.4.2 legacy).
    public struct STTEntry: Sendable {
        public let executable: URL
        public let prefixArgs: [String]
    }

    /// Memoized STT entry resolver — safe initializer, first access runs the probe.
    private static let cachedSTTEntry: STTEntry? = resolveSTTEntry()

    public static func resolveSTTEntry() -> STTEntry? {
        // Tier 1: pipx console-script binary.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let pipxBin = home.appendingPathComponent(".local/bin/mlx_audio.stt.generate")
        if FileManager.default.isExecutableFile(atPath: pipxBin.path) {
            return STTEntry(executable: pipxBin, prefixArgs: [])
        }
        // Tier 2 / Tier 3: need a Python with mlx_audio importable.
        guard let python = findPythonWithMLXAudio() else { return nil }
        if canImportModule("mlx_audio.stt.generate", pythonURL: python) {
            return STTEntry(executable: python, prefixArgs: ["-m", "mlx_audio.stt.generate"])
        }
        if canImportModule("mlx_audio.stt", pythonURL: python) {
            return STTEntry(executable: python, prefixArgs: ["-m", "mlx_audio.stt"])
        }
        return nil
    }

    /// Read the installed `mlx_audio.__version__` via the given interpreter.
    /// Returns `nil` if the interpreter can't report a version.
    public static func installedMLXAudioVersion(python: URL? = nil) -> String? {
        guard let pythonURL = python ?? findPythonWithMLXAudio() else { return nil }
        let process = Process()
        process.executableURL = pythonURL
        // mlx-audio doesn't expose `__version__`; use importlib.metadata which
        // reads the installed distribution's pyproject/Egg-Info version.
        process.arguments = [
            "-c",
            "from importlib.metadata import version; print(version('mlx-audio'))",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let raw = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    /// Probe whether a given submodule is importable under the supplied python.
    static func canImportModule(_ module: String, pythonURL: URL) -> Bool {
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = ["-c", "import \(module)"]
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

    // MARK: - STT Argument Construction

    /// Whether a resolved STT entry uses the mlx-audio 0.4.2+ `stt.generate`
    /// contract (named `--audio`/`--output-path` flags, full Hugging Face model
    /// ids, file-based JSON output) versus the pre-0.4.2 `mlx_audio.stt` legacy
    /// contract (positional audio file, short model aliases, stdout output).
    ///
    /// The pipx console-script (`~/.local/bin/mlx_audio.stt.generate`, empty
    /// prefixArgs) and the `-m mlx_audio.stt.generate` module form are both the
    /// new contract; only `-m mlx_audio.stt` is legacy.
    static func sttEntryIsGenerate(_ entry: STTEntry) -> Bool {
        entry.executable.lastPathComponent == "mlx_audio.stt.generate"
            || entry.prefixArgs.contains("mlx_audio.stt.generate")
    }

    /// Short STT model aliases → the full Hugging Face repo ids that mlx-audio
    /// 0.4.2's `stt.generate` requires. Keep the default in `MLXAudioTranscriber`
    /// in sync with the keys here.
    static let sttModelAliases = [
        "parakeet": "mlx-community/parakeet-tdt-0.6b-v2",
    ]

    /// Map a pippin STT model alias to the full Hugging Face repo id that
    /// mlx-audio 0.4.2's `stt.generate` requires (bare "parakeet" no longer
    /// resolves — it gets treated as a literal repo id and 404s). Ids that are
    /// already fully qualified (contain "/") or are unknown bare names pass
    /// through unchanged so explicit user overrides still work.
    static func resolveSTTModelID(_ model: String) -> String {
        if model.contains("/") { return model }
        return sttModelAliases[model.lowercased()] ?? model
    }

    /// Build the mlx-audio STT argument vector for the given entry's contract.
    ///
    /// - generate (0.4.2+): `<prefix> --model <hf-id> --audio <file>
    ///   --output-path <base> --format json` — the transcript is written to
    ///   `<base>.json`, so the caller reads that file rather than stdout.
    /// - legacy (pre-0.4.2): `<prefix> <file> --model <alias> --format text` —
    ///   positional file, short alias, transcript on stdout. `outputBase` is
    ///   ignored.
    static func buildSTTArgs(
        entry: STTEntry,
        filePath: String,
        model: String,
        outputBase: String
    ) -> [String] {
        if sttEntryIsGenerate(entry) {
            return entry.prefixArgs + [
                "--model", resolveSTTModelID(model),
                "--audio", filePath,
                "--output-path", outputBase,
                "--format", "json",
            ]
        }
        return entry.prefixArgs + [
            filePath,
            "--model", model,
            "--format", "text",
        ]
    }

    /// The `--flag` tokens `buildSTTArgs` will pass for the given entry's
    /// contract. `doctor` asserts each appears in the STT CLI's `--help` output,
    /// so a version skew that renames or drops a flag pippin depends on is caught
    /// before a real `memos transcribe` fails (pippin-xua, relates to pippin-8ik
    /// where pippin's arg vector and the installed mlx-audio drifted apart).
    /// Derived from `buildSTTArgs` so the doctor probe and the real invocation
    /// can never diverge.
    static func expectedSTTFlags(for entry: STTEntry) -> [String] {
        buildSTTArgs(entry: entry, filePath: "probe.wav", model: "parakeet", outputBase: "probe")
            .filter { $0.hasPrefix("--") }
    }

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
        guard let entry = cachedSTTEntry else {
            // No STT path resolves. If mlx_audio itself is importable but
            // the submodule isn't, this is almost certainly a version skew
            // (e.g. a stranded pre-0.4.2 install). Surface versionMismatch
            // so the CLI prints actionable remediation instead of a cryptic
            // module-not-found trace.
            if let installed = installedMLXAudioVersion() {
                throw AudioBridgeError.versionMismatch(
                    installed: installed,
                    pinned: pinnedMLXAudioVersion
                )
            }
            throw AudioBridgeError.notAvailable
        }

        if sttEntryIsGenerate(entry) {
            return try transcribeViaGenerate(entry: entry, filePath: filePath, model: model)
        }

        // Legacy pre-0.4.2 `mlx_audio.stt`: positional file, transcript on stdout.
        let args = buildSTTArgs(entry: entry, filePath: filePath, model: model, outputBase: "")
        let stdout = try runProcess(
            executable: entry.executable,
            arguments: args,
            timeoutSeconds: 300
        )

        // Attempt JSON decode first; fall through to plain text if it isn't JSON.
        if outputFormat == "json",
           let data = stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            return transcriptionResult(fromJSON: json, fallbackText: stdout, modelUsed: model)
        }

        // Plain text or SRT: return raw output as text.
        return TranscriptionResult(text: stdout, modelUsed: model)
    }

    /// Build a `TranscriptionResult` from an mlx-audio JSON payload. The shape is
    /// the same whether the JSON arrived on stdout (legacy) or in an output file
    /// (0.4.2): a `text` field (with a caller-supplied fallback) plus optional
    /// `language`/`duration`.
    private static func transcriptionResult(
        fromJSON json: [String: Any]?,
        fallbackText: String,
        modelUsed: String
    ) -> TranscriptionResult {
        TranscriptionResult(
            text: (json?["text"] as? String) ?? fallbackText,
            language: json?["language"] as? String,
            duration: json?["duration"] as? Double,
            modelUsed: modelUsed
        )
    }

    /// Transcribe under the mlx-audio 0.4.2+ `stt.generate` contract: the tool
    /// writes the transcript to `<output-path>.json` and (unhelpfully) exits 0
    /// even on failure — so success is detected by a readable, parseable output
    /// file, not the exit code. The temp file is always cleaned up.
    private static func transcribeViaGenerate(
        entry: STTEntry,
        filePath: String,
        model: String
    ) throws -> TranscriptionResult {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pippin-stt-\(UUID().uuidString)")
        let outFile = base.appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: outFile) }

        let args = buildSTTArgs(entry: entry, filePath: filePath, model: model, outputBase: base.path)
        let result = try runProcessCapturing(
            executable: entry.executable,
            arguments: args,
            timeoutSeconds: 300
        )
        if result.timedOut { throw AudioBridgeError.timeout }

        // 0.4.2 returns exit 0 on errors (e.g. unresolved model), so the only
        // reliable success signal is a parseable output file.
        guard let data = try? Data(contentsOf: outFile) else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            throw AudioBridgeError.processFailed(
                detail.isEmpty ? "mlx-audio produced no transcript output" : detail
            )
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let fallbackText = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return transcriptionResult(
            fromJSON: json,
            fallbackText: fallbackText,
            modelUsed: resolveSTTModelID(model)
        )
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

    /// Check whether the mlx-audio Python package is importable from any known python3 interpreter.
    static func isAvailable() -> Bool {
        findPythonWithMLXAudio() != nil
    }

    // MARK: - mlx-audio Python Discovery

    /// Swift's `static let` gives us thread-safe, zero-cost-after-init memoization —
    /// no hand-rolled lock needed. First access runs the probe exactly once.
    private static let cachedMLXAudioPython: URL? =
        findPythonWithMLXAudio(candidates: defaultMLXAudioPythonCandidates())

    /// Find a python3 interpreter that can `import mlx_audio`, searching common install
    /// locations (pipx venv, system, PATH). Memoized per-process.
    ///
    /// - Returns: URL of the first working interpreter, or `nil` if none have mlx_audio.
    static func findPythonWithMLXAudio() -> URL? {
        cachedMLXAudioPython
    }

    /// Probe the given python3 candidate URLs in order and return the first that can
    /// `import mlx_audio`. Pure function — no caching, suitable for unit tests.
    static func findPythonWithMLXAudio(candidates: [URL]) -> URL? {
        for candidate in candidates where canImportMLXAudio(pythonURL: candidate) {
            return candidate
        }
        return nil
    }

    /// Build the default ordered list of python3 candidates to probe.
    /// Order: pipx venv → system → PATH-resolved. Pipx is first because it's the
    /// recommended install path on modern macOS (Homebrew Python is externally-managed).
    /// Duplicates collapsed.
    static func defaultMLXAudioPythonCandidates() -> [URL] {
        var candidates: [URL] = []
        var seen = Set<String>()

        func add(_ url: URL) {
            if seen.insert(url.path).inserted {
                candidates.append(url)
            }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        add(home.appendingPathComponent(".local/pipx/venvs/mlx-audio/bin/python3"))
        // Homebrew pipx stashes venvs under /opt/homebrew/var/pipx when
        // `pipx` itself is installed via brew and used in system mode.
        add(URL(fileURLWithPath: "/opt/homebrew/var/pipx/venvs/mlx-audio/bin/python3"))
        add(URL(fileURLWithPath: "/usr/bin/python3"))
        if let pathPython = resolvePython3OnPath() {
            add(pathPython)
        }
        return candidates
    }

    /// Run `/usr/bin/which python3` and return the resolved URL, if any.
    private static func resolvePython3OnPath() -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    /// Attempt `python3 -c "import mlx_audio"` with the given interpreter.
    /// Returns false if the interpreter doesn't exist, can't launch, or exits non-zero.
    private static func canImportMLXAudio(pythonURL: URL) -> Bool {
        let process = Process()
        process.executableURL = pythonURL
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
        guard let pythonURL = findPythonWithMLXAudio() else {
            throw AudioBridgeError.processFailed(
                "mlx-audio not found — install with: pipx install mlx-audio"
            )
        }
        return try runProcess(executable: pythonURL, arguments: arguments, timeoutSeconds: timeoutSeconds)
    }

    /// Captured result of a subprocess run: drained stdout/stderr, exit status,
    /// and whether the timeout fired. Lets callers that can't trust the exit
    /// code (mlx-audio 0.4.2's `stt.generate` exits 0 on failure) inspect stderr
    /// and decide success by other means.
    struct ProcessOutcome {
        let stdout: String
        let stderr: String
        let status: Int32
        let timedOut: Bool
    }

    /// Core subprocess runner: launch, drain stdout/stderr concurrently, apply a
    /// SIGTERM→SIGKILL timeout, and return the full outcome WITHOUT throwing on a
    /// nonzero exit. Callers decide how to interpret status/stderr.
    private static func runProcessCapturing(
        executable: URL,
        arguments: [String],
        timeoutSeconds: Int
    ) throws -> ProcessOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw AudioBridgeError.processFailed("Failed to launch \(executable.path): \(error.localizedDescription)")
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

        let stdoutStr = (String(data: stdoutData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let stderrStr = (String(data: stderrData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        return ProcessOutcome(
            stdout: stdoutStr,
            stderr: stderrStr,
            status: process.terminationStatus,
            timedOut: process.terminationReason == .uncaughtSignal
        )
    }

    /// Core subprocess runner: launch, drain stdout/stderr concurrently,
    /// apply a SIGTERM→SIGKILL timeout, and return stdout. Callers decide
    /// how to resolve the executable (python interpreter vs console-script binary).
    private static func runProcess(
        executable: URL,
        arguments: [String],
        timeoutSeconds: Int
    ) throws -> String {
        let outcome = try runProcessCapturing(
            executable: executable,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds
        )
        if outcome.timedOut { throw AudioBridgeError.timeout }
        guard outcome.status == 0 else {
            let detail = outcome.stderr.isEmpty ? outcome.stdout : outcome.stderr
            throw AudioBridgeError.processFailed(detail)
        }
        return outcome.stdout
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
