import ArgumentParser

@main
struct Pippin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pippin",
        abstract: "macOS CLI toolkit for Apple app automation.",
        subcommands: [MailCommand.self]
    )
}
