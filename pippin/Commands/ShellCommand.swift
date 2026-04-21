import ArgumentParser
import Foundation

/// Callback type for parsing a command line into a ParsableCommand.
/// Injected by the executable target to avoid a circular dependency.
public typealias CommandParser = ([String]) throws -> ParsableCommand

/// Interactive REPL mode for pippin. Allows running multiple commands
/// in a single session without re-invoking the binary each time.
///
/// Agents benefit from REPL mode because it eliminates per-command
/// process startup overhead and enables stateful workflows where
/// context carries across commands within the session.
public struct ShellCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "shell",
        abstract: "Start an interactive REPL session.",
        discussion: """
        Enter pippin commands without the 'pippin' prefix. For example:

          pippin> mail accounts
          pippin> mail list --account Work --format json
          pippin> calendar agenda
          pippin> quit

        Special commands:
          help        Show available commands
          version     Show pippin version
          use <acct>  Set active mail account (auto-injected as --account)
          use         Clear active account
          context     Show current session context
          history     Show command history
          quit        Exit the REPL (also: exit, Ctrl-D)

        Lines starting with # are treated as comments and ignored.
        """
    )

    @Option(name: .long, help: "Default output format for all commands in this session: text, json, or agent.")
    public var format: OutputFormat?

    @Option(name: .long, help: "Path to session state file (default: ~/.config/pippin/session.json).")
    public var sessionFile: String?

    /// The command parser is injected at runtime by Pippin.main().
    /// This avoids PippinLib needing to know about the Pippin root command.
    public nonisolated(unsafe) static var parser: CommandParser?

    public init() {}

    public mutating func run() async throws {
        guard let parser = Self.parser else {
            fputs("Error: REPL parser not configured. Use 'pippin shell' to start.\n", stderr)
            throw ExitCode.failure
        }

        let session = SessionManager(path: sessionFile)
        let isInteractive = isatty(fileno(stdin)) != 0

        if isInteractive {
            fputs("pippin \(PippinVersion.version) — interactive mode\n", stderr)
            fputs("Type 'help' for commands, 'quit' to exit. Use 'complete <partial-input>' to see completions.\n", stderr)
            if let acct = session.activeAccount {
                fputs("Active account: \(acct)\n", stderr)
            }
            fputs("\n", stderr)
        }

        while true {
            if isInteractive {
                let prompt = buildPrompt(session: session)
                fputs(prompt, stderr)
            }

            guard let line = readLine(strippingNewline: true) else {
                if isInteractive { fputs("\n", stderr) }
                break
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let lower = trimmed.lowercased()

            // Built-in REPL commands
            if lower == "quit" || lower == "exit" { break }
            if lower == "version" { print("pippin \(PippinVersion.version)"); continue }
            if lower == "help" { printHelp(); continue }
            if lower == "context" { printContext(session: session); continue }
            if lower == "history" { printHistory(session: session); continue }
            if lower.hasPrefix("complete") {
                handleComplete(trimmed)
                continue
            }
            if lower.hasPrefix("use") {
                handleUse(trimmed, session: session)
                continue
            }

            // Record in history
            session.recordCommand(trimmed)

            // Parse the line into arguments, respecting quotes
            var args = shellSplit(trimmed)

            // Inject default --format if set and not already present
            if let fmt = format, !args.contains("--format"),
               !args.contains(where: { $0.hasPrefix("--format=") })
            {
                args.append("--format")
                args.append(fmt.rawValue)
            }

            // Inject --account from session context for mail commands
            if let acct = session.activeAccount,
               !args.isEmpty,
               args[0] == "mail",
               !args.contains("--account"),
               !args.contains(where: { $0.hasPrefix("--account=") })
            {
                args.append("--account")
                args.append(acct)
            }

            await executeCommand(args, parser: parser)
        }
    }

    // MARK: - Prompt

    private func buildPrompt(session: SessionManager) -> String {
        if let acct = session.activeAccount {
            return "pippin [\(acct)]> "
        }
        return "pippin> "
    }

    // MARK: - Command Execution

    private func executeCommand(_ args: [String], parser: CommandParser) async {
        do {
            var command = try parser(args)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch where error is CleanExit || error is ExitCode {
            // --help or intentional exit code — don't crash the REPL
        } catch {
            if let fmt = format, fmt == .agent {
                printAgentError(error)
            } else {
                fputs("Error: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    // MARK: - Built-in REPL Commands

    private func handleComplete(_ input: String) {
        let parts = shellSplit(input)
        if parts.count < 2 {
            fputs("Usage: complete <partial-input>\nExample: complete mail li\n", stderr)
            return
        }

        let partial = parts[1...].joined(separator: " ")
        let suggestions = ReplCompleter.completions(for: partial)

        if suggestions.isEmpty {
            fputs("No completions found.\n", stderr)
            return
        }

        fputs("\nCompletions for '\(partial)':\n", stderr)
        for suggestion in suggestions {
            fputs("  \(suggestion)\n", stderr)
        }
        fputs("\n", stderr)
    }

    private func handleUse(_ input: String, session: SessionManager) {
        let parts = shellSplit(input)
        if parts.count < 2 {
            session.setActiveAccount(nil)
            fputs("Cleared active account.\n", stderr)
            return
        }
        let account = parts[1 ..< parts.count].joined(separator: " ")
        session.setActiveAccount(account)
        fputs("Active account: \(account)\n", stderr)
    }

    private func printContext(session: SessionManager) {
        let s = session.currentState
        fputs("\nSession context:\n", stderr)
        fputs("  Account:      \(s.activeAccount ?? "(none)")\n", stderr)
        fputs("  Mailbox:      \(s.activeMailbox ?? "(none)")\n", stderr)
        fputs("  Last message: \(s.lastMessageId ?? "(none)")\n", stderr)
        fputs("  Last event:   \(s.lastEventId ?? "(none)")\n", stderr)
        fputs("  Last reminder:\(s.lastReminderId ?? "(none)")\n", stderr)
        fputs("  Last note:    \(s.lastNoteId ?? "(none)")\n", stderr)
        fputs("  History:      \(s.history.count) commands\n", stderr)

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        fputs("  Last active:  \(formatter.string(from: s.lastActive))\n\n", stderr)
    }

    private func printHistory(session: SessionManager) {
        let cmds = session.history
        if cmds.isEmpty {
            fputs("No command history.\n", stderr)
            return
        }
        fputs("\nRecent commands:\n", stderr)
        let start = max(0, cmds.count - 20)
        for (i, cmd) in cmds[start...].enumerated() {
            fputs("  \(start + i + 1). \(cmd)\n", stderr)
        }
        fputs("\n", stderr)
    }

    // MARK: - Help

    private func printHelp() {
        let commands: [(String, String)] = [
            ("mail", "Interact with Apple Mail"),
            ("memos", "Interact with Voice Memos"),
            ("calendar", "Interact with Apple Calendar"),
            ("audio", "Text-to-speech, speech-to-text, audio models"),
            ("contacts", "Interact with Apple Contacts"),
            ("browser", "Control a headless WebKit browser"),
            ("reminders", "Interact with Apple Reminders"),
            ("notes", "Interact with Apple Notes"),
            ("doctor", "Check system requirements and permissions"),
            ("status", "System dashboard"),
            ("", ""),
            ("use <account>", "Set active mail account"),
            ("use", "Clear active account"),
            ("complete <input>", "Show command completions for partial input"),
            ("context", "Show session context"),
            ("history", "Show command history"),
            ("help", "Show this help"),
            ("version", "Show pippin version"),
            ("quit", "Exit the REPL (also: exit, Ctrl-D)"),
        ]

        fputs("\nAvailable commands:\n\n", stderr)
        for (cmd, desc) in commands {
            if cmd.isEmpty {
                fputs("\n", stderr)
            } else {
                fputs("  \(cmd.padding(toLength: 16, withPad: " ", startingAt: 0)) \(desc)\n", stderr)
            }
        }
        fputs("\nPrefix any command with its subcommand. Example: mail list --account Work\n", stderr)
        fputs("Add --format json or --format agent for structured output.\n\n", stderr)
    }
}

// MARK: - Shell Argument Splitting

/// Split a command line string into arguments, respecting single and double quotes.
/// Does not handle backslash escaping (not needed for pippin's use case).
public func shellSplit(_ input: String) -> [String] {
    var args: [String] = []
    var current = ""
    var inSingle = false
    var inDouble = false

    for char in input {
        if char == "'", !inDouble {
            inSingle.toggle()
        } else if char == "\"", !inSingle {
            inDouble.toggle()
        } else if char == " ", !inSingle, !inDouble {
            if !current.isEmpty {
                args.append(current)
                current = ""
            }
        } else {
            current.append(char)
        }
    }
    if !current.isEmpty {
        args.append(current)
    }
    return args
}
