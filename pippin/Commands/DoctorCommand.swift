import ArgumentParser
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
    public let remediation: String? // nil when status is .ok

    public init(name: String, status: Status, detail: String, remediation: String? = nil) {
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

    @OptionGroup public var output: OutputOptions

    public init() {}

    public mutating func run() async throws {
        let checks = runAllChecks()

        if output.isJSON {
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
                    for line in remediation.components(separatedBy: .newlines) {
                        print("       \(line)")
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

// MARK: - Diagnostic checks (shared with InitCommand)

/// Run all diagnostic checks and return results.
public func runAllChecks() -> [DiagnosticCheck] {
    var checks: [DiagnosticCheck] = []

    checks.append(checkMacOSVersion())
    checks.append(checkMailAutomation())
    checks.append(checkVoiceMemosDB())
    checks.append(checkParakeetMLX())
    checks.append(checkSpeechRecognition())
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
            remediation: "Update to macOS 15 (Sequoia) or later."
        )
    }
}

private func checkMailAutomation() -> DiagnosticCheck {
    // Try to list accounts with a short timeout to test TCC grant
    do {
        _ = try MailBridge.listAccounts()
        return DiagnosticCheck(
            name: "Mail automation",
            status: .ok,
            detail: "granted"
        )
    } catch {
        let detail = error.localizedDescription
        if detail.contains("not authorized") || detail.contains("AppleEvent") ||
            detail.contains("1002") || detail.contains("TCC")
        {
            return DiagnosticCheck(
                name: "Mail automation",
                status: .fail,
                detail: "permission denied",
                remediation: """
                    → Open System Settings > Privacy & Security > Automation
                      Grant Terminal.app (or pippin binary) access to Mail.
                      Then run: pippin mail list
                    """
            )
        }
        // Could be Mail not running or other issue
        return DiagnosticCheck(
            name: "Mail automation",
            status: .fail,
            detail: detail,
            remediation: """
                → Ensure Mail.app is installed and has at least one account configured.
                  Then run: pippin mail list
                """
        )
    }
}

private func checkVoiceMemosDB() -> DiagnosticCheck {
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
                remediation: """
                    → Voice Memos database not found at expected path.
                      Ensure Voice Memos.app has been opened at least once.
                    """
            )
        case .unsupportedSchemaVersion(let v):
            return DiagnosticCheck(
                name: "Voice Memos access",
                status: .fail,
                detail: "unsupported schema version \(v)",
                remediation: """
                    → The Voice Memos database schema has changed (version \(v)).
                      This version of pippin may need updating.
                    """
            )
        default:
            return DiagnosticCheck(
                name: "Voice Memos access",
                status: .fail,
                detail: error.localizedDescription,
                remediation: """
                    → Open System Settings > Privacy & Security > Full Disk Access
                      Add Terminal.app, then restart your terminal.
                    """
            )
        }
    } catch {
        return DiagnosticCheck(
            name: "Voice Memos access",
            status: .fail,
            detail: "permission denied",
            remediation: """
                → Open System Settings > Privacy & Security > Full Disk Access
                  Add Terminal.app, then restart your terminal.
                """
        )
    }
}

private func checkParakeetMLX() -> DiagnosticCheck {
    // Check common locations
    let commonPaths = [
        "/opt/homebrew/bin/parakeet-mlx",
        "/usr/local/bin/parakeet-mlx",
    ]

    for path in commonPaths {
        if FileManager.default.isExecutableFile(atPath: path) {
            return DiagnosticCheck(
                name: "parakeet-mlx",
                status: .ok,
                detail: "found at \(path)"
            )
        }
    }

    // Try `which`
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    process.arguments = ["parakeet-mlx"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            let out = (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.isEmpty {
                return DiagnosticCheck(
                    name: "parakeet-mlx",
                    status: .ok,
                    detail: "found at \(out)"
                )
            }
        }
    } catch {}

    return DiagnosticCheck(
        name: "parakeet-mlx",
        status: .skip,
        detail: "not found (optional — install for transcription)",
        remediation: "→ pip install parakeet-mlx (optional, for `--transcribe` support)"
    )
}

private func checkSpeechRecognition() -> DiagnosticCheck {
    // SFSpeechRecognizer status check without importing Speech framework
    // Just report as skip since we use parakeet-mlx as primary
    return DiagnosticCheck(
        name: "Speech Recognition",
        status: .skip,
        detail: "not determined (grant on first use of --transcribe)"
    )
}

private func checkPippinVersion() -> DiagnosticCheck {
    DiagnosticCheck(
        name: "pippin version",
        status: .ok,
        detail: PippinVersion.version
    )
}
