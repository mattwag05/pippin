import ArgumentParser
import Contacts
import EventKit
import Foundation

/// A single diagnostic check result.
public struct DiagnosticCheck: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ok
        case fail
        case skip // optional check not available
    }

    public let name: String
    public let status: Status
    public let detail: String
    /// Structured remediation — `nil` when status is `.ok` or there is
    /// nothing useful to say. JSON mode emits the `Remediation` shape
    /// (`human_hint`, `doctor_check`, optional `shell_command`); text
    /// mode renders the hint prose plus a `$ <cmd>` line when present.
    public let remediation: Remediation?

    public init(name: String, status: Status, detail: String, remediation: Remediation? = nil) {
        self.name = name
        self.status = status
        self.detail = detail
        self.remediation = remediation
    }
}

public struct DoctorCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check system requirements and permissions."
    )

    @Flag(name: .long, help: "Add Mail bridge latency probes (ready/list/activity/search). Each runs against a 20s soft cap; slow probes warn, blown probes fail. Adds up to ~70s wall time on a problem vault.")
    public var latency: Bool = false

    @OptionGroup public var output: OutputOptions

    public init() {}

    public mutating func run() async throws {
        let runLatency = latency
        let checks = await detachBlocking {
            var checks = runAllChecks()
            if runLatency {
                checks.append(contentsOf: runMailLatencyProbes())
            }
            return checks
        }

        if output.isAgent {
            try output.printAgent(checks)
        } else if output.isJSON {
            try printJSON(checks)
        } else {
            for check in checks {
                let icon: String
                switch check.status {
                case .ok: icon = "ok"
                case .fail: icon = "FAIL"
                case .skip: icon = "--"
                }
                print("[\(icon)]  \(check.name): \(check.detail)")
                if let remediation = check.remediation {
                    for line in remediation.humanHint.components(separatedBy: .newlines) {
                        print("       \(line)")
                    }
                    if let cmd = remediation.shellCommand {
                        print("       $ \(cmd)")
                    }
                }
            }
        }

        let hasCriticalFailure = checks.contains { $0.status == .fail }
        if hasCriticalFailure {
            throw ExitCode(1)
        }
    }
}

// MARK: - Testable helpers

/// Classify a Mail automation error by its description string.
func classifyMailError(_ detail: String) -> DiagnosticCheck {
    if detail.contains("not authorized") || detail.contains("AppleEvent") ||
        detail.contains("1002") || detail.contains("TCC") {
        return DiagnosticCheck(
            name: "Mail automation",
            status: .fail,
            detail: "permission denied",
            remediation: Remediation(
                humanHint: """
                Open System Settings > Privacy & Security > Automation
                Grant Terminal.app (or pippin binary) access to Mail.
                Then run: pippin mail list
                """,
                doctorCheck: "Mail automation"
            )
        )
    }
    if detail.isEmpty {
        return DiagnosticCheck(
            name: "Mail automation",
            status: .fail,
            detail: "Mail.app is not running",
            remediation: Remediation(
                humanHint: "Mail.app is not running. Open it and retry.",
                doctorCheck: "Mail automation",
                shellCommand: "open -a Mail && sleep 4"
            )
        )
    }
    return DiagnosticCheck(
        name: "Mail automation",
        status: .fail,
        detail: detail,
        remediation: Remediation(
            humanHint: """
            Ensure Mail.app is installed and has at least one account configured.
            Then run: pippin mail list
            """,
            doctorCheck: "Mail automation"
        )
    )
}

/// Classify `python3 --version` output into a DiagnosticCheck.
func classifyPython3Output(exitCode: Int32, output: String) -> DiagnosticCheck {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if exitCode == 0 && !trimmed.isEmpty {
        let version = trimmed.hasPrefix("Python ") ? String(trimmed.dropFirst(7)) : trimmed
        return DiagnosticCheck(
            name: "Python3",
            status: .ok,
            detail: version
        )
    }
    return DiagnosticCheck(
        name: "Python3",
        status: .fail,
        detail: "not found",
        remediation: Remediation(
            humanHint: "python3 is not installed. Install it via Homebrew.",
            doctorCheck: "Python3",
            shellCommand: "brew install python3"
        )
    )
}

