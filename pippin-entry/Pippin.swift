import ArgumentParser
import CDisclaimSpawn
import Foundation
import PippinLib

@main
struct Pippin: AsyncParsableCommand {
    static let configuration: CommandConfiguration = {
        var commands: [ParsableCommand.Type] = [
            MailCommand.self, MemosCommand.self, CalendarCommand.self,
            ContactsCommand.self,
            RemindersCommand.self, NotesCommand.self, MessagesCommand.self,
            ActionsCommand.self,
            DigestCommand.self,
            DoctorCommand.self, StatusCommand.self, InitCommand.self,
            PermissionsCommand.self, CompletionsCommand.self,
            AgentInfoCommand.self,
            ShellCommand.self, McpServerCommand.self,
            BatchCommand.self,
            JobCommand.self, JobRunnerInternalCommand.self,
            DoCommand.self,
        ]
        if ProcessInfo.processInfo.environment["PIPPIN_EXPERIMENTAL"] == "1" {
            commands.append(AudioCommand.self)
            commands.append(BrowserCommand.self)
        }
        return CommandConfiguration(
            commandName: "pippin",
            abstract: PippinVersion.tagline,
            version: "pippin \(PippinVersion.version)",
            subcommands: commands
        )
    }()

    static func main() async {
        // Before anything else: re-exec as our own TCC responsible process so
        // EventKit/Contacts/Automation grants key on pippin's signed identity
        // regardless of which app launched us (Terminal, Codex, the [agent-runtime]
        // gateway, launchd). One grant to pippin then works under every launcher.
        // See pippin-0vr.
        becomeOwnResponsibleProcess()

        // Inject the parser so ShellCommand can dispatch subcommands
        // without a circular dependency on the Pippin root command.
        ShellCommand.parser = { args in
            try Pippin.parseAsRoot(args)
        }

        // Let agent-mode error envelopes recover ArgumentParser's actionable
        // validation text (which localizedDescription swallows) via the root
        // command's `message(for:)`. PippinLib can't reference Pippin directly.
        // See pippin-kzi.
        AgentError.argumentParserMessage = { Pippin.message(for: $0) }

        // Let `agent-info` advertise the live subcommand list without
        // duplicating it — resolved once here (on the main actor) from the root
        // command's own registry, then read as a plain array.
        AgentInfoCommand.commandNames = configuration.subcommands
            .filter { $0.configuration.shouldDisplay }
            .compactMap { $0.configuration.commandName }

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
                // Typed exit code so a calling shell can branch on the failure
                // class without parsing the JSON envelope.
                Darwin.exit(PippinExitCode.from(error))
            } else if let remediation = RemediationCatalog.resolve(for: error) {
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
                Darwin.exit(PippinExitCode.from(error))
            } else {
                Pippin.exit(withError: error)
            }
        }
    }

    /// Re-exec disclaimed (once per process tree) so pippin is its own TCC
    /// responsible process. No-op when already disclaimed, opted out
    /// (`PIPPIN_NO_DISCLAIM=1`), or when the disclaim SPI is unavailable. See
    /// pippin-0vr / `DisclaimRespawn`.
    private static func becomeOwnResponsibleProcess() {
        guard DisclaimRespawn.shouldRespawn(environment: ProcessInfo.processInfo.environment) else {
            return
        }
        // Set before spawning so the child (and anything it spawns) inherits the
        // guard via environ and won't re-exec again.
        setenv(DisclaimRespawn.guardKey, "1", 1)
        // `pippin_respawn_disclaimed` blocks in waitpid for the child's lifetime.
        // That's a deliberate exception to the detach-blocking rule: this is the
        // very first statement of `main()`, a supervisor that does nothing but
        // wait — no cooperative work has been scheduled and no fan-out exists yet,
        // so it cannot starve the cooperative pool. detach-lint:allow
        let status = pippin_respawn_disclaimed(CommandLine.unsafeArgv)
        if status >= 0 {
            // The disclaimed child ran to completion — propagate its exit status.
            Darwin.exit(status)
        }
        // status < 0: SPI unavailable (-2) or spawn failed (-1) — run in-process.
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
