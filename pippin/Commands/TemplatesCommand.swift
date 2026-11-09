import ArgumentParser
import Foundation

public struct TemplatesCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "templates",
        abstract: "Manage AI summarization templates.",
        subcommands: [List.self, Show.self, Add.self]
    )

    public init() {}

    // MARK: - List

    public struct List: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List all available templates."
        )

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let manager = TemplateManager()
            let templates = manager.allTemplates()

            struct TemplateListItem: Encodable {
                let name: String
                let description: String
                let builtIn: Bool
            }
            let items = templates.map { t in
                TemplateListItem(name: t.name, description: t.description, builtIn: t.isBuiltIn)
            }
            return AgentResult(items)
        }
    }

    // MARK: - Show

    public struct Show: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Print the system prompt for a template."
        )

        @Argument(help: "Template name.")
        public var name: String

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            struct TemplateContent: Encodable {
                let name: String
                let content: String
            }
            let manager = TemplateManager()
            let template = try manager.resolve(name: name)
            return AgentResult(TemplateContent(name: template.name, content: template.content))
        }
    }

    // MARK: - Add

    public struct Add: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Copy a .md template file into ~/.config/pippin/templates/."
        )

        @Argument(help: "Path to .md file to add.")
        public var path: String

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard path.hasSuffix(".md") else {
                throw ValidationError("Template file must have a .md extension.")
            }
            guard FileManager.default.fileExists(atPath: path) else {
                throw ValidationError("File not found: \(path)")
            }
        }

        public mutating func execute() async throws -> AgentResult {
            let manager = TemplateManager()
            struct TemplateAdded: Encodable {
                let path: String
            }
            let dest = try manager.addTemplate(fromPath: path)
            return AgentResult(TemplateAdded(path: dest))
        }
    }
}