// MARK: - Diagnostic checks (shared with InitCommand)

/// Run all diagnostic checks and return results.
public func runAllChecks() -> [DiagnosticCheck] {
    var checks: [DiagnosticCheck] = []

    checks.append(checkMacOSVersion())
    checks.append(checkMailAutomation())
    checks.append(checkMailEnvelopeIndex())
    checks.append(checkVoiceMemosDB())
    checks.append(checkMessagesAccess())
    checks.append(checkCalendarAccess())
    checks.append(checkRemindersAccess())
    checks.append(checkContactsAccess())
    checks.append(checkNotesAccess())
    checks.append(checkCodeSigning())
    checks.append(checkPython3())
    checks.append(checkMLXAudio())
    checks.append(checkOllama())
    checks.append(checkNodeJS())
    checks.append(checkPlaywright())
    checks.append(checkPippinVersion())

    return checks
}

private func checkMacOSVersion() -> DiagnosticCheck {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    let versionStr = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"

    // macOS 26+ (Tahoe) required. macOS 15 = Sequoia, 26 = Tahoe.
    // We accept 15+ since that's what SPM targets, but flag if below.
    if version.majorVersion >= 15 {
        return DiagnosticCheck(
            name: "macOS version",
            status: .ok,
            detail: versionStr
        )
    } else {
        return DiagnosticCheck(
            name: "macOS version",
            status: .fail,
            detail: "\(versionStr) (requires macOS 15+)",
            remediation: Remediation(
                humanHint: "Update to macOS 15 (Sequoia) or later.",
                doctorCheck: "macOS version"
            )
        )
    }
}

func checkMailAutomation() -> DiagnosticCheck {
    do {
        _ = try MailBridge.listAccounts()
        return DiagnosticCheck(
            name: "Mail automation",
            status: .ok,
            detail: "granted"
        )
    } catch {
        return classifyMailError(error.localizedDescription)
    }
}

/// Envelope Index fast path availability (pippin-60x). Informational: mail
/// commands work either way (JXA fallback is silent and automatic), so an
/// unreadable index is a `.skip` with a hint — never a `.fail` that would
/// flag existing Automation-only setups as broken.
func checkMailEnvelopeIndex() -> DiagnosticCheck {
    let name = "Mail fast path (Envelope Index)"
    guard let dbPath = MailEnvelopeIndex.defaultDBPath() else {
        return DiagnosticCheck(
            name: name,
            status: .skip,
            detail: "no Envelope Index under ~/Library/Mail (Mail.app never used on this Mac)"
        )
    }
    do {
        // Accounts aren't needed to probe readability + schema version.
        _ = try MailEnvelopeIndex(dbPath: dbPath, accounts: [])
        return DiagnosticCheck(
            name: name,
            status: .ok,
            detail: "index readable, schema supported — mail list/search/activity use the SQLite fast path"
        )
    } catch let error as MailEnvelopeIndexError {
        switch error {
        case let .unsupportedVersion(v):
            return DiagnosticCheck(
                name: name,
                status: .skip,
                detail: "Envelope Index schema version \(v) is unknown to this pippin build — mail commands use the (slower) JXA path until pippin is updated"
            )
        default:
            return DiagnosticCheck(
                name: name,
                status: .skip,
                detail: "Envelope Index unreadable — mail commands use the (slower) JXA path. Grant Full Disk Access to enable ~1000x faster list/search (System Settings > Privacy & Security > Full Disk Access)"
            )
        }
    } catch {
        return DiagnosticCheck(
            name: name,
            status: .skip,
            detail: "Envelope Index unreadable (\(error.localizedDescription)) — mail commands use the (slower) JXA path"
        )
    }
}

