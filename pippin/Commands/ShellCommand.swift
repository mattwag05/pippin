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
          help     Show available commands
          version  Show pippin version
          quit     Exit the REPL (also: exit, Ctrl-D)

        Lines starting with # are treated as comments and ignored.
        """
    )

    @Option(name: .long, help: "Default output format for all commands in this session: text, json, or agent.")
    public var format: OutputFormat?

    /// The command parser is injected at runtime by Pippin.main().
    /// This avoids PippinLib needing to know about the Pippin root command.
    public static nonisolated(unsafe) var parser: CommandParser?

    public init() {}

    public mutating func run() async throws {
        guard let parser = Self.parser else {
            fputs("Error: REPL parser not configured. Use 'pippin shell' to start.\n", stderr)
            throw ExitCode.failure
        }

        let isInteractive = isatty(fileno(stdin)) != 0

        if isInteractive {
            fputs("pippin \(PippinVersion.version) — interactive mode\n", stderr)
            fputs("Type 'help' for commands, 'quit' to exit.\n\n", stderr)
        }

        while true {
            if isInteractive {
                fputs("pippin> ", stderr)
            }

            guard let line = readLine(strippingNewline: true) else {
                // EOF (Ctrl-D)
                if isInteractive {
                    fputs("\n", stderr)
                }
                break
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Built-in REPL commands
            let lower = trimmed.lowercased()
            if lower == "quit" || lower == "exit" {
                break
            }
            if lower == "version" {
                print("pippin \(PippinVersion.version)")
                continue
            }
            if lower == "help" {
                printHelp()
                continue
            }

            // Parse the line into arguments, respecting quotes
            var args = shellSplit(trimmed)

            // Inject default --format if set and not already present
            if let fmt = format, !args.contains("--format"), !args.contains(where: { $0.hasPrefix("--format=") }) {
                args.append("--format")
                args.append(fmt.rawValue)
            }

            // Execute as a pippin subcommand
            await executeCommand(args, parser: parser)
        }
    }

    // MARK: - Command Execution

    /// Parse and run a single command within the REPL.
    private func executeCommand(_ args: [String], parser: CommandParser) async {
        do {
            var command = try parser(args)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch where error is CleanExit || error is ExitCode {
            // --help was passed for a subcommand — ArgumentParser already printed help
        } catch {
            // Print error but don't exit the REPL
            if let fmt = format, fmt == .agent {
                printAgentError(error)
            } else {
                fputs("Error: \(error.localizedDescription)\n", stderr)
            }
        }
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
            ("", ""),
            ("help", "Show this help"),
            ("version", "Show pippin version"),
            ("quit", "Exit the REPL (also: exit, Ctrl-D)"),
        ]

        fputs("\nAvailable commands:\n\n", stderr)
        for (cmd, desc) in commands {
            if cmd.isEmpty {
                fputs("\n", stderr)
            } else {
                fputs("  \(cmd.padding(toLength: 14, withPad: " ", startingAt: 0)) \(desc)\n", stderr)
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
        if char == "'" && !inDouble {
            inSingle.toggle()
        } else if char == "\"" && !inSingle {
            inDouble.toggle()
        } else if char == " " && !inSingle && !inDouble {
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
