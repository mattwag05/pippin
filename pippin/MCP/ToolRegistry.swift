import Foundation

/// One registered MCP tool. Schema + argv builder live side-by-side so they can't drift.
struct MCPTool {
    let name: String
    let description: String
    let inputSchema: JSONValue
    /// Given the MCP `arguments` object (or nil), return the argv passed to the child
    /// `pippin` process. Always ends with `--format agent` so stdout is compact JSON.
    let buildArgs: @Sendable (JSONValue?) throws -> [String]

    var descriptor: MCPToolDescriptor {
        MCPToolDescriptor(name: name, description: description, inputSchema: inputSchema)
    }
}

/// Errors raised while translating MCP arguments into a child process argv.
enum MCPToolArgError: LocalizedError {
    case missingRequired(String)
    case wrongType(field: String, expected: String)
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case let .missingRequired(name): return "Missing required argument: \(name)"
        case let .wrongType(field, expected): return "Argument '\(field)' must be \(expected)"
        case let .unknownTool(name): return "Unknown tool: \(name)"
        }
    }
}

/// Build the argv prefix `[<parts>..., "--format", "agent"]`. Centralizes the contract
/// that every tool call must run the child in agent-output mode — enforced by
/// `testAllArgvEndWithFormatAgent`.
private func pippinArgv(_ parts: String...) -> [String] {
    parts + ["--format", "agent"]
}

enum ArgHelpers {
    static func string(_ args: JSONValue?, _ key: String) -> String? {
        args?[key]?.stringValue
    }

    static func requiredString(_ args: JSONValue?, _ key: String) throws -> String {
        guard let value = args?[key]?.stringValue else {
            throw MCPToolArgError.missingRequired(key)
        }
        return value
    }

    static func int(_ args: JSONValue?, _ key: String) -> Int64? {
        args?[key]?.intValue
    }

    static func bool(_ args: JSONValue?, _ key: String) -> Bool? {
        args?[key]?.boolValue
    }

    static func flagIfTrue(_ args: JSONValue?, _ key: String, flagName: String) -> [String] {
        bool(args, key) == true ? [flagName] : []
    }

    static func optionIfString(
        _ args: JSONValue?,
        _ key: String,
        flagName: String
    ) -> [String] {
        if let value = string(args, key) { return [flagName, value] }
        return []
    }

    static func optionIfInt(
        _ args: JSONValue?,
        _ key: String,
        flagName: String
    ) -> [String] {
        if let value = int(args, key) { return [flagName, String(value)] }
        return []
    }
}

// MARK: - Schema builder sugar

/// Type-safe helpers for composing JSON Schema as `JSONValue`.
enum Schema {
    static func object(
        properties: [String: JSONValue],
        required: [String] = []
    ) -> JSONValue {
        var dict: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            dict["required"] = .array(required.map { .string($0) })
        }
        // MCP clients ignore `additionalProperties` on most fields, but declaring it
        // false keeps schemas strict for clients that do validate.
        dict["additionalProperties"] = .bool(false)
        return .object(dict)
    }

    static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    static func integer(_ description: String, default defaultValue: Int? = nil) -> JSONValue {
        var dict: [String: JSONValue] = [
            "type": .string("integer"),
            "description": .string(description),
        ]
        if let defaultValue {
            dict["default"] = .int(Int64(defaultValue))
        }
        return .object(dict)
    }

    static func boolean(_ description: String, default defaultValue: Bool? = nil) -> JSONValue {
        var dict: [String: JSONValue] = [
            "type": .string("boolean"),
            "description": .string(description),
        ]
        if let defaultValue {
            dict["default"] = .bool(defaultValue)
        }
        return .object(dict)
    }

    static let empty: JSONValue = object(properties: [:])
}

// MARK: - Registry

