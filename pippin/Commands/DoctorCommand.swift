import ArgumentParser

public struct DoctorCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check system requirements and permissions."
    )

    @OptionGroup public var output: OutputOptions

    public init() {}

    public mutating func run() async throws {
        // Stub — full implementation in Phase 4
        print("pippin doctor: not yet implemented")
    }
}
