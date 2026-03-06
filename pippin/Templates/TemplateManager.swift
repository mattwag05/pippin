import Foundation

public enum TemplateError: LocalizedError, Sendable {
    case notFound(String)
    case invalidFrontmatter(String)

    public var errorDescription: String? {
        switch self {
        case let .notFound(name):
            return "Template '\(name)' not found. Use `pippin memos templates list` to see available templates."
        case let .invalidFrontmatter(detail):
            return "Invalid template frontmatter: \(detail)"
        }
    }
}

public struct Template: Sendable {
    public let name: String
    public let description: String
    public let content: String
    public let isBuiltIn: Bool
}

public final class TemplateManager: Sendable {
    public static func defaultTemplatesDir() -> String {
        let home = NSHomeDirectory()
        return "\(home)/.config/pippin/templates"
    }

    private let templatesDir: String

    public init(templatesDir: String? = nil) {
        self.templatesDir = templatesDir ?? TemplateManager.defaultTemplatesDir()
    }

    // MARK: - Public API

    /// All available templates: built-in first, then user templates.
    public func allTemplates() -> [Template] {
        var templates: [Template] = BuiltInTemplates.all.map {
            Template(name: $0.name, description: $0.description, content: $0.content, isBuiltIn: true)
        }
        templates.append(contentsOf: loadUserTemplates())
        return templates
    }

    /// Resolve a template by name (built-in or user). Throws if not found.
    public func resolve(name: String) throws -> Template {
        if let builtIn = BuiltInTemplates.all.first(where: { $0.name == name }) {
            return Template(name: builtIn.name, description: builtIn.description, content: builtIn.content, isBuiltIn: true)
        }
        if let user = loadUserTemplates().first(where: { $0.name == name }) {
            return user
        }
        throw TemplateError.notFound(name)
    }

    /// Copy a .md file into the user templates directory.
    public func addTemplate(fromPath sourcePath: String) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(atPath: templatesDir, withIntermediateDirectories: true)

        let filename = (sourcePath as NSString).lastPathComponent
        let destPath = (templatesDir as NSString).appendingPathComponent(filename)
        if fm.fileExists(atPath: destPath) {
            try fm.removeItem(atPath: destPath)
        }
        try fm.copyItem(atPath: sourcePath, toPath: destPath)
        return destPath
    }

    // MARK: - Private

    private func loadUserTemplates() -> [Template] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: templatesDir) else { return [] }
        return files
            .filter { $0.hasSuffix(".md") }
            .sorted()
            .compactMap { filename -> Template? in
                let path = (templatesDir as NSString).appendingPathComponent(filename)
                guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
                return parseUserTemplate(raw: raw, filename: filename)
            }
    }

    /// Parse a user template file. YAML frontmatter is optional.
    /// Frontmatter format:
    /// ---
    /// name: my-template
    /// description: One-line description
    /// ---
    /// <system prompt content>
    private func parseUserTemplate(raw: String, filename: String) -> Template {
        let defaultName = (filename as NSString).deletingPathExtension
        var name = defaultName
        var description = ""
        var content = raw

        if raw.hasPrefix("---") {
            let lines = raw.components(separatedBy: "\n")
            var endIndex = -1
            for (i, line) in lines.dropFirst().enumerated() {
                if line.trimmingCharacters(in: .whitespaces) == "---" {
                    endIndex = i + 1
                    break
                }
            }
            if endIndex > 0 {
                let frontmatterLines = Array(lines[1 ..< endIndex])
                for line in frontmatterLines {
                    if line.hasPrefix("name:") {
                        name = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("description:") {
                        description = String(line.dropFirst(12)).trimmingCharacters(in: .whitespaces)
                    }
                }
                content = lines[(endIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return Template(name: name, description: description, content: content, isBuiltIn: false)
    }
}
