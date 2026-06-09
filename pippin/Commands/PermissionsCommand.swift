import ArgumentParser
import Darwin
import Foundation

/// `pippin permissions` — resolve and report the macOS privacy permissions each
/// app integration needs.
///
/// By default, when run interactively, it *primes* every promptable permission
/// (EventKit Reminders/Calendar, Contacts, and the Mail/Notes Automation
/// prompt) so each OS dialog appears once and is answered now — the reliable way
/// to stop later background/agent use from hitting an unanswerable prompt. Then
/// it prints the resulting status for all integrations, including the two Full
/// Disk Access ones (Voice Memos, Messages) which have no prompt and must be
/// granted manually.
///
/// Priming is skipped automatically when there's no one to answer a dialog —
/// under MCP, `--format agent|json`, a non-TTY pipe, or `--status` — in which
/// case the command is a pure read-only report. (pippin-uu3)
public struct PermissionsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "permissions",
        abstract: "Grant (interactively) and report macOS permissions for each app integration."
    )

    @Flag(name: .long, help: "Report current status only; never trigger permission prompts.")
    public var status: Bool = false

    @OptionGroup public var output: OutputOptions

    public init() {}

    public mutating func run() async throws {
        let interactive = isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
        let willPrime = !status && PermissionPriming.shouldPrime(
            interactive: interactive,
            isMCP: isMCPContext(),
            isStructuredOutput: output.isStructured
        )

        if willPrime {
            print("pippin permissions — granting access (answer each macOS prompt)")
            print(String(repeating: "=", count: 52))
            print()
            print("Reminders…")
            _ = await PermissionPrimer.primeReminders()
            print("Calendar…")
            _ = await PermissionPrimer.primeCalendar()
            print("Contacts…")
            _ = await PermissionPrimer.primeContacts()
            print("Mail & Notes (Automation)…")
            await detachBlocking {
                PermissionPrimer.primeMailAutomation()
                PermissionPrimer.primeNotesAutomation()
            }
            print()
        }

        let reports = await detachBlocking { PermissionPrimer.currentReports() }

        if output.isAgent {
            try output.printAgent(reports)
        } else if output.isJSON {
            try printJSON(reports)
        } else {
            renderText(reports, primed: willPrime, interactive: interactive)
        }

        // A `.denied` integration needs an active manual grant in System
        // Settings — signal that to scripts. Not-determined (couldn't prime
        // here) and manual-required (FDA) are informational, not failures.
        if reports.contains(where: { $0.state == .denied }) {
            throw ExitCode(1)
        }
    }

    private func renderText(_ reports: [PermissionReport], primed: Bool, interactive: Bool) {
        for report in reports {
            let icon: String
            switch report.state {
            case .granted: icon = "ok"
            case .denied: icon = "FAIL"
            case .notDetermined: icon = "??"
            case .manualRequired: icon = "--"
            case .unavailable: icon = "--"
            case .unknown: icon = "??"
            }
            print("[\(icon)]  \(report.integration): \(report.detail)")
            if report.state != .granted, let remediation = report.remediation {
                for line in remediation.humanHint.components(separatedBy: .newlines) {
                    print("       \(line)")
                }
            }
        }

        print()
        let notGranted = reports.filter { $0.state != .granted && $0.state != .unavailable }
        if notGranted.isEmpty {
            print("All available integrations are granted. pippin is ready.")
            return
        }
        if !primed, !status, !interactive {
            print("Run `pippin permissions` from an interactive terminal to grant the promptable ones.")
        }
        let manual = notGranted.filter { $0.mechanism == .fullDiskAccess }
        if !manual.isEmpty {
            let names = manual.map(\.integration).joined(separator: ", ")
            print("\(names) need Full Disk Access — there's no prompt; grant it manually (see above), then relaunch your terminal.")
        }
    }
}

// Structured output is the `[PermissionReport]` array directly — both
// `--format json` and `--format agent` (envelope `data`) emit it.