func checkMessagesAccess() -> DiagnosticCheck {
    let dbPath = MessagesDatabase.defaultDBPath()
    do {
        _ = try MessagesDatabase(dbPath: dbPath)
        return DiagnosticCheck(name: "Messages access", status: .ok, detail: "database readable")
    } catch let error as MessagesError {
        switch error {
        case .databaseNotFound:
            return DiagnosticCheck(
                name: "Messages access",
                status: .skip,
                detail: "no Messages database (Messages.app never used on this Mac)"
            )
        default:
            return DiagnosticCheck(
                name: "Messages access",
                status: .fail,
                detail: "permission denied",
                remediation: .fullDiskAccess(integration: "Messages", listCommand: "pippin messages list")
            )
        }
    } catch {
        return DiagnosticCheck(
            name: "Messages access",
            status: .fail,
            detail: "permission denied",
            remediation: .fullDiskAccess(integration: "Messages", listCommand: "pippin messages list")
        )
    }
}

func checkVoiceMemosDB() -> DiagnosticCheck {
    let dbPath = VoiceMemosDB.defaultDBPath()
    do {
        _ = try VoiceMemosDB(dbPath: dbPath)
        return DiagnosticCheck(
            name: "Voice Memos access",
            status: .ok,
            detail: "database readable"
        )
    } catch let error as VoiceMemosError {
        switch error {
        case .databaseNotFound:
            return DiagnosticCheck(
                name: "Voice Memos access",
                status: .fail,
                detail: "database not found",
                remediation: RemediationCatalog.forCategory(.databaseNotFound)
            )
        case let .unsupportedSchemaVersion(v):
            return DiagnosticCheck(
                name: "Voice Memos access",
                status: .fail,
                detail: "unsupported schema version \(v)",
                remediation: Remediation(
                    humanHint: """
                    The Voice Memos database schema has changed (version \(v)). \
                    This version of pippin may need updating.
                    """,
                    doctorCheck: "Voice Memos access"
                )
            )
        case let .accessDenied(reason):
            return DiagnosticCheck(
                name: "Voice Memos access",
                status: .fail,
                detail: "permission denied (\(reason))",
                remediation: RemediationCatalog.forCategory(.accessDenied)
            )
        default:
            return DiagnosticCheck(
                name: "Voice Memos access",
                status: .fail,
                detail: error.localizedDescription,
                remediation: RemediationCatalog.forCategory(.accessDenied)
            )
        }
    } catch {
        return DiagnosticCheck(
            name: "Voice Memos access",
            status: .fail,
            detail: "permission denied",
            remediation: RemediationCatalog.forCategory(.accessDenied)
        )
    }
}

private func checkCalendarAccess() -> DiagnosticCheck {
    checkEventKitAccess(integration: "Calendar", entity: .event, listCommand: "pippin calendar list")
}

private func checkRemindersAccess() -> DiagnosticCheck {
    checkEventKitAccess(integration: "Reminders", entity: .reminder, listCommand: "pippin reminders list")
}

/// Shared EventKit (Calendar/Reminders) authorization check. Parameterized so
/// the not-determined / denied messaging lives in exactly one place — editing
/// it for one integration can't silently skip the other. (pippin-xzu /simplify)
private func checkEventKitAccess(
    integration: String,
    entity: EKEntityType,
    listCommand: String
) -> DiagnosticCheck {
    let name = "\(integration) access"
    let status = EKEventStore.authorizationStatus(for: entity)
    switch status {
    case .fullAccess, .authorized:
        return DiagnosticCheck(name: name, status: .ok, detail: "granted")
    case .notDetermined:
        return DiagnosticCheck(
            name: name,
            status: .skip,
            detail: "not yet granted — run `pippin permissions` to grant interactively",
            remediation: .privacyAccess(permission: integration, listCommand: listCommand, doctorCheck: name)
        )
    case .denied, .restricted:
        return DiagnosticCheck(
            name: name,
            status: .fail,
            detail: "permission denied",
            remediation: .privacyAccess(permission: integration, listCommand: listCommand, doctorCheck: name)
        )
    default:
        return DiagnosticCheck(
            name: name,
            status: .skip,
            detail: "status: \(status.rawValue) (grant via `\(listCommand)`)"
        )
    }
}

