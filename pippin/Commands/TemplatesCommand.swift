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

    public struct List: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List all available templates."
        )

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            let manager = TemplateManager()
            let templates = manager.allTemplates()

            if output.isJSON {
                struct TemplateListItem: Encodable {
                    let name: String
                    let description: String
                    let builtIn: Bool
                }
                let items = templates.map { t in
                    TemplateListItem(name: t.name, description: t.description, builtIn: t.isBuiltIn)
                }
                try printJSON(items)
            } else {
                printTemplatesTable(templates)
            }
        }
    }

    // MARK: - Show

    public struct Show: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Print the system prompt for a template."
        )

        @Argument(help: "Template name.")
        public var name: String

        public init() {}

        public mutating func run() async throws {
            let manager = TemplateManager()
            let template = try manager.resolve(name: name)
            print(template.content)
        }
    }

    // MARK: - Add

    public struct Add: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Copy a .md template file into ~/.config/pippin/templates/."
        )

        @Argument(help: "Path to .md file to add.")
        public var path: String

        public init() {}

        public mutating func validate() throws {
            guard path.hasSuffix(".md") else {
                throw ValidationError("Template file must have a .md extension.")
            }
            guard FileManager.default.fileExists(atPath: path) else {
                throw ValidationError("File not found: \(path)")
            }
        }

        public mutating func run() async throws {
            let manager = TemplateManager()
            let dest = try manager.addTemplate(fromPath: path)
            print("Template added: \(dest)")
        }
    }
}

// MARK: - Text output

private func printTemplatesTable(_ templates: [Template]) {
    if templates.isEmpty {
        print("No templates found.")
        return
    }
    let rows = templates.map { t -> [String] in
        let source = t.isBuiltIn ? "built-in" : "user"
        return [t.name, source, t.description]
    }
    let table = TextFormatter.table(
        headers: ["NAME", "SOURCE", "DESCRIPTION"],
        rows: rows,
        columnWidths: [20, 10, 50]
    )
    print(table)
}
