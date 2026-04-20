import ArgumentParser
import Foundation
import PippinLib

@main
struct Pippin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pippin",
        abstract: PippinVersion.tagline,
        version: "pippin \(PippinVersion.version)",
        subcommands: [
            MailCommand.self, MemosCommand.self, CalendarCommand.self,
            AudioCommand.self, ContactsCommand.self, BrowserCommand.self,
            RemindersCommand.self, NotesCommand.self,
            ActionsCommand.self,
            DigestCommand.self,
            DoctorCommand.self, StatusCommand.self, InitCommand.self, CompletionsCommand.self,
            ShellCommand.self, McpServerCommand.self,
        ]
    )

    static func main() async {
        // Inject the parser so ShellCommand can dispatch subcommands
        // without a circular dependency on the Pippin root command.
        ShellCommand.parser = { args in
            try Pippin.parseAsRoot(args)
        }

        do {
            var command = try parseAsRoot(nil)

            // If no subcommand was given, default to the REPL shell
            if command is Pippin {
                var shell = ShellCommand()
                try await shell.run()
                return
            }

            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            // CleanExit (--help, --version) and ExitCode (intentional exit code) must be handled normally.
            if error is CleanExit || error is ExitCode {
                Pippin.exit(withError: error)
            } else if isAgentMode() {
                printAgentError(error)
                Darwin.exit(1)
            } else if let remediation = RemediationCatalog.forError(error) {
                // Catalogued errors print ourselves so we can append remediation.
                // Uncatalogued errors (ValidationError, etc.) fall through to
                // ArgumentParser so its usage-help formatting is preserved.
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                fputs("Error: \(message)\n\n", stderr)
                fputs("\(remediation.humanHint)\n", stderr)
                if let cmd = remediation.shellCommand {
                    fputs("  $ \(cmd)\n", stderr)
                }
                fputs("Run 'pippin doctor' for diagnostics.\n", stderr)
                Darwin.exit(1)
            } else {
                Pippin.exit(withError: error)
            }
        }
    }

    /// Returns true if `--format agent` was passed on the command line.
    private static func isAgentMode() -> Bool {
        let args = CommandLine.arguments
        for index in 0 ..< (args.count - 1) where args[index] == "--format" {
            if args[index + 1] == "agent" { return true }
        }
        return args.contains("--format=agent")
    }
}

struct CompletionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "completions",
        abstract: "Generate shell completion scripts.",
        discussion: """
        Outputs a completion script for the given shell. To install:

          # zsh
          pippin completions zsh > ~/.zfunc/_pippin
          # Add to ~/.zshrc: fpath=(~/.zfunc $fpath)
          # Then: autoload -Uz compinit && compinit

          # bash
          pippin completions bash >> ~/.bash_completion

          # fish
          pippin completions fish > ~/.config/fish/completions/pippin.fish
        """
    )

    @Argument(help: "Shell to generate completions for: zsh, bash, or fish.")
    var shell: String

    func run() throws {
        guard let completionShell = CompletionShell(rawValue: shell) else {
            throw ValidationError("Unknown shell '\(shell)'. Supported: zsh, bash, fish.")
        }
        print(Pippin.completionScript(for: completionShell))
    }
}
