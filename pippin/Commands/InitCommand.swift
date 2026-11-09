import ArgumentParser
import Foundation

public struct InitCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Guided first-run setup for permissions and dependencies."
    )

    @OptionGroup public var output: OutputOptions

    public init() {}

    public mutating func run() async throws {
        // In an interactive terminal, proactively trigger each promptable TCC
        // prompt up front so onboarding resolves them in one pass, rather than
        // deferring to "first use", which silently fails when first use is a
        // background agent that can't show a dialog. Skipped under MCP and
        // non-TTY (see PermissionPriming.shouldPrime). (pippin-dkf)
        // The cue goes to stderr: stdout is reserved for the envelope.
        if PermissionPriming.shouldPrime(
            interactive: PermissionPriming.isInteractiveTerminal(),
            isMCP: isMCPContext()
        ) {
            fputs("Granting app permissions (answer each macOS prompt)...\n", stderr)
            _ = await PermissionPrimer.primeReminders()
            _ = await PermissionPrimer.primeCalendar()
            _ = await PermissionPrimer.primeContacts()
            await detachBlocking {
                PermissionPrimer.primeMailAutomation()
                PermissionPrimer.primeNotesAutomation()
            }
        }

        let checks = await detachBlocking { runAllChecks() }
        try output.printAgent(InitReport(checks: checks))
    }
}

/// Structured output for `pippin init`.
public struct InitReport: Codable, Sendable {
    public let ready: Bool
    public let checks: [DiagnosticCheck]

    public init(checks: [DiagnosticCheck]) {
        self.checks = checks
        ready = !checks.contains { $0.status == .fail }
    }
}
