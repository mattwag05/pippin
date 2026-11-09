import ArgumentParser
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
/// Priming is skipped automatically when there's no one to answer a dialog
/// (under MCP, a non-TTY pipe, or `--status`), in which case the command is a
/// pure read-only report. Progress cues during priming go to stderr; stdout
/// carries only the envelope. (pippin-uu3)
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
        let willPrime = !status && PermissionPriming.shouldPrime(
            interactive: PermissionPriming.isInteractiveTerminal(),
            isMCP: isMCPContext()
        )

        if willPrime {
            fputs("pippin permissions: granting access (answer each macOS prompt)\n", stderr)
            fputs("Reminders...\n", stderr)
            _ = await PermissionPrimer.primeReminders()
            fputs("Calendar...\n", stderr)
            _ = await PermissionPrimer.primeCalendar()
            fputs("Contacts...\n", stderr)
            _ = await PermissionPrimer.primeContacts()
            fputs("Mail & Notes (Automation)...\n", stderr)
            await detachBlocking {
                PermissionPrimer.primeMailAutomation()
                PermissionPrimer.primeNotesAutomation()
            }
        }

        let reports = await detachBlocking { PermissionPrimer.currentReports() }
        try output.printAgent(reports)

        // A `.denied` integration needs an active manual grant in System
        // Settings — signal that to scripts. Not-determined (couldn't prime
        // here) and manual-required (FDA) are informational, not failures.
        if reports.contains(where: { $0.state == .denied }) {
            throw ExitCode(1)
        }
    }
}

// Structured output is the `[PermissionReport]` array directly (envelope `data`).
