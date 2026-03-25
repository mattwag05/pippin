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

        if output.isAgent {
            try printAgentJSON(checks)
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

// MARK: - Testable helpers

/// Classify a Mail automation error by its description string.
func classifyMailError(_ detail: String) -> DiagnosticCheck {
    if detail.contains("not authorized") || detail.contains("AppleEvent") ||
        detail.contains("1002") || detail.contains("TCC")
    {
        return DiagnosticCheck(
            name: "Mail automation",
            status: .fail,
            detail: "permission denied",
            remediation: """
            Open System Settings > Privacy & Security > Automation
            Grant Terminal.app (or pippin binary) access to Mail.
            Then run: pippin mail list
            """
        )
    }
    if detail.isEmpty {
        return DiagnosticCheck(
            name: "Mail automation",
            status: .fail,
            detail: "Mail.app is not running",
            remediation: "$ open -a Mail && sleep 4"
        )
    }
    return DiagnosticCheck(
        name: "Mail automation",
        status: .fail,
        detail: detail,
        remediation: """
        Ensure Mail.app is installed and has at least one account configured.
        Then run: pippin mail list
        """
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
        remediation: "$ brew install python3"
    )
}

// MARK: - Diagnostic checks (shared with InitCommand)

/// Run all diagnostic checks and return results.
public func runAllChecks() -> [DiagnosticCheck] {
    var checks: [DiagnosticCheck] = []

    checks.append(checkMacOSVersion())
    checks.append(checkMailAutomation())
    checks.append(checkVoiceMemosDB())
    checks.append(checkCalendarAccess())
    checks.append(checkRemindersAccess())
    checks.append(checkContactsAccess())
    checks.append(checkNotesAccess())
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
            remediation: "Update to macOS 15 (Sequoia) or later."
        )
    }
}

private func checkMailAutomation() -> DiagnosticCheck {
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
                Voice Memos database not found at expected path.
                $ open -a "Voice Memos" && sleep 3
                Then run: pippin memos list
                """
            )
        case let .unsupportedSchemaVersion(v):
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

private func checkCalendarAccess() -> DiagnosticCheck {
    let status = EKEventStore.authorizationStatus(for: .event)
    switch status {
    case .fullAccess, .authorized:
        return DiagnosticCheck(
            name: "Calendar access",
            status: .ok,
            detail: "granted"
        )
    case .notDetermined:
        return DiagnosticCheck(
            name: "Calendar access",
            status: .skip,
            detail: "not determined (grant on first use of `pippin calendar`)"
        )
    case .denied, .restricted:
        return DiagnosticCheck(
            name: "Calendar access",
            status: .fail,
            detail: "permission denied",
            remediation: """
            Open System Settings > Privacy & Security > Calendars
            Grant access to Terminal.app (or the pippin binary).
            Then run: pippin calendar list
            """
        )
    default:
        return DiagnosticCheck(
            name: "Calendar access",
            status: .skip,
            detail: "status: \(status.rawValue) (grant on first use of `pippin calendar`)"
        )
    }
}

private func checkRemindersAccess() -> DiagnosticCheck {
    let status = EKEventStore.authorizationStatus(for: .reminder)
    switch status {
    case .fullAccess, .authorized:
        return DiagnosticCheck(name: "Reminders access", status: .ok, detail: "granted")
    case .notDetermined:
        return DiagnosticCheck(
            name: "Reminders access",
            status: .skip,
            detail: "not determined (grant on first use of `pippin reminders`)"
        )
    case .denied, .restricted:
        return DiagnosticCheck(
            name: "Reminders access",
            status: .fail,
            detail: "permission denied",
            remediation: """
            Open System Settings > Privacy & Security > Reminders
            Grant access to Terminal.app (or the pippin binary).
            Then run: pippin reminders list
            """
        )
    default:
        return DiagnosticCheck(
            name: "Reminders access",
            status: .skip,
            detail: "status: \(status.rawValue) (grant on first use of `pippin reminders`)"
        )
    }
}

private func checkNotesAccess() -> DiagnosticCheck {
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
                remediation: "$ open -a Notes && sleep 2"
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
                remediation: "$ open -a Notes && sleep 2"
            )
        default:
            let detail = error.localizedDescription
            if detail.contains("not authorized") || detail.contains("AppleEvent") ||
                detail.contains("1002") || detail.contains("TCC")
            {
                return DiagnosticCheck(
                    name: "Notes automation",
                    status: .fail,
                    detail: "permission denied",
                    remediation: """
                    Open System Settings > Privacy & Security > Automation
                    Grant Terminal.app (or pippin binary) access to Notes.
                    Then run: pippin notes folders
                    """
                )
            }
            return DiagnosticCheck(
                name: "Notes automation",
                status: .fail,
                detail: detail,
                remediation: """
                Ensure Notes.app is installed and open.
                $ open -a Notes && sleep 2
                Then run: pippin notes folders
                """
            )
        }
    } catch {
        return DiagnosticCheck(
            name: "Notes automation",
            status: .fail,
            detail: error.localizedDescription,
            remediation: """
            Ensure Notes.app is installed and open.
            $ open -a Notes && sleep 2
            Then run: pippin notes folders
            """
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
            detail: "not determined (grant on first use of `pippin contacts`)"
        )
    case .denied, .restricted:
        return DiagnosticCheck(
            name: "Contacts access",
            status: .fail,
            detail: "permission denied",
            remediation: """
            Open System Settings > Privacy & Security > Contacts
            Grant access to Terminal.app (or the pippin binary).
            Then run: pippin contacts list
            """
        )
    default:
        return DiagnosticCheck(
            name: "Contacts access",
            status: .skip,
            detail: "status: \(status.rawValue) (grant on first use of `pippin contacts`)"
        )
    }
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
    if AudioBridge.isAvailable() {
        return DiagnosticCheck(
            name: "mlx-audio",
            status: .ok,
            detail: "available"
        )
    }
    return DiagnosticCheck(
        name: "mlx-audio",
        status: .fail,
        detail: "not found (required for `pippin memos transcribe`)",
        remediation: "$ pip install mlx-audio"
    )
}

private func checkOllama() -> DiagnosticCheck {
    guard let url = URL(string: "http://localhost:11434/api/version") else {
        return DiagnosticCheck(name: "Ollama", status: .skip, detail: "invalid URL")
    }
    var request = URLRequest(url: url, timeoutInterval: 3)
    request.httpMethod = "GET"
    if let (_, httpResponse) = try? sendSynchronousRequest(request), httpResponse.statusCode == 200 {
        return DiagnosticCheck(name: "Ollama", status: .ok, detail: "reachable at localhost:11434")
    }
    return DiagnosticCheck(
        name: "Ollama",
        status: .skip,
        detail: "not reachable — optional, required for `mail index`, `mail triage`, `mail extract`",
        remediation: "$ brew install ollama && ollama serve"
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
        remediation: "$ brew install node"
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
        remediation: "$ npx playwright install webkit"
    )
}

private func checkPippinVersion() -> DiagnosticCheck {
    DiagnosticCheck(
        name: "pippin version",
        status: .ok,
        detail: PippinVersion.version
    )
}