func checkNotesAccess() -> DiagnosticCheck {
    // Fast pre-check: is Notes.app running? Avoids 30s JXA timeout when it's not.
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-x", "Notes"]
    pgrep.standardOutput = Pipe()
    pgrep.standardError = Pipe()
    if let _ = try? pgrep.run() {
        pgrep.waitUntilExit()
        if pgrep.terminationStatus != 0 {
            return DiagnosticCheck(
                name: "Notes automation",
                status: .fail,
                detail: "Notes.app is not running",
                remediation: Remediation(
                    humanHint: "Notes.app is not running. Open it and retry.",
                    doctorCheck: "Notes automation",
                    shellCommand: "open -a Notes && sleep 2"
                )
            )
        }
    }
    // Notes is running (or pgrep not available) — try the bridge
    do {
        _ = try NotesBridge.listFolders()
        return DiagnosticCheck(
            name: "Notes automation",
            status: .ok,
            detail: "granted"
        )
    } catch let error as NotesBridgeError {
        switch error {
        case .timeout:
            return DiagnosticCheck(
                name: "Notes automation",
                status: .fail,
                detail: "Notes.app is not running or timed out",
                remediation: Remediation(
                    humanHint: "Notes.app is not running or the JXA bridge timed out. Open the app and retry.",
                    doctorCheck: "Notes automation",
                    shellCommand: "open -a Notes && sleep 2"
                )
            )
        default:
            let detail = error.localizedDescription
            if detail.contains("not authorized") || detail.contains("AppleEvent") ||
                detail.contains("1002") || detail.contains("TCC") {
                return DiagnosticCheck(
                    name: "Notes automation",
                    status: .fail,
                    detail: "permission denied",
                    remediation: Remediation(
                        humanHint: """
                        Open System Settings > Privacy & Security > Automation
                        Grant Terminal.app (or pippin binary) access to Notes.
                        Then run: pippin notes folders
                        """,
                        doctorCheck: "Notes automation"
                    )
                )
            }
            return DiagnosticCheck(
                name: "Notes automation",
                status: .fail,
                detail: detail,
                remediation: Remediation(
                    humanHint: "Ensure Notes.app is installed and open, then run: pippin notes folders",
                    doctorCheck: "Notes automation",
                    shellCommand: "open -a Notes && sleep 2"
                )
            )
        }
    } catch {
        return DiagnosticCheck(
            name: "Notes automation",
            status: .fail,
            detail: error.localizedDescription,
            remediation: Remediation(
                humanHint: "Ensure Notes.app is installed and open, then run: pippin notes folders",
                doctorCheck: "Notes automation",
                shellCommand: "open -a Notes && sleep 2"
            )
        )
    }
}

private func checkContactsAccess() -> DiagnosticCheck {
    let status = CNContactStore.authorizationStatus(for: .contacts)
    switch status {
    case .authorized:
        return DiagnosticCheck(name: "Contacts access", status: .ok, detail: "granted")
    case .notDetermined:
        return DiagnosticCheck(
            name: "Contacts access",
            status: .skip,
            detail: "not yet granted — run `pippin permissions` to grant interactively",
            remediation: .privacyAccess(
                permission: "Contacts",
                listCommand: "pippin contacts list",
                doctorCheck: "Contacts access"
            )
        )
    case .denied, .restricted:
        return DiagnosticCheck(
            name: "Contacts access",
            status: .fail,
            detail: "permission denied",
            remediation: .privacyAccess(
                permission: "Contacts",
                listCommand: "pippin contacts list",
                doctorCheck: "Contacts access"
            )
        )
    default:
        return DiagnosticCheck(
            name: "Contacts access",
            status: .skip,
            detail: "status: \(status.rawValue) (grant on first use of `pippin contacts`)"
        )
    }
}

