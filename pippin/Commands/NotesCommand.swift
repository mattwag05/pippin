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

    /// Hint surfaced when a Notes JXA loop hits its 22s soft timeout.
    /// Mirrors `MailCommand.Search.timedOutHint`.
    static let timedOutHint = "Notes scan exceeded soft timeout, returning partial results — narrow with --folder or --limit for complete results"

    // MARK: - List

    public struct List: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List notes. Defaults to 50 most recently modified."
        )

        @Option(name: .long, help: "Filter by folder name.")
        public var folder: String?

        @Option(name: .long, help: "Maximum notes to return (default: 50). Ignored when --cursor or --page-size is set.")
        public var limit: Int = 50

        @OptionGroup public var pagination: PaginationOptions

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard limit > 0 else {
                throw ValidationError("--limit must be positive.")
            }
        }

        public mutating func execute() async throws -> AgentResult {
            if pagination.isActive {
                return try await runPaginated()
            }
            let outcome = try await detachBlocking { [folder, limit] in
                try NotesBridge.listNotes(folder: folder, limit: limit)
            }
            let notes = outcome.results
            // The shared helper applies --fields projection and the structured
            // timedOut advisory (envelope warnings) instead of a hand-rolled branch.
            return .emit(notes, timedOut: outcome.timedOut, timedOutHint: NotesCommand.timedOutHint)
        }

        private func runPaginated() async throws -> AgentResult {
            let hash = Pagination.filterHash(["folder": folder])
            let (offset, pageSize) = try Pagination.resolve(
                pagination, defaultPageSize: limit, filterHash: hash
            )
            // Native offset pushdown: the JXA list script skips the first
            // `offset` sorted notes and returns only `pageSize + 1` (the +1 is
            // the has-more sentinel). This lifts the old maxListLimit (500)
            // pagination ceiling — body fetches are bounded to the page window,
            // and the all-notes sort enumeration is bounded by the soft cap
            // (surfaced as timedOut), not by a fixed offset ceiling.
            let outcome = try await detachBlocking { [folder] in
                try NotesBridge.listNotes(folder: folder, limit: pageSize + 1, offset: offset)
            }
            let page = try Pagination.pageFromPushdown(
                fetched: outcome.results, offset: offset, pageSize: pageSize, filterHash: hash
            )
            return .emitPage(page, timedOut: outcome.timedOut, timedOutHint: NotesCommand.timedOutHint)
        }
    }

    // MARK: - Show

    public struct Show: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show full details of a note by ID."
        )

        @Argument(help: "Note ID (from `pippin notes list`).")
        public var id: String

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let note = try await detachBlocking { [id] in try NotesBridge.showNote(id: id) }
            // Exclude the large HTML body, include plainText instead.
            return AgentResult(NoteAgentView(note: note))
        }
    }

    // MARK: - Search

    public struct Search: AgentCommand {
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

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard limit > 0 else {
                throw ValidationError("--limit must be positive.")
            }
        }

        public mutating func execute() async throws -> AgentResult {
            let outcome = try await detachBlocking { [query, folder, limit] in
                try NotesBridge.searchNotes(query: query, folder: folder, limit: limit)
            }
            let notes = outcome.results
            return .emit(notes, timedOut: outcome.timedOut, timedOutHint: NotesCommand.timedOutHint)
        }
    }

    // MARK: - Folders

    public struct Folders: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "folders",
            abstract: "List all Notes folders."
        )

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let outcome = try await detachBlocking { try NotesBridge.listFolders() }
            let folders = outcome.results
            return .emit(folders, timedOut: outcome.timedOut, timedOutHint: NotesCommand.timedOutHint)
        }
    }

    // MARK: - Create

    public struct Create: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create a new note."
        )

        @Argument(help: "Note title.")
        public var title: String

        @Option(name: .long, help: "Folder name to create the note in.")
        public var folder: String?

        @Option(name: .long, help: "Note body content. Plain text; newlines are converted to formatted HTML unless --html is passed.")
        public var body: String?

        @Flag(name: .long, help: "Treat --body as raw HTML (skip plain-text-to-HTML conversion).")
        public var html: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let result = try await detachBlocking { [title, body, folder, html] in
                try NotesBridge.createNote(title: title, body: body, folder: folder, html: html)
            }
            return AgentResult(result)
        }
    }

    // MARK: - Edit

    public struct Edit: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "edit",
            abstract: "Edit a note's title or body."
        )

        @Argument(help: "Note ID (from `pippin notes list`).")
        public var id: String

        @Option(name: .long, help: "New title for the note.")
        public var title: String?

        @Option(name: .long, help: "New body content (replaces existing, or appends if --append). Plain text; newlines are converted to formatted HTML unless --html is passed.")
        public var body: String?

        @Flag(name: .long, help: "Append body content instead of replacing.")
        public var append: Bool = false

        @Flag(name: .long, help: "Treat --body as raw HTML (skip plain-text-to-HTML conversion).")
        public var html: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            if title == nil, body == nil {
                throw ValidationError("At least one of --title or --body must be provided.")
            }
        }

        public mutating func execute() async throws -> AgentResult {
            let result = try await detachBlocking { [id, title, body, append, html] in
                try NotesBridge.editNote(id: id, title: title, body: body, append: append, html: html)
            }
            return AgentResult(result)
        }
    }

    // MARK: - Delete

    public struct Delete: AgentCommand {
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

        public mutating func execute() async throws -> AgentResult {
            let result = try await detachBlocking { [id] in try NotesBridge.deleteNote(id: id) }
            return AgentResult(result)
        }
    }
}

// MARK: - Agent view helpers

/// Compact note view for `notes show`: excludes the large HTML body.
/// Internal (not private) so tests can assert the serialized shape.
struct NoteAgentView: Encodable {
    let id: String
    let title: String
    let plainText: String
    let folder: String
    let modifiedAt: String

    init(note: NoteInfo) {
        id = note.id
        title = note.title
        plainText = note.plainText
        folder = note.folder
        modifiedAt = note.modificationDate
    }
}
