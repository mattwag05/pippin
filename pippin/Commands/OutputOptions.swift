import ArgumentParser

public enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
    case text
    case json
}

public struct OutputOptions: ParsableArguments {
    @Option(name: .long, help: "Output format: text (default) or json.")
    public var format: OutputFormat = .text

    public init() {}

    public var isJSON: Bool { format == .json }
}
