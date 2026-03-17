import ArgumentParser

public enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
    case text
    case json
    case agent
}

public struct OutputOptions: ParsableArguments {
    @Option(name: .long, help: "Output format: text (default), json, or agent (compact JSON for AI agents).")
    public var format: OutputFormat = .text

    public init() {}

    public var isJSON: Bool {
        format == .json
    }

    public var isAgent: Bool {
        format == .agent
    }

    public var isStructured: Bool {
        isJSON || isAgent
    }
}
