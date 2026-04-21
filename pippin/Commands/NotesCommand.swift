import ArgumentParser
import Foundation

public struct NotesCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "notes",
        abstract: "Interact with Apple Notes.",
        subcommands: [
            List.self, Show.self, Search.self,
            Folders.self, Create.self, Edit.self, Delete.self,
        ]
    )

    public init() {}

    // MARK: - List

    public struct List: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List notes. Defaults to 50 most recently modified."
        )

        @Option(name: .long, help: "Filter by folder name.")
        public var folder: String?

        @Option(name: .long, help: "Maximum notes to return (default: 50).")
        public var limit: Int = 50

        @Option(name: .long, help: "Comma-separated JSON field names to include (e.g. id,title). JSON output only.")
        public var fields: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard limit > 0 else {
                throw ValidationError("--limit must be positive.")
            }
        }

        public mutating func run() throws {
            let notes = try NotesBridge.listNotes(folder: folder, limit: limit)
            if output.isJSON {
                try printFilteredNotes(notes, fields: fields)
            } else if output.isAgent {
                try output.printAgent(notes)
            } else {
                if notes.isEmpty {
                    print("No notes found.")
                    return
                }
                print(printNotesTable(notes))
            }
        }
    }

    // MARK: - Show

    public struct Show: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show full details of a note by ID."
        )

        @Argument(help: "Note ID (from `pippin notes list`).")
        public var id: String

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() throws {
            let note = try NotesBridge.showNote(id: id)
            if output.isJSON {
                try printJSON(note)
            } else if output.isAgent {
                // Agent mode: exclude large HTML body, include plainText instead
                try output.printAgent(NoteAgentView(note: note))
            } else {
                print(printNoteCard(note))
            }
        }
    }

    // MARK: - Search

    public struct Search: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "search",
            abstract: "Search notes by title or body content."
        )

        @Argument(help: "Search query.")
        public var query: String

        @Option(name: .long, help: "Filter by folder name.")
        public var folder: String?

        @Option(name: .long, help: "Maximum results to return (default: 50).")
        public var limit: Int = 50

        @Option(name: .long, help: "Comma-separated JSON field names to include. JSON output only.")
        public var fields: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard limit > 0 else {
                throw ValidationError("--limit must be positive.")
            }
        }

        public mutating func run() throws {
            let notes = try NotesBridge.searchNotes(query: query, folder: folder, limit: limit)
            if output.isJSON {
                try printFilteredNotes(notes, fields: fields)
            } else if output.isAgent {
                try output.printAgent(notes)
            } else {
                if notes.isEmpty {
                    print("No notes matching \"\(query)\".")
                    return
                }
                print(printNotesTable(notes))
            }
        }
    }

    // MARK: - Folders

    public struct Folders: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "folders",
            abstract: "List all Notes folders."
        )

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() throws {
            let folders = try NotesBridge.listFolders()
            if output.isJSON {
                try printJSON(folders)
            } else if output.isAgent {
                try output.printAgent(folders)
            } else {
                if folders.isEmpty {
                    print("No folders found.")
                    return
                }
                print(printFoldersTable(folders))
            }
        }
    }

    // MARK: - Create

    public struct Create: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create a new note."
        )

        @Argument(help: "Note title.")
        public var title: String

        @Option(name: .long, help: "Folder name to create the note in.")
        public var folder: String?

        @Option(name: .long, help: "Note body content (HTML or plain text).")
        public var body: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() throws {
            let result = try NotesBridge.createNote(title: title, body: body, folder: folder)
            if output.isJSON {
                try printJSON(result)
            } else if output.isAgent {
                try output.printAgent(result)
            } else {
                print(TextFormatter.actionResult(success: result.success, action: result.action, details: result.details))
            }
        }
    }

    // MARK: - Edit

    public struct Edit: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "edit",
            abstract: "Edit a note's title or body."
        )

        @Argument(help: "Note ID (from `pippin notes list`).")
        public var id: String

        @Option(name: .long, help: "New title for the note.")
        public var title: String?

        @Option(name: .long, help: "New body content (replaces existing, or appends if --append).")
        public var body: String?

        @Flag(name: .long, help: "Append body content instead of replacing.")
        public var append: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            if title == nil, body == nil {
                throw ValidationError("At least one of --title or --body must be provided.")
            }
        }

        public mutating func run() throws {
            let result = try NotesBridge.editNote(id: id, title: title, body: body, append: append)
            if output.isJSON {
                try printJSON(result)
            } else if output.isAgent {
                try output.printAgent(result)
            } else {
                print(TextFormatter.actionResult(success: result.success, action: result.action, details: result.details))
            }
        }
    }

    // MARK: - Delete

    public struct Delete: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Move a note to Recently Deleted."
        )

        @Argument(help: "Note ID (from `pippin notes list`).")
        public var id: String

        @Flag(name: .long, help: "Required: confirm deletion.")
        public var force: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard force else {
                throw ValidationError("Pass --force to confirm deletion.")
            }
        }

        public mutating func run() throws {
            let result = try NotesBridge.deleteNote(id: id)
            if output.isJSON {
                try printJSON(result)
            } else if output.isAgent {
                try output.printAgent(result)
            } else {
                print(TextFormatter.actionResult(success: result.success, action: result.action, details: result.details))
            }
        }
    }
}

