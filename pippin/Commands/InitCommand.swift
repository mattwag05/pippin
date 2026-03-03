import ArgumentParser

public struct InitCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Guided first-run setup for permissions and dependencies."
    )

    public init() {}

    public mutating func run() async throws {
        // Stub — full implementation in Phase 4
        print("pippin init: not yet implemented")
    }
}