/// Classify `codesign -dvv` output into a signing-status check. Pure so it can
/// be unit-tested without a real binary. A stable (non-ad-hoc) signature means
/// TCC grants survive rebuilds/upgrades; ad-hoc or unsigned means they reset.
/// (pippin-xzu)
func classifyCodeSigning(_ output: String) -> DiagnosticCheck {
    let isAdhoc = output.contains("adhoc") || output.contains("Signature=adhoc")
    let hasAuthority = output.contains("Authority=")
    if hasAuthority, !isAdhoc {
        let developerID = output.contains("Authority=Developer ID Application")
        return DiagnosticCheck(
            name: "Code signing",
            status: .ok,
            detail: developerID
                ? "Developer ID — TCC grants persist across upgrades"
                : "stable identity — TCC grants persist across upgrades"
        )
    }
    let detail = isAdhoc ? "ad-hoc signed" : "unsigned"
    return DiagnosticCheck(
        name: "Code signing",
        status: .skip,
        detail: "\(detail) — TCC grants reset on rebuild/upgrade",
        remediation: Remediation(
            humanHint: """
            pippin is \(detail), so macOS may drop its permission grants whenever \
            the binary changes (reinstall/upgrade). Reinstall a stably-signed \
            build — `make install` signs with your Developer ID when available — \
            then run `pippin permissions` once. Grants then persist.
            """,
            doctorCheck: "Code signing"
        )
    )
}