// MARK: - Agent view helpers

/// Compact note view for agent mode — excludes large HTML body.
private struct NoteAgentView: Encodable {
    let id: String
    let title: String
    let plainText: String
    let folder: String
    let modificationDate: String

    init(note: NoteInfo) {
        id = note.id
        title = note.title
        plainText = note.plainText
        folder = note.folder
        modificationDate = note.modificationDate
    }
}

// MARK: - Text output helpers

private func printNotesTable(_ notes: [NoteInfo]) -> String {
    let rows = notes.map { note -> [String] in
        let shortId = note.id.components(separatedBy: "/").last ?? String(note.id.suffix(8))
        let date = TextFormatter.compactDate(note.modificationDate)
        return [shortId, date, note.folder, note.title]
    }
    return TextFormatter.table(
        headers: ["ID", "DATE", "FOLDER", "TITLE"],
        rows: rows,
        columnWidths: [10, 16, 18, 34]
    )
}

private func printNoteCard(_ note: NoteInfo) -> String {
    var fields: [(String, String)] = [
        ("id", note.id),
        ("title", note.title),
        ("folder", note.folder),
        ("folderId", note.folderId),
        ("creationDate", note.creationDate),
        ("modificationDate", note.modificationDate),
    ]
    if let account = note.account {
        fields.append(("account", account))
    }
    fields.append(("body", note.plainText))
    return TextFormatter.card(fields: fields)
}

private func printFoldersTable(_ folders: [NoteFolder]) -> String {
    let rows = folders.map { f -> [String] in
        [f.name, f.account ?? "", String(f.noteCount)]
    }
    return TextFormatter.table(
        headers: ["NAME", "ACCOUNT", "COUNT"],
        rows: rows,
        columnWidths: [30, 30, 8]
    )
}

private func printFilteredNotes(_ notes: [NoteInfo], fields: String?) throws {
    guard let fields else {
        try printJSON(notes)
        return
    }
    let fieldList = fields.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let allDicts: [[String: Any]] = try notes.map { note in
        let noteData = try encoder.encode(note)
        guard let dict = try JSONSerialization.jsonObject(with: noteData) as? [String: Any] else {
            throw EncodingError.invalidValue(note, .init(codingPath: [], debugDescription: "Expected JSON object"))
        }
        return fieldList.reduce(into: [:]) { result, field in
            if let val = dict[field] { result[field] = val }
        }
    }
    let data = try JSONSerialization.data(withJSONObject: allDicts, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}
