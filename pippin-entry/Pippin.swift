import ArgumentParser
import PippinLib

@main
struct Pippin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pippin",
        abstract: PippinVersion.tagline,
        version: "pippin \(PippinVersion.version)",
        subcommands: [
            MailCommand.self, MemosCommand.self, DoctorCommand.self, InitCommand.self,
            CompletionsCommand.self,
        ]
    )
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