/// Source of truth for the MCP tool surface. Adding a new tool is one entry.
enum MCPToolRegistry {
    static let tools: [MCPTool] = [
        // MARK: Mail

        MCPTool(
            name: "mail_accounts",
            description: "List configured Apple Mail accounts.",
            inputSchema: Schema.empty,
            buildArgs: { _ in pippinArgv("mail", "accounts") }
        ),
        MCPTool(
            name: "mail_mailboxes",
            description: "List mailboxes, optionally filtered to one account.",
            inputSchema: Schema.object(properties: [
                "account": Schema.string("Mail account name."),
            ]),
            buildArgs: { args in
                var argv = pippinArgv("mail", "mailboxes")
                argv += ArgHelpers.optionIfString(args, "account", flagName: "--account")
                return argv
            }
        ),
        MCPTool(
            name: "mail_list",
            description: "List messages in a mailbox. Defaults to INBOX, limit 20.",
            inputSchema: Schema.object(properties: [
                "account": Schema.string("Mail account name."),
                "mailbox": Schema.string("Mailbox name (default: INBOX)."),
                "unread": Schema.boolean("Only return unread messages.", default: false),
                "limit": Schema.integer("Maximum messages to return (default: 20).", default: 20),
                "page": Schema.integer("Page number (1-based).", default: 1),
            ]),
            buildArgs: { args in
                var argv = pippinArgv("mail", "list")
                argv += ArgHelpers.optionIfString(args, "account", flagName: "--account")
                argv += ArgHelpers.optionIfString(args, "mailbox", flagName: "--mailbox")
                argv += ArgHelpers.flagIfTrue(args, "unread", flagName: "--unread")
                argv += ArgHelpers.optionIfInt(args, "limit", flagName: "--limit")
                argv += ArgHelpers.optionIfInt(args, "page", flagName: "--page")
                return argv
            }
        ),
        MCPTool(
            name: "mail_show",
            description: "Show a single mail message by compound ID (account||mailbox||numericId).",
            inputSchema: Schema.object(
                properties: [
                    "messageId": Schema.string("Compound message ID from mail_list output."),
                    "subject": Schema.string("Alternative: find first message matching this subject."),
                ]
            ),
            buildArgs: { args in
                var argv = pippinArgv("mail", "show")
                if let id = ArgHelpers.string(args, "messageId") {
                    argv.append(id)
                } else if let subject = ArgHelpers.string(args, "subject") {
                    argv += ["--subject", subject]
                } else {
                    throw MCPToolArgError.missingRequired("messageId or subject")
                }
                return argv
            }
        ),
        MCPTool(
            name: "mail_search",
            description: "Search messages by subject/sender (add --body to include body text).",
            inputSchema: Schema.object(
                properties: [
                    "query": Schema.string("Search query (case-insensitive)."),
                    "account": Schema.string("Restrict to a single account."),
                    "mailbox": Schema.string("Restrict to a single mailbox."),
                    "body": Schema.boolean("Search message body too (slower).", default: false),
                    "after": Schema.string("Only messages on/after YYYY-MM-DD."),
                    "before": Schema.string("Only messages on/before YYYY-MM-DD."),
                    "to": Schema.string("Filter by recipient email."),
                    "limit": Schema.integer("Maximum results (default: 10).", default: 10),
                    "semantic": Schema.boolean(
                        "Use embedding-based semantic search (requires prior `mail index`).",
                        default: false
                    ),
                ],
                required: ["query"]
            ),
            buildArgs: { args in
                var argv = pippinArgv("mail", "search")
                let query = try ArgHelpers.requiredString(args, "query")
                argv.append(query)
                argv += ArgHelpers.optionIfString(args, "account", flagName: "--account")
                argv += ArgHelpers.optionIfString(args, "mailbox", flagName: "--mailbox")
                argv += ArgHelpers.flagIfTrue(args, "body", flagName: "--body")
                argv += ArgHelpers.optionIfString(args, "after", flagName: "--after")
                argv += ArgHelpers.optionIfString(args, "before", flagName: "--before")
                argv += ArgHelpers.optionIfString(args, "to", flagName: "--to")
                argv += ArgHelpers.optionIfInt(args, "limit", flagName: "--limit")
                argv += ArgHelpers.flagIfTrue(args, "semantic", flagName: "--semantic")
                return argv
            }
        ),

        // MARK: Calendar

        MCPTool(
            name: "calendar_list",
            description: "List calendars configured in Apple Calendar.",
            inputSchema: Schema.object(properties: [
                "type": Schema.string("Filter by type: local, calDAV, exchange, subscription, birthday."),
            ]),
            buildArgs: { args in
                var argv = pippinArgv("calendar", "list")
                argv += ArgHelpers.optionIfString(args, "type", flagName: "--type")
                return argv
            }
        ),
        MCPTool(
            name: "calendar_events",
            description: "List calendar events in a date range. Defaults to today.",
            inputSchema: Schema.object(properties: [
                "from": Schema.string("Start date (YYYY-MM-DD or ISO 8601)."),
                "to": Schema.string("End date (YYYY-MM-DD or ISO 8601)."),
                "calendar": Schema.string("Calendar ID to filter by."),
                "calendarName": Schema.string("Calendar name to filter by (case-insensitive)."),
                "range": Schema.string("Shorthand range: today, today+N, week, month."),
                "limit": Schema.integer("Max events (default: 50).", default: 50),
            ]),
            buildArgs: { args in
                var argv = pippinArgv("calendar", "events")
                argv += ArgHelpers.optionIfString(args, "from", flagName: "--from")
                argv += ArgHelpers.optionIfString(args, "to", flagName: "--to")
                argv += ArgHelpers.optionIfString(args, "calendar", flagName: "--calendar")
                argv += ArgHelpers.optionIfString(args, "calendarName", flagName: "--calendar-name")
                argv += ArgHelpers.optionIfString(args, "range", flagName: "--range")
                argv += ArgHelpers.optionIfInt(args, "limit", flagName: "--limit")
                return argv
            }
        ),
        MCPTool(
            name: "calendar_today",
            description: "List events scheduled for today.",
            inputSchema: Schema.empty,
            buildArgs: { _ in pippinArgv("calendar", "today") }
        ),
        MCPTool(
            name: "calendar_remaining",
            description: "List events from now until end of today.",
            inputSchema: Schema.empty,
            buildArgs: { _ in pippinArgv("calendar", "remaining") }
        ),
        MCPTool(
            name: "calendar_upcoming",
            description: "List events for the next 7 days.",
            inputSchema: Schema.empty,
            buildArgs: { _ in pippinArgv("calendar", "upcoming") }
        ),
        MCPTool(
            name: "calendar_search",
            description: "Search calendar events by text across a date range.",
            inputSchema: Schema.object(
                properties: [
                    "query": Schema.string("Search query (matches title, notes, location)."),
                    "from": Schema.string("Start date (default: 6 months ago)."),
                    "to": Schema.string("End date (default: 6 months from now)."),
                    "calendarName": Schema.string("Filter by calendar name."),
                    "limit": Schema.integer("Max results (default: 50).", default: 50),
                ],
                required: ["query"]
            ),
            buildArgs: { args in
                var argv = pippinArgv("calendar", "search")
                try argv += ["--query", ArgHelpers.requiredString(args, "query")]
                argv += ArgHelpers.optionIfString(args, "from", flagName: "--from")
                argv += ArgHelpers.optionIfString(args, "to", flagName: "--to")
                argv += ArgHelpers.optionIfString(args, "calendarName", flagName: "--calendar-name")
                argv += ArgHelpers.optionIfInt(args, "limit", flagName: "--limit")
                return argv
            }
        ),
        MCPTool(
            name: "calendar_create",
            description: "Create a new calendar event.",
            inputSchema: Schema.object(
                properties: [
                    "title": Schema.string("Event title."),
                    "start": Schema.string("Start date/time (YYYY-MM-DD or ISO 8601)."),
                    "end": Schema.string("End date/time (default: start + 1 hour)."),
                    "calendar": Schema.string("Calendar ID to create in."),
                    "location": Schema.string("Event location."),
                    "notes": Schema.string("Event notes."),
                    "url": Schema.string("Event URL."),
                    "allDay": Schema.boolean("Create as all-day event.", default: false),
                    "alert": Schema.string("Alert before event (e.g. '15m', '1h', '2d')."),
                ],
                required: ["title", "start"]
            ),
            buildArgs: { args in
                var argv = pippinArgv("calendar", "create")
                try argv += ["--title", ArgHelpers.requiredString(args, "title")]
                try argv += ["--start", ArgHelpers.requiredString(args, "start")]
                argv += ArgHelpers.optionIfString(args, "end", flagName: "--end")
                argv += ArgHelpers.optionIfString(args, "calendar", flagName: "--calendar")
                argv += ArgHelpers.optionIfString(args, "location", flagName: "--location")
                argv += ArgHelpers.optionIfString(args, "notes", flagName: "--notes")
                argv += ArgHelpers.optionIfString(args, "url", flagName: "--url")
                argv += ArgHelpers.flagIfTrue(args, "allDay", flagName: "--all-day")
                argv += ArgHelpers.optionIfString(args, "alert", flagName: "--alert")
                return argv
            }
        ),

        // MARK: Reminders

        MCPTool(
            name: "reminders_lists",
            description: "List all Apple Reminders lists.",
            inputSchema: Schema.empty,
            buildArgs: { _ in pippinArgv("reminders", "lists") }
        ),
        MCPTool(
            name: "reminders_list",
            description: "List reminders, defaulting to incomplete items.",
            inputSchema: Schema.object(properties: [
                "list": Schema.string("Reminder list ID from reminders_lists."),
                "completed": Schema.boolean("Include completed reminders.", default: false),
                "dueBefore": Schema.string("Due before date (YYYY-MM-DD or ISO 8601)."),
                "dueAfter": Schema.string("Due after date (YYYY-MM-DD or ISO 8601)."),
                "priority": Schema.string("Filter by priority: high, medium, low, none."),
                "limit": Schema.integer("Max reminders (default: 50).", default: 50),
            ]),
            buildArgs: { args in
                var argv = pippinArgv("reminders", "list")
                argv += ArgHelpers.optionIfString(args, "list", flagName: "--list")
                argv += ArgHelpers.flagIfTrue(args, "completed", flagName: "--completed")
                argv += ArgHelpers.optionIfString(args, "dueBefore", flagName: "--due-before")
                argv += ArgHelpers.optionIfString(args, "dueAfter", flagName: "--due-after")
                argv += ArgHelpers.optionIfString(args, "priority", flagName: "--priority")
                argv += ArgHelpers.optionIfInt(args, "limit", flagName: "--limit")
                return argv
            }
        ),
        MCPTool(
            name: "reminders_show",
            description: "Show full details for a single reminder by ID.",
            inputSchema: Schema.object(
                properties: ["id": Schema.string("Reminder ID or prefix.")],
                required: ["id"]
            ),
            buildArgs: { args in
                var argv = pippinArgv("reminders", "show")
                try argv.append(ArgHelpers.requiredString(args, "id"))
                return argv
            }
        ),
        MCPTool(
            name: "reminders_search",
            description: "Search reminders by title/notes text.",
            inputSchema: Schema.object(
                properties: [
                    "query": Schema.string("Search query."),
                    "list": Schema.string("Restrict to a single list ID."),
                    "completed": Schema.boolean("Search completed reminders instead.", default: false),
                    "limit": Schema.integer("Max results (default: 50).", default: 50),
                ],
                required: ["query"]
            ),
            buildArgs: { args in
                var argv = pippinArgv("reminders", "search")
                try argv.append(ArgHelpers.requiredString(args, "query"))
                argv += ArgHelpers.optionIfString(args, "list", flagName: "--list")
                argv += ArgHelpers.flagIfTrue(args, "completed", flagName: "--completed")
                argv += ArgHelpers.optionIfInt(args, "limit", flagName: "--limit")
                return argv
            }
        ),
        MCPTool(
            name: "reminders_create",
            description: "Create a new reminder.",
            inputSchema: Schema.object(
                properties: [
                    "title": Schema.string("Reminder title."),
                    "list": Schema.string("Target list ID (default: default list)."),
                    "due": Schema.string("Due date/time (YYYY-MM-DD or ISO 8601)."),
                    "priority": Schema.string("Priority: high, medium, low, none."),
                    "notes": Schema.string("Reminder notes."),
                    "url": Schema.string("Reminder URL."),
                ],
                required: ["title"]
            ),
            buildArgs: { args in
                var argv = pippinArgv("reminders", "create")
                try argv.append(ArgHelpers.requiredString(args, "title"))
                argv += ArgHelpers.optionIfString(args, "list", flagName: "--list")
                argv += ArgHelpers.optionIfString(args, "due", flagName: "--due")
                argv += ArgHelpers.optionIfString(args, "priority", flagName: "--priority")
                argv += ArgHelpers.optionIfString(args, "notes", flagName: "--notes")
                argv += ArgHelpers.optionIfString(args, "url", flagName: "--url")
                return argv
            }
        ),
        MCPTool(
            name: "reminders_complete",
            description: "Mark a reminder as completed.",
            inputSchema: Schema.object(
                properties: ["id": Schema.string("Reminder ID or prefix.")],
                required: ["id"]
            ),
            buildArgs: { args in
                var argv = pippinArgv("reminders", "complete")
                try argv.append(ArgHelpers.requiredString(args, "id"))
                return argv
            }
        ),

        // MARK: Contacts

        MCPTool(
            name: "contacts_search",
            description: "Search contacts by name (default) or email.",
            inputSchema: Schema.object(
                properties: [
                    "query": Schema.string("Search query."),
                    "email": Schema.boolean("Search by email instead of name.", default: false),
                    "fields": Schema.string("Comma-separated fields to include (e.g. id,fullName,emails)."),
                ],
                required: ["query"]
            ),
            buildArgs: { args in
                var argv = pippinArgv("contacts", "search")
                try argv.append(ArgHelpers.requiredString(args, "query"))
                argv += ArgHelpers.flagIfTrue(args, "email", flagName: "--email")
                argv += ArgHelpers.optionIfString(args, "fields", flagName: "--fields")
                return argv
            }
        ),
        MCPTool(
            name: "contacts_show",
            description: "Show full contact details by identifier.",
            inputSchema: Schema.object(
                properties: ["identifier": Schema.string("Contact identifier.")],
                required: ["identifier"]
            ),
            buildArgs: { args in
                var argv = pippinArgv("contacts", "show")
                try argv.append(ArgHelpers.requiredString(args, "identifier"))
                return argv
            }
        ),

        // MARK: Notes

        MCPTool(
            name: "notes_list",
            description: "List Apple Notes, defaulting to 50 most recently modified.",
            inputSchema: Schema.object(properties: [
                "folder": Schema.string("Filter by folder name."),
                "limit": Schema.integer("Max notes (default: 50).", default: 50),
            ]),
            buildArgs: { args in
                var argv = pippinArgv("notes", "list")
                argv += ArgHelpers.optionIfString(args, "folder", flagName: "--folder")
                argv += ArgHelpers.optionIfInt(args, "limit", flagName: "--limit")
                return argv
            }
        ),
        MCPTool(
            name: "notes_search",
            description: "Search notes by title or body content.",
            inputSchema: Schema.object(
                properties: [
                    "query": Schema.string("Search query."),
                    "folder": Schema.string("Filter by folder name."),
                    "limit": Schema.integer("Max results (default: 50).", default: 50),
                ],
                required: ["query"]
            ),
            buildArgs: { args in
                var argv = pippinArgv("notes", "search")
                try argv.append(ArgHelpers.requiredString(args, "query"))
                argv += ArgHelpers.optionIfString(args, "folder", flagName: "--folder")
                argv += ArgHelpers.optionIfInt(args, "limit", flagName: "--limit")
                return argv
            }
        ),
        MCPTool(
            name: "notes_show",
            description: "Show full details of a note by ID (returns plainText, not HTML).",
            inputSchema: Schema.object(
                properties: ["id": Schema.string("Note ID from notes_list.")],
                required: ["id"]
            ),
            buildArgs: { args in
                var argv = pippinArgv("notes", "show")
                try argv.append(ArgHelpers.requiredString(args, "id"))
                return argv
            }
        ),
        MCPTool(
            name: "notes_folders",
            description: "List all Apple Notes folders.",
            inputSchema: Schema.empty,
            buildArgs: { _ in pippinArgv("notes", "folders") }
        ),

        // MARK: Memos

        MCPTool(
            name: "memos_list",
            description: "List Voice Memos recordings (most recent first).",
            inputSchema: Schema.object(properties: [
                "since": Schema.string("Only recordings on or after YYYY-MM-DD."),
                "limit": Schema.integer("Maximum number of results (default: 20).", default: 20),
            ]),
            buildArgs: { args in
                var argv = pippinArgv("memos", "list")
                argv += ArgHelpers.optionIfString(args, "since", flagName: "--since")
                argv += ArgHelpers.optionIfInt(args, "limit", flagName: "--limit")
                return argv
            }
        ),
        MCPTool(
            name: "memos_info",
            description: "Show full metadata for a single Voice Memos recording by ID.",
            inputSchema: Schema.object(
                properties: ["id": Schema.string("Memo UUID from memos_list output.")],
                required: ["id"]
            ),
            buildArgs: { args in
                var argv = pippinArgv("memos", "info")
                try argv.append(ArgHelpers.requiredString(args, "id"))
                return argv
            }
        ),
        MCPTool(
            name: "memos_export",
            description: "Copy Voice Memos recording(s) to a directory, optionally with transcript sidecars.",
            inputSchema: Schema.object(
                properties: [
                    "id": Schema.string("Memo UUID (omit with all=true)."),
                    "all": Schema.boolean("Export every recording.", default: false),
                    "output": Schema.string("Destination directory (created if absent)."),
                    "transcribe": Schema.boolean("Transcribe audio and write sidecar.", default: false),
                    "sidecarFormat": Schema.string("Sidecar format: txt (default), srt, markdown, rtf."),
                    "forceTranscribe": Schema.boolean("Bypass transcript cache.", default: false),
                    "jobs": Schema.integer("Parallel transcription jobs (default: 2).", default: 2),
                ],
                required: ["output"]
            ),
            buildArgs: { args in
                var argv = pippinArgv("memos", "export")
                let all = ArgHelpers.bool(args, "all") == true
                if let id = ArgHelpers.string(args, "id") {
                    argv.append(id)
                } else if !all {
                    throw MCPToolArgError.missingRequired("id (or all=true)")
                }
                if all { argv.append("--all") }
                try argv += ["--output", ArgHelpers.requiredString(args, "output")]
                argv += ArgHelpers.flagIfTrue(args, "transcribe", flagName: "--transcribe")
                argv += ArgHelpers.optionIfString(args, "sidecarFormat", flagName: "--sidecar-format")
                argv += ArgHelpers.flagIfTrue(args, "forceTranscribe", flagName: "--force-transcribe")
                argv += ArgHelpers.optionIfInt(args, "jobs", flagName: "--jobs")
                return argv
            }
        ),
        MCPTool(
            name: "memos_transcribe",
            description: "Transcribe Voice Memos audio to text. Requires mlx-audio (see `pippin doctor`).",
            inputSchema: Schema.object(properties: [
                "id": Schema.string("Memo UUID (omit with all=true)."),
                "all": Schema.boolean("Transcribe every recording.", default: false),
                "output": Schema.string("Directory to write .txt files (default: inline in JSON)."),
                "force": Schema.boolean("Bypass transcript cache.", default: false),
                "jobs": Schema.integer("Parallel transcription jobs (default: 2).", default: 2),
            ]),
            buildArgs: { args in
                var argv = pippinArgv("memos", "transcribe")
                let all = ArgHelpers.bool(args, "all") == true
                if let id = ArgHelpers.string(args, "id") {
                    argv.append(id)
                } else if !all {
                    throw MCPToolArgError.missingRequired("id (or all=true)")
                }
                if all { argv.append("--all") }
                argv += ArgHelpers.optionIfString(args, "output", flagName: "--output")
                argv += ArgHelpers.flagIfTrue(args, "force", flagName: "--force")
                argv += ArgHelpers.optionIfInt(args, "jobs", flagName: "--jobs")
                return argv
            }
        ),
        MCPTool(
            name: "memos_summarize",
            description: "Summarize a Voice Memos recording using an AI provider (ollama or claude).",
            inputSchema: Schema.object(properties: [
                "id": Schema.string("Memo UUID (omit with all=true)."),
                "all": Schema.boolean("Summarize every recording.", default: false),
                "template": Schema.string("Template name (e.g. meeting-notes, summary, action-items)."),
                "prompt": Schema.string("Free-form prompt (overrides template)."),
                "provider": Schema.string("AI provider: ollama or claude (default: ollama)."),
                "model": Schema.string("Model name (provider-specific default)."),
                "since": Schema.string("With all=true, only memos on or after YYYY-MM-DD."),
                "output": Schema.string("Write output to a directory instead of inline JSON."),
                "jobs": Schema.integer("Parallel summarization jobs (default: 2).", default: 2),
            ]),
            buildArgs: { args in
                var argv = pippinArgv("memos", "summarize")
                let all = ArgHelpers.bool(args, "all") == true
                if let id = ArgHelpers.string(args, "id") {
                    argv.append(id)
                } else if !all {
                    throw MCPToolArgError.missingRequired("id (or all=true)")
                }
                if all { argv.append("--all") }
                argv += ArgHelpers.optionIfString(args, "template", flagName: "--template")
                argv += ArgHelpers.optionIfString(args, "prompt", flagName: "--prompt")
                argv += ArgHelpers.optionIfString(args, "provider", flagName: "--provider")
                argv += ArgHelpers.optionIfString(args, "model", flagName: "--model")
                argv += ArgHelpers.optionIfString(args, "since", flagName: "--since")
                argv += ArgHelpers.optionIfString(args, "output", flagName: "--output")
                argv += ArgHelpers.optionIfInt(args, "jobs", flagName: "--jobs")
                return argv
            }
        ),

        // MARK: System

        MCPTool(
            name: "status",
            description: "System dashboard: accounts, events, reminders, permissions.",
            inputSchema: Schema.empty,
            buildArgs: { _ in pippinArgv("status") }
        ),
        MCPTool(
            name: "doctor",
            description: "Check pippin's system requirements and permissions.",
            inputSchema: Schema.empty,
            buildArgs: { _ in pippinArgv("doctor") }
        ),
    ]

    /// Look up a tool by name. Returns nil if unknown.
    static func tool(named name: String) -> MCPTool? {
        tools.first { $0.name == name }
    }
}