func checkCodeSigning() -> DiagnosticCheck {
    guard let path = Bundle.main.executablePath else {
        return DiagnosticCheck(name: "Code signing", status: .skip, detail: "could not locate the pippin binary")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["-dvv", path]
    let pipe = Pipe()
    // codesign writes its description to stderr.
    process.standardError = pipe
    process.standardOutput = Pipe()
    guard (try? process.run()) != nil else {
        return DiagnosticCheck(name: "Code signing", status: .skip, detail: "codesign unavailable")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return classifyCodeSigning(String(data: data, encoding: .utf8) ?? "")
}

func checkPython3() -> DiagnosticCheck {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "--version"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe // python3 may write to stderr

    guard (try? process.run()) != nil else {
        return classifyPython3Output(exitCode: 1, output: "")
    }

    // 5-second timeout
    let deadline = DispatchTime.now() + .seconds(5)
    let result = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        process.waitUntilExit()
        result.signal()
    }
    if result.wait(timeout: deadline) == .timedOut {
        process.terminate()
        return classifyPython3Output(exitCode: 1, output: "")
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return classifyPython3Output(exitCode: process.terminationStatus, output: output)
}

private func checkMLXAudio() -> DiagnosticCheck {
    let pinned = AudioBridge.pinnedMLXAudioVersion
    guard let entry = AudioBridge.resolveSTTEntry() else {
        // mlx_audio itself might still be importable (version skew) — prefer
        // the versionMismatch-shaped hint when we can read a version.
        if let installed = AudioBridge.installedMLXAudioVersion() {
            return DiagnosticCheck(
                name: "mlx-audio",
                status: .fail,
                detail: "installed \(installed), expected \(pinned) (STT entry not resolvable)",
                remediation: Remediation(
                    humanHint: "mlx-audio \(installed) is installed but the expected STT entry point is missing. Reinstall pinned version.",
                    doctorCheck: "mlx-audio",
                    shellCommand: "pipx install 'mlx-audio==\(pinned)' --force"
                )
            )
        }
        return DiagnosticCheck(
            name: "mlx-audio",
            status: .fail,
            detail: "not found (required for `pippin memos transcribe`)",
            remediation: RemediationCatalog.forCategory(.notAvailable)
        )
    }

    // Entry resolves — record installed version + run a dry invocation to
    // catch broken installs beyond the version string.
    let installedVersion = AudioBridge.installedMLXAudioVersion() ?? "unknown"
    guard let helpText = runSTTHelp(entry: entry) else {
        return DiagnosticCheck(
            name: "mlx-audio",
            status: .fail,
            detail: "installed \(installedVersion), dry invocation failed",
            remediation: Remediation(
                humanHint: "mlx-audio is installed but `--help` on the STT entry fails. Reinstall the pinned version.",
                doctorCheck: "mlx-audio",
                shellCommand: "pipx install 'mlx-audio==\(pinned)' --force"
            )
        )
    }

    // The `--help` text parsed — assert the flags `buildSTTArgs` will pass are
    // actually advertised by the installed CLI. `--help` returning exit 0 is not
    // enough: mlx-audio 0.4.2 exits 0 on `--help` but a version skew that renames
    // or drops `--audio`/`--output-path` would still fail every real
    // transcription (pippin-xua). Catch the arg-shape mismatch here.
    let missingFlags = sttFlagsMissing(fromHelp: helpText, expected: AudioBridge.expectedSTTFlags(for: entry))
    if !missingFlags.isEmpty {
        let missingList = missingFlags.joined(separator: ", ")
        return DiagnosticCheck(
            name: "mlx-audio",
            status: .fail,
            detail: "installed \(installedVersion), STT CLI does not accept required flag(s): \(missingList)",
            remediation: Remediation(
                humanHint: "The installed mlx-audio STT CLI is missing flag(s) pippin requires (\(missingList)) — `memos transcribe`/`summarize`/`capture` will fail. Reinstall the pinned version.",
                doctorCheck: "mlx-audio",
                shellCommand: "pipx install 'mlx-audio==\(pinned)' --force"
            )
        )
    }

    let detail: String
    if installedVersion == pinned {
        detail = "available, version \(installedVersion) (\(entry.executable.path))"
    } else {
        detail = "available, installed \(installedVersion), pinned \(pinned) (\(entry.executable.path))"
    }
    return DiagnosticCheck(name: "mlx-audio", status: .ok, detail: detail)
}

/// Runs `<entry> --help` with a short timeout. Returns the combined
/// stdout+stderr help text on exit status 0, else nil (broken/unresponsive
/// install). The text is then matched against the flags pippin will pass.
private func runSTTHelp(entry: AudioBridge.STTEntry) -> String? {
    let process = Process()
    process.executableURL = entry.executable
    process.arguments = entry.prefixArgs + ["--help"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe // argparse may print usage to either stream
    do {
        try process.run()
    } catch {
        return nil
    }
    let deadline = DispatchTime.now() + .seconds(10)
    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        process.waitUntilExit()
        sem.signal()
    }
    if sem.wait(timeout: deadline) == .timedOut {
        process.terminate()
        return nil
    }
    // `--help` output is small (a few KB), well under the pipe buffer, so
    // reading after exit cannot deadlock.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8) ?? ""
}

/// The subset of `expected` flag tokens that do NOT appear in the CLI's
/// `--help` text. Pure (no I/O) so it's unit-testable against a captured help
/// fixture. A flag counts as present only when SOME occurrence ends on a token
/// boundary (space, `=`, `,`, `]`, `)`, `/`, whitespace, or end-of-text) — so
/// `--format` is not satisfied by `--format-version` alone, and a real
/// `--format` elsewhere in the text still counts.
func sttFlagsMissing(fromHelp help: String, expected: [String]) -> [String] {
    let boundary: Set<Character> = [" ", "=", ",", "]", ")", "\n", "\t", "/", "\r"]
    return expected.filter { flag in
        var searchStart = help.startIndex
        while let range = help.range(of: flag, range: searchStart ..< help.endIndex) {
            let after = range.upperBound
            if after == help.endIndex || boundary.contains(help[after]) {
                return false // found a whole-token occurrence → present
            }
            searchStart = range.upperBound
        }
        return true // no whole-token occurrence → missing
    }
}

private func checkOllama() -> DiagnosticCheck {
    let baseURL = AIProviderFactory.loadConfig()?.ai?.ollama?.url ?? "http://localhost:11434"
    guard let versionURL = URL(string: "\(baseURL)/api/version") else {
        return DiagnosticCheck(name: "Ollama", status: .skip, detail: "invalid URL")
    }
    var request = URLRequest(url: versionURL, timeoutInterval: 3)
    request.httpMethod = "GET"
    guard
        let (_, httpResponse) = try? sendSynchronousRequest(request, waitTimeoutSeconds: 5),
        httpResponse.statusCode == 200
    else {
        return DiagnosticCheck(
            name: "Ollama",
            status: .skip,
            detail: "not reachable — optional, required for `mail index`, `mail triage`, `mail extract`",
            remediation: Remediation(
                humanHint: "Ollama is not reachable on localhost:11434. It is optional — only `mail index`, `mail triage`, and `mail extract` need it.",
                doctorCheck: "Ollama",
                shellCommand: "brew install ollama && ollama serve"
            )
        )
    }

    // Reachable — also verify the configured model is actually pulled, so
    // `pippin calendar agenda` / `memos summarize` / `actions` don't fail
    // tens of seconds in with HTTP 404 "model X not found." Default mirrors
    // OllamaProvider.init.
    let configuredModel = AIProviderFactory.loadConfig()?.ai?.ollama?.model ?? "llama3.2"
    if let modelStatus = checkOllamaModel(baseURL: baseURL, configuredModel: configuredModel) {
        return modelStatus
    }
    return DiagnosticCheck(name: "Ollama", status: .ok, detail: "reachable at \(baseURL); model \(configuredModel) pulled")
}

/// Returns a non-nil DiagnosticCheck when the configured model is not
/// available; nil means the model is present (caller emits the green check).
/// Tags probe + model-name matching are shared with `OllamaProvider`'s
/// model-not-found path (issue #22) — see `OllamaProvider.modelIsAvailable`.
private func checkOllamaModel(baseURL: String, configuredModel: String) -> DiagnosticCheck? {
    guard let availableNames = OllamaProvider.fetchAvailableModels(baseURL: baseURL) else {
        // Couldn't probe tags — Ollama is up so don't flag a hard failure.
        return DiagnosticCheck(
            name: "Ollama",
            status: .ok,
            detail: "reachable at \(baseURL) (model presence not verified)"
        )
    }

    if OllamaProvider.modelIsAvailable(configured: configuredModel, available: availableNames) {
        return nil
    }

    let suggestion: String
    if availableNames.isEmpty {
        suggestion = "ollama pull \(configuredModel)"
    } else {
        let sample = availableNames.sorted().prefix(3).joined(separator: ", ")
        suggestion = "ollama pull \(configuredModel)  # or set ai.ollama.model in ~/.config/pippin/config.json (available: \(sample))"
    }
    return DiagnosticCheck(
        name: "Ollama",
        status: .fail,
        detail: "reachable at \(baseURL) but model \(configuredModel) is not pulled — `pippin memos summarize`, `calendar agenda`, `actions extract` will fail",
        remediation: Remediation(
            humanHint: "The configured Ollama model is not pulled. Pull it with the command below, or set a different model under ai.ollama.model in ~/.config/pippin/config.json.",
            doctorCheck: "Ollama",
            shellCommand: suggestion
        )
    )
}

private func checkNodeJS() -> DiagnosticCheck {
    if BrowserBridge.isNodeAvailable() {
        return DiagnosticCheck(name: "Node.js", status: .ok, detail: "found")
    }
    return DiagnosticCheck(
        name: "Node.js",
        status: .skip,
        detail: "not found (optional — required for `pippin browser`)",
        remediation: Remediation(
            humanHint: "Node.js is optional — install it only if you plan to use `pippin browser`.",
            doctorCheck: "Node.js",
            shellCommand: "brew install node"
        )
    )
}

private func checkPlaywright() -> DiagnosticCheck {
    guard BrowserBridge.isNodeAvailable() else {
        return DiagnosticCheck(name: "Playwright", status: .skip, detail: "skipped (Node.js not found)")
    }
    if BrowserBridge.isPlaywrightAvailable() {
        return DiagnosticCheck(name: "Playwright", status: .ok, detail: "found")
    }
    return DiagnosticCheck(
        name: "Playwright",
        status: .skip,
        detail: "not found (optional — required for `pippin browser`)",
        remediation: Remediation(
            humanHint: "Playwright is optional — install it only if you plan to use `pippin browser`.",
            doctorCheck: "Playwright",
            shellCommand: "npx playwright install webkit"
        )
    )
}

private func checkPippinVersion() -> DiagnosticCheck {
    DiagnosticCheck(
        name: "pippin version",
        status: .ok,
        detail: PippinVersion.version
    )
}

// MARK: - Mail latency probes (opt-in via --latency)

/// Run the three MCP-relevant Mail probes (list/activity/search) and
/// classify by wall-clock latency. Each probe uses a 20s soft timeout
/// inside the bridge (well under the 22s default and the 35-50s hard
/// caps) so the worst case is bounded — a thoroughly broken vault still
/// returns a typed error within ~60s rather than hanging.
public func runMailLatencyProbes() -> [DiagnosticCheck] {
    [
        runMailLatencyProbe(name: "Mail.app ready latency") {
            // Ready-poll only (no mailbox scan) — isolates Mail.app launch/sync
            // time from per-query latency in the probes below.
            try MailBridge.probeReady()
        },
        runMailLatencyProbe(name: "Mail list latency") {
            _ = try MailBridge.listMessages(
                mailbox: "INBOX", unread: false, limit: 1, softTimeoutMs: 20000,
                fastPath: false // probes measure the JXA/Mail.app path, not SQLite
            )
        },
        runMailLatencyProbe(name: "Mail activity latency") {
            let oneHourAgo = Calendar.current.date(byAdding: .hour, value: -1, to: Date())
            _ = try MailBridge.listActivity(
                mailboxes: ["INBOX"], since: oneHourAgo, limit: 1, preview: 0,
                softTimeoutMs: 20000, fastPath: false
            )
        },
        runMailLatencyProbe(name: "Mail search latency") {
            _ = try MailBridge.searchMessages(
                query: "pippin-doctor-probe-no-match-expected", limit: 1,
                softTimeoutMs: 20000, fastPath: false
            )
        },
    ]
}

private func runMailLatencyProbe(name: String, body: () throws -> Void) -> DiagnosticCheck {
    let start = Date()
    do {
        try body()
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        return classifyLatency(name: name, ms: ms)
    } catch {
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        return DiagnosticCheck(
            name: name,
            status: .fail,
            detail: "errored after \(ms)ms: \(error.localizedDescription)",
            remediation: Remediation(
                humanHint: "The Mail bridge raised an error during the latency probe. Open Mail.app, retry `pippin mail list --limit 1`, and check `pippin doctor` for permissions issues.",
                doctorCheck: name
            )
        )
    }
}

func classifyLatency(name: String, ms: Int) -> DiagnosticCheck {
    // 20s yellow, 55s red — chosen to match the MCP runChild 60s cap with
    // a 5s headroom for the JSON-RPC roundtrip on top of the probe itself.
    if ms >= 55000 {
        return DiagnosticCheck(
            name: name,
            status: .fail,
            detail: "\(ms)ms — exceeds MCP 60s runChild cap; this tool will be SIGKILL'd under MCP",
            remediation: Remediation(
                humanHint: "Mail bridge is too slow for MCP use. Narrow the call (--account, --mailbox, --limit) or investigate Mail.app sync state. Consider quitting and reopening Mail.app.",
                doctorCheck: name,
                shellCommand: "killall Mail && open -a Mail"
            )
        )
    }
    if ms >= 20000 {
        return DiagnosticCheck(
            name: name,
            status: .skip,
            detail: "warning: \(ms)ms — slow; narrow scope for reliable MCP use",
            remediation: Remediation(
                humanHint: "This probe took longer than the 22s soft cap most callers use. Mail.app may be syncing. Re-run after sync completes.",
                doctorCheck: name
            )
        )
    }
    return DiagnosticCheck(name: name, status: .ok, detail: "\(ms)ms")
}
