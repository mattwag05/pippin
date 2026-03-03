import ArgumentParser
import PippinLib

@main
struct Pippin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pippin",
        abstract: PippinVersion.tagline,
        version: "pippin \(PippinVersion.version)",
        subcommands: [MailCommand.self, MemosCommand.self, DoctorCommand.self, InitCommand.self]
    )
}
