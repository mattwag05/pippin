import Foundation

/// One registered MCP tool, generated from an `MCPToolSpec` and the
/// ArgumentParser definition of the command it runs (see ToolSpec.swift).
struct MCPTool {
    /// What a call can change. Drives the `tools/list` annotations and what a
    /// timeout means: a read can be retried, a mutation may already have happened.
    enum Effect: Equatable {
        case readOnly
        /// `verifyWith` names a read-only tool that takes no required arguments
        /// and shows whether the change landed.
        case mutating(verifyWith: String?)
    }

    let name: String
    /// Nil means unclassified, which the dispatcher treats as mutating.
    /// `ToolRegistryTests` fails on a registered tool that leaves it nil.
    let effect: Effect?
    let description: String
    let inputSchema: JSONValue
    /// Given the MCP `arguments` object (or nil), return the argv passed to the child
    /// `pippin` process. Always includes `--format agent` so stdout is compact JSON.
    /// Runs for every call — including in-process tools — so argument errors surface
    /// identically on both dispatch paths.
    let buildArgs: @Sendable (JSONValue?) throws -> [String]
    /// Optional in-process handler (see `MCPInProcessTools`), given the `buildArgs`
    /// argv. When non-nil the dispatcher calls this instead of spawning a child;
    /// the returned string must be the envelope the child would print.
    let inProcess: (@Sendable ([String]) async throws -> String)?

    init(
        name: String,
        effect: Effect? = nil,
        description: String,
        inputSchema: JSONValue,
        buildArgs: @escaping @Sendable (JSONValue?) throws -> [String],
        inProcess: (@Sendable ([String]) async throws -> String)? = nil
    ) {
        self.name = name
        self.effect = effect
        self.description = description
        self.inputSchema = inputSchema
        self.buildArgs = buildArgs
        self.inProcess = inProcess
    }

    var descriptor: MCPToolDescriptor {
        let readOnly = effect == .readOnly
        // Every tool that is not read-only passes through `SafetyGate`, which
        // accepts confirmToken and idempotencyKey for all of them.
        return MCPToolDescriptor(
            name: name, description: description,
            inputSchema: readOnly ? inputSchema : SafetyGate.withReservedArguments(inputSchema),
            annotations: .init(readOnlyHint: readOnly, destructiveHint: !readOnly)
        )
    }
}

/// Errors raised while translating MCP arguments into a child process argv.
enum MCPToolArgError: LocalizedError, RemediableError {
    case missingRequired(String)
    case wrongType(field: String, expected: String)

    var errorDescription: String? {
        switch self {
        case let .missingRequired(name): return "Missing required argument: \(name)"
        case let .wrongType(field, expected): return "Argument '\(field)' must be \(expected)"
        }
    }

    var agentCode: String {
        switch self {
        case .missingRequired: return "missing_required"
        case .wrongType: return "invalid_argument"
        }
    }

    var nextStep: NextStep { .none }
}

enum ArgHelpers {
    static func string(_ args: JSONValue?, _ key: String) -> String? {
        args?[key]?.stringValue
    }

    /// A value passed as a bare positional (an id). These sit before the
    /// options, where a `--` separator cannot go, so one that starts with "-"
    /// would be parsed as a flag: an id of `--version` used to return the
    /// version text as a successful result. No real id starts with "-".
    static func notFlagLike(_ value: String, _ key: String) throws -> String {
        guard !value.hasPrefix("-") else {
            throw MCPToolArgError.wrongType(field: key, expected: "a value that does not start with '-'")
        }
        return value
    }

    static func int(_ args: JSONValue?, _ key: String) -> Int64? {
        args?[key]?.intValue
    }

    static func bool(_ args: JSONValue?, _ key: String) -> Bool? {
        args?[key]?.boolValue
    }

    static func stringArray(_ args: JSONValue?, _ key: String) -> [String]? {
        guard let items = args?[key]?.arrayValue else { return nil }
        let strings = items.compactMap(\.stringValue)
        return strings.isEmpty ? nil : strings
    }

    static func double(_ args: JSONValue?, _ key: String) -> Double? {
        args?[key]?.doubleValue
    }

    static func flagIfTrue(_ args: JSONValue?, _ key: String, flagName: String) -> [String] {
        bool(args, key) == true ? [flagName] : []
    }

    /// Outbound-send gate: an agent must see a preview and re-call with
    /// `confirm: true` to actually deliver mail.
    static func dryRunUnlessConfirmed(_ args: JSONValue?) -> [String] {
        bool(args, "confirm") == true ? ["--confirm"] : ["--dry-run"]
    }

    /// Destructive-delete gate: resolve `--force` from an explicit `confirm: true`,
    /// or throw before the child is ever spawned. Load-bearing — `contacts delete`
    /// blocks on `readLine()` without `--force`, which under MCP would hang the child
    /// until the 60s timeout instead of returning an actionable error.
    static func forceFromConfirm(_ args: JSONValue?) throws -> [String] {
        guard bool(args, "confirm") == true else {
            throw MCPToolArgError.missingRequired("confirm (must be true — deletion cannot be undone)")
        }
        return ["--force"]
    }

    /// Bind an option and its value as a single `--flag=value` token. The `=`
    /// form is load-bearing: a value supplied by an MCP client (e.g. a search
    /// body, or a note/reminder title starting with "-" like a markdown bullet)
    /// would otherwise be misparsed by ArgumentParser as a stray flag, failing
    /// the whole tool call. Process argv is not shell-split, so spaces/quotes in
    /// `value` are preserved verbatim.
    static func option(_ flagName: String, _ value: String) -> String {
        "\(flagName)=\(value)"
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

// MARK: - Special bindings

extension MCPProperty {
    /// `confirm` on a delete: refuses the call unless true, then passes `--force`.
    static func confirmGate(
        _ description: String,
        emit: @escaping @Sendable (JSONValue?) throws -> [String] = { try ArgHelpers.forceFromConfirm($0) }
    ) -> MCPProperty {
        .special("confirm", schema: Schema.boolean(description, default: false), required: true, emit: .custom(emit))
    }

    /// `confirm` on a send: `--confirm` when true, else a `--dry-run` preview.
    static let confirmSend = MCPProperty.arg(
        "confirm", "--confirm", "Must be true to actually send. Omitted or false returns a dry-run preview.",
        emit: .custom { ArgHelpers.dryRunUnlessConfirmed($0) }
    )

    /// The memo id positional of a command that also takes `--all`: one of
    /// the two is required.
    static func idOrAll(_ description: String) -> MCPProperty {
        .arg("id", .positional, description, emit: .custom { args in
            guard let id = ArgHelpers.string(args, "id") else {
                if ArgHelpers.bool(args, "all") == true { return [] }
                throw MCPToolArgError.missingRequired("id (or all=true)")
            }
            return try [ArgHelpers.notFlagLike(id, "id")]
        })
    }

    static let expectMessageId = MCPProperty.arg(
        "expectMessageId", "--expect-message-id",
        "Optional RFC Message-ID the id must still name: a row's messageIdHeader (request it with fields). On mismatch nothing happens and the error code is message_identity_mismatch."
    )
}

// MARK: - Registry

/// Source of truth for the MCP tool surface. Adding a new tool is one spec;
/// its schema and argv come from the CLI command it names.
enum MCPToolRegistry {
    static let tools: [MCPTool] = specs.map { MCPTool(addingListOptions($0)) }

    /// List and search tools accept `--fields` at the CLI through the shared
    /// output options; these expose it, plus cursor paging where it exists.
    private static let projectableTools: Set = [
        "mail_list", "mail_search", "mail_activity", "calendar_events", "calendar_today",
        "calendar_remaining", "calendar_upcoming", "calendar_search", "reminders_list",
        "reminders_search", "contacts_search", "contacts_list", "notes_list", "notes_search",
        "messages_list", "messages_search", "memos_list",
    ]
    private static let pagedTools: Set = [
        "mail_list", "mail_search", "calendar_events", "calendar_upcoming", "reminders_list",
        "contacts_search", "notes_list", "memos_list",
    ]

    private static func addingListOptions(_ spec: MCPToolSpec) -> MCPToolSpec {
        guard projectableTools.contains(spec.name) else { return spec }
        var extra: [MCPProperty] = [
            .arg("fields", "--fields", "Comma-separated row keys, or `all`. Default: essential fields."),
        ]
        if pagedTools.contains(spec.name) {
            extra += [
                .arg("cursor", "--cursor", "Opaque next_cursor from a previous response."),
                .arg("pageSize", "--page-size", "Rows per page when paginating.", as: .integer),
                .arg("page", "--page", "1-based page number. Ignored when cursor is set.", as: .integer),
            ]
        }
        var spec = spec
        // Before `--format`, so a trailing `-- <positional>` stays last.
        spec.properties += extra.filter { option in !spec.properties.contains { $0.name == option.name } }
            .map { option in
                var option = option
                option.leading = true
                return option
            }
        return spec
    }

    private static let specs: [MCPToolSpec] = [
        // MARK: Mail

        MCPToolSpec("mail_accounts", .readOnly, "List configured Apple Mail accounts.", inProcess: MCPInProcessTools.executeMailRead),
        MCPToolSpec("mail_mailboxes", .readOnly, "List mailboxes, optionally filtered to one account.", inProcess: MCPInProcessTools.executeMailRead, properties: [
            .arg("account", "--account", "Mail account name."),
        ]),
        MCPToolSpec("mail_list", .readOnly, "List messages in a mailbox. Defaults to INBOX, limit 20. Set preview to ~200 for agent scan workflows to avoid N+1 mail_show calls.", inProcess: MCPInProcessTools.executeMailRead, properties: [
            .arg("account", "--account", "Mail account name."),
            .arg("mailbox", "--mailbox"),
            .arg("unread", "--unread", "Only return unread messages."),
            .arg("limit", "--limit", "Maximum messages to return (default: 20; capped at 500).", as: .integer),
            .arg("page", "--page", "Page number (1-based).", as: .integer, default: .int(1)),
            .arg("preview", "--preview", "Include a plain-text body preview of up to N chars per message (forces per-message IMAP fetch; use ~200 for scan workflows).", as: .integer),
            .arg("after", "--after", "Only messages on/after YYYY-MM-DD."),
            .arg("before", "--before", "Only messages on/before YYYY-MM-DD."),
            .arg("fields", "--fields", "Comma-separated JSON field names to include (e.g. id,subject,from). Trims the payload to fewer tokens."),
        ]),
        MCPToolSpec("mail_activity", .readOnly, "Combined recent mail activity across multiple mailboxes (INBOX + Sent by default). Use this for scan workflows instead of N calls to mail_list. Default is metadata-only (preview 0, sub-second); pass preview > 0 for body snippets, which force per-message body fetches (~30-40s).", properties: [
            .arg("account", "--account", "Mail account name."),
            .arg("mailboxes", "--mailboxes", "Comma-separated mailbox names (default: INBOX,Sent)."),
            .arg("since", "--since"),
            .arg("limit", "--limit", "Maximum messages to return (default: 50; capped at 500).", as: .integer),
            // The CLI's own default is 200 (human use keeps snippets), so an
            // omitted MCP arg must pass --preview 0 explicitly.
            .arg(
                "preview", "--preview",
                "Plain-text preview length in chars (default: 0 = metadata-only, sub-second). Values > 0 force per-message body fetches (~30-40s).",
                as: .integer, default: .int(0),
                emit: .custom { args in [ArgHelpers.option("--preview", String(ArgHelpers.int(args, "preview") ?? 0))] }
            ),
        ]),
        MCPToolSpec("mail_show", .readOnly, "Show one or more mail messages by compound ID (account||mailbox||numericId). Pass messageIds with 2+ IDs to batch-fetch in one call (single batched Mail fetch; data becomes an array).", properties: [
            .arg("messageIds", .positional, "Two or more compound message IDs to fetch in one batched call. `data` is an array in input order.", emit: .none),
            // messageIds, messageId and subject are alternatives; one is required.
            .special("messageId", schema: Schema.string("Compound message ID from mail_list output."), emit: .custom { args in
                if let ids = ArgHelpers.stringArray(args, "messageIds") {
                    return try ids.map { try ArgHelpers.notFlagLike($0, "messageIds") }
                } else if let id = ArgHelpers.string(args, "messageId") {
                    return try [ArgHelpers.notFlagLike(id, "messageId")]
                } else if let subject = ArgHelpers.string(args, "subject") {
                    return [ArgHelpers.option("--subject", subject)]
                }
                throw MCPToolArgError.missingRequired("messageId, messageIds, or subject")
            }),
            .arg("subject", "--subject", "Alternative: find first message matching this subject.", emit: .none),
        ]),
        MCPToolSpec("mail_verify", .readOnly, "Inspect a message's headers against the sender's historical baseline (DKIM domain/selector, Message-ID domain, Date TZ offset, SPF/DKIM/DMARC results). Returns per-dimension comparison, anomaly warnings, the full raw-source auth chain (every Received hop, all Authentication-Results instances, ARC set, DKIM signatures) in `authChain`, and a verdict. Use on any suspicious message before acting on its contents.", properties: [
            .arg("messageId", .positional, "Compound message ID from mail_list or mail_show output."),
        ]),
        MCPToolSpec("mail_attachments", .mutating(verifyWith: nil), "List and download attachments for a message. When saveDir is omitted, attachments are written to pippin's cache directory (~/Library/Caches/pippin/attachments/<msg>/) and the paths are returned in `savedPath`; the agent can then read the files with its file tools.", properties: [
            .arg("messageId", .positional, "Compound message ID from mail_list or mail_show output."),
            .arg("saveDir", "--save-dir", "Optional directory to save attachments into. If omitted, a pippin cache directory is used.", emit: .custom { args in
                ArgHelpers.string(args, "saveDir").map { [ArgHelpers.option("--save-dir", $0)] } ?? ["--save-to-cache"]
            }),
            .expectMessageId,
        ]),
        MCPToolSpec("mail_search", .readOnly, "Search messages by subject or sender. Use `from` for sender-only searches without body scanning. `body: true` performs the slower content scan; body-matched hits return a bodyPreview snippet.", inProcess: MCPInProcessTools.executeMailRead, properties: [
            .arg("query", .trailing, "Search query (case-insensitive)."),
            .arg("account", "--account", "Restrict to a single account."),
            .arg("mailbox", "--mailbox", "Restrict to a single mailbox."),
            .arg("body", "--body", "Search message body too (slower). Hits matched via the body include a bodyPreview snippet."),
            .arg("after", "--after", "Only messages on/after YYYY-MM-DD."),
            .arg("before", "--before", "Only messages on/before YYYY-MM-DD."),
            .arg("to", "--to", "Filter by recipient email."),
            .arg("from", "--from", "Filter by sender email/name substring."),
            .arg("limit", "--limit", "Maximum results (default: 10; capped at 500).", as: .integer),
            .arg("preview", "--preview", "Include a plain-text bodyPreview of up to N chars on every hit. Uncached hits cost one batched body fetch (slower).", as: .integer),
            .arg("semantic", "--semantic", "Use embedding-based semantic search (requires prior `mail index`)."),
            .arg("fields", "--fields", "Comma-separated JSON field names to include (e.g. id,subject,from). Trims the payload to fewer tokens."),
        ]),
        MCPToolSpec("mail_mark", .mutating(verifyWith: "mail_list"), "Mark a message as read or unread. Reversible: call again with the opposite `read` value.", properties: [
            .arg("messageId", .positional, "Compound message ID from mail_list output."),
            // `mail mark` validate() rejects both-or-neither, so emit exactly one.
            .special("read", schema: Schema.boolean("true marks the message read; false marks it unread."), required: true, emit: .custom { args in
                guard let read = ArgHelpers.bool(args, "read") else { throw MCPToolArgError.missingRequired("read") }
                return [read ? "--read" : "--unread"]
            }),
            .arg("dryRun", "--dry-run", "Report what would change without touching the message."),
            .expectMessageId,
        ]),
        MCPToolSpec("mail_move", .mutating(verifyWith: "mail_list"), "Move a message to another mailbox in the same account: this is how you archive, trash, or file a message (pass the destination mailbox name from mail_mailboxes, e.g. Archive, Trash, Junk). Reversible by moving it back.", properties: [
            .arg("messageId", .positional, "Compound message ID from mail_list output."),
            .arg("to", "--to", "Destination mailbox name, exactly as reported by mail_mailboxes (names differ per account, e.g. '[Gmail]/Trash')."),
            .arg("dryRun", "--dry-run", "Report what would move without touching the message."),
            .expectMessageId,
        ]),
        MCPToolSpec("mail_send", .mutating(verifyWith: "mail_list"), "Send an email. Returns a preview and sends NOTHING on the first call: review the preview, then call again with the same arguments plus the confirmToken it returned (or confirm=true where the policy allows the tool) to deliver.", properties: [
            .arg("to", "--to", "Recipient email addresses.", required: true),
            .arg("subject", "--subject"),
            .arg("body", "--body"),
            .arg("cc", "--cc", "CC recipients."),
            .arg("bcc", "--bcc", "BCC recipients."),
            .arg("from", "--from", "Sending account name (from mail_accounts). Defaults to the primary account."),
            .arg("attach", "--attach", "Absolute paths of files to attach."),
            .confirmSend,
        ]),
        MCPToolSpec("mail_reply", .mutating(verifyWith: "mail_list"), "Reply to a message. Returns a preview and sends NOTHING on the first call: review the preview, then call again with the same arguments plus the confirmToken it returned (or confirm=true where the policy allows the tool) to deliver.", properties: [
            .arg("messageId", .positional, "Compound message ID from mail_list output."),
            .arg("body", "--body"),
            .arg("to", "--to", "Override the reply-to addresses. Defaults to the original sender."),
            .arg("cc", "--cc", "CC recipients."),
            .arg("bcc", "--bcc", "BCC recipients."),
            .arg("from", "--from", "Sending account name (from mail_accounts)."),
            .arg("attach", "--attach", "Absolute paths of files to attach."),
            .confirmSend,
            .expectMessageId,
        ]),
        MCPToolSpec("mail_forward", .mutating(verifyWith: "mail_list"), "Forward a message. Returns a preview and sends NOTHING on the first call: review the preview, then call again with the same arguments plus the confirmToken it returned (or confirm=true where the policy allows the tool) to deliver.", properties: [
            .arg("messageId", .positional, "Compound message ID from mail_list output."),
            .arg("to", "--to", "Recipient email addresses.", required: true),
            .arg("body", "--body", "Optional note prepended before the forwarded content."),
            .arg("cc", "--cc", "CC recipients."),
            .arg("bcc", "--bcc", "BCC recipients."),
            .arg("from", "--from", "Sending account name (from mail_accounts)."),
            .arg("attach", "--attach", "Absolute paths of files to attach."),
            .confirmSend,
            .expectMessageId,
        ]),
        MCPToolSpec("mail_triage", .readOnly, "AI triage of a mailbox: classify and prioritize messages from metadata only (no bodies read). Read-only.", properties: [
            .arg("account", "--account"),
            .arg("mailbox", "--mailbox"),
            .arg("limit", "--limit", "Maximum messages to triage (default: 20).", as: .integer),
            .arg("provider", "--provider"),
            .arg("model", "--model"),
            .arg("noRules", "--no-rules", "Skip the rule-based pre-pass and send every message to the AI."),
            .arg("rulesFile", "--rules-file", "Path to a triage-rules.json (default: ~/.config/pippin/triage-rules.json)."),
        ]),
        MCPToolSpec("mail_apply_rules", .mutating(verifyWith: "mail_list"), "Execute the move/mark actions in the triage rules file against a mailbox. Returns a plan grouped by sender and changes NOTHING unless confirm=true (or, where the policy sets this tool to confirm, the confirmToken a first call returns): review the plan first. Messages newer than minAgeDays are never touched.", properties: [
            .arg("account", "--account"),
            .arg("mailbox", "--mailbox"),
            .arg("scanLimit", "--scan-limit", as: .integer),
            .arg("maxActions", "--max-actions", "Cap on messages actuated per run (default: 200). Oldest first.", as: .integer),
            .arg("minAgeDays", "--min-age-days", as: .integer),
            .arg("skipUnread", "--skip-unread"),
            .arg("rulesFile", "--rules-file", "Path to a triage-rules.json (default: ~/.config/pippin/triage-rules.json)."),
            // This CLI is preview-by-default and takes an opt-in `--live`.
            .arg("confirm", "--live", "Set true to actually move/mark. Omitted or false returns the plan only."),
        ]),
        MCPToolSpec("mail_sanitize", .readOnly, "Scan a message for prompt-injection patterns before acting on its contents. Read-only. Use alongside mail_verify on anything suspicious.", properties: [
            .arg("messageId", .positional, "Compound message ID from mail_list output."),
            .arg("aiAssisted", "--ai-assisted", "Add an AI-assisted scan on top of the rule-based patterns."),
            .arg("provider", "--provider", "AI provider for aiAssisted: ollama, claude, or openai."),
            .arg("model", "--model"),
        ]),
        MCPToolSpec("mail_extract", .readOnly, "Extract structured data (dates, amounts, contacts, action items) from one message using AI. Read-only.", properties: [
            .arg("messageId", .positional, "Compound message ID from mail_list output."),
            .arg("provider", "--provider", "AI provider: ollama, claude, or openai."),
            .arg("model", "--model", "Model name."),
        ]),

        // MARK: Calendar

        MCPToolSpec("calendar_list", .readOnly, "List calendars configured in Apple Calendar.", inProcess: MCPInProcessTools.execute, properties: [
            .arg("type", "--type", "Filter by type: local, calDAV, exchange, subscription, birthday."),
        ]),
        MCPToolSpec("calendar_events", .readOnly, "List calendar events in a date range. Defaults to today.", inProcess: MCPInProcessTools.execute, properties: [
            .arg("from", "--from", "Start date (YYYY-MM-DD or ISO 8601)."),
            .arg("to", "--to", "End date (YYYY-MM-DD or ISO 8601)."),
            .arg("calendar", "--calendar", "Calendar ID to filter by."),
            .arg("calendarName", "--calendar-name", "Calendar name to filter by (case-insensitive)."),
            .arg("range", "--range", "Shorthand range: today, today+N, week, month."),
            .arg("limit", "--limit", "Max events (default: 50).", as: .integer),
        ]),
        MCPToolSpec("calendar_today", .readOnly, "List events scheduled for today.", inProcess: MCPInProcessTools.execute),
        MCPToolSpec("calendar_remaining", .readOnly, "List events from now until end of today.", inProcess: MCPInProcessTools.execute),
        MCPToolSpec("calendar_upcoming", .readOnly, "List events for the next 7 days.", inProcess: MCPInProcessTools.execute),
        MCPToolSpec("calendar_search", .readOnly, "Search calendar events by text across a date range.", inProcess: MCPInProcessTools.execute, properties: [
            .arg("query", "--query", "Search query (matches title, notes, location).", required: true),
            .arg("from", "--from", "Start date (default: 6 months ago)."),
            .arg("to", "--to", "End date (default: 6 months from now)."),
            .arg("calendarName", "--calendar-name", "Filter by calendar name."),
            .arg("limit", "--limit", "Max results (default: 50).", as: .integer),
        ]),
        MCPToolSpec("calendar_create", .mutating(verifyWith: "calendar_upcoming"), "Create a new calendar event.", properties: [
            .arg("title", "--title", "Event title."),
            .arg("start", "--start", "Start date/time (YYYY-MM-DD or ISO 8601)."),
            .arg("end", "--end"),
            .arg("calendar", "--calendar", "Calendar ID to create in."),
            .arg("location", "--location"),
            .arg("notes", "--notes"),
            .arg("url", "--url"),
            .arg("allDay", "--all-day", "Create as all-day event."),
            .arg("alert", "--alert", "Alert before event (e.g. '15m', '1h', '2d')."),
        ]),
        MCPToolSpec("calendar_show", .readOnly, "Show full details for a single event by ID (from calendar_events / calendar_search).", properties: [
            .arg("id", .positional, "Event ID."),
            .arg("occurrence", "--occurrence", "For a recurring event: which occurrence to show, as the occurrenceDate from calendar_events."),
        ]),
        MCPToolSpec("calendar_edit", .mutating(verifyWith: "calendar_upcoming"), "Edit an existing calendar event. Only the fields you pass are changed.", properties: [
            .arg("id", .positional, "Event ID from calendar_events / calendar_search."),
            .arg("title", "--title", "New event title."),
            .arg("start", "--start"),
            .arg("end", "--end"),
            .arg("calendar", "--calendar", "Move to this calendar (EventKit ID from calendar_list, not a name)."),
            .arg("location", "--location"),
            .arg("notes", "--notes"),
            .arg("url", "--url"),
            .arg("alert", "--alert", "New alert offset."),
            .arg("span", "--span", "For a recurring event: 'this' occurrence (default), this and 'future' ones (both need occurrence), or 'all' for the whole series."),
            .arg("occurrence", "--occurrence", "For a recurring event: which occurrence, as the occurrenceDate from calendar_events (every occurrence shares one id). Required to edit or delete one unless span is 'all'."),
            .arg("allDay", "--all-day", "Convert to an all-day event."),
            .arg("noAllDay", "--no-all-day", "Convert away from an all-day event."),
        ]),
        MCPToolSpec("calendar_delete", .mutating(verifyWith: "calendar_upcoming"), "Delete a calendar event. IRREVERSIBLE: the first call returns a confirmToken; call again with it (or confirm=true where the policy allows the tool) to delete.", properties: [
            .arg("id", .positional, "Event ID from calendar_events / calendar_search."),
            .confirmGate("Must be true. Deletion cannot be undone."),
            .arg("span", "--span", "For a recurring event: 'this' occurrence (default), this and 'future' ones (both need occurrence), or 'all' for the whole series."),
            .arg("occurrence", "--occurrence", "For a recurring event: which occurrence, as the occurrenceDate from calendar_events (every occurrence shares one id). Required to edit or delete one unless span is 'all'."),
        ]),
        MCPToolSpec("calendar_smart_create", .mutating(verifyWith: "calendar_upcoming"), "Create an event from a natural-language description using AI (resolves calendar names, unlike calendar_create which needs an EventKit ID). Reports scheduling conflicts unless allowConflicts is set.", properties: [
            .arg("description", .trailing, "Natural-language event description, e.g. 'lunch with Sam next Tuesday at noon'."),
            .arg("calendar", "--calendar", "Target calendar name (resolved for you)."),
            .arg("provider", "--provider", "AI provider: ollama, claude, or openai."),
            .arg("model", "--model", "Model name."),
            .arg("dryRun", "--dry-run", "Show the parsed event without creating it."),
            .arg("allowConflicts", "--allow-conflicts", "Create even if it overlaps an existing event."),
        ]),
        MCPToolSpec("calendar_agenda", .readOnly, "AI-generated briefing of upcoming events. Read-only.", properties: [
            .arg("days", "--days", "Days to cover, 1-7 (default: 1).", as: .integer),
            .arg("provider", "--provider", "AI provider: ollama, claude, or openai."),
            .arg("model", "--model", "Model name."),
        ]),
        MCPToolSpec("calendar_conflicts", .readOnly, "Find overlapping events in a time window. Read-only. Use before scheduling.", properties: [
            .arg("from", "--from", "Window start (default: start of today)."),
            .arg("to", "--to", "Window end (default: end of today)."),
            .arg("range", "--range", "Relative window instead of from/to: today, today+N, week, or month."),
        ]),

        // MARK: Reminders

        MCPToolSpec("reminders_lists", .readOnly, "List all Apple Reminders lists.", inProcess: MCPInProcessTools.execute),
        MCPToolSpec("reminders_list", .readOnly, "List reminders, defaulting to incomplete items.", inProcess: MCPInProcessTools.execute, properties: [
            .arg("list", "--list", "Reminder list ID from reminders_lists."),
            .arg("completed", "--completed", "Include completed reminders."),
            .arg("dueBefore", "--due-before", "Due before date (YYYY-MM-DD or ISO 8601)."),
            .arg("dueAfter", "--due-after", "Due after date (YYYY-MM-DD or ISO 8601)."),
            .arg("createdAfter", "--created-after", "Only reminders created on or after this date (YYYY-MM-DD or ISO 8601)."),
            .arg("modifiedAfter", "--modified-after", "Only reminders modified on or after this date (YYYY-MM-DD or ISO 8601)."),
            .arg("priority", "--priority", "Filter by priority: high, medium, low, none."),
            .arg("limit", "--limit", "Max reminders (default: 50).", as: .integer),
        ]),
        MCPToolSpec("reminders_show", .readOnly, "Show full details for a single reminder by ID.", inProcess: MCPInProcessTools.execute, properties: [
            .arg("id", .positional, "Reminder ID or prefix."),
        ]),
        MCPToolSpec("reminders_search", .readOnly, "Search reminders by title/notes text.", inProcess: MCPInProcessTools.execute, properties: [
            .arg("query", .trailing, "Search query."),
            .arg("list", "--list", "Restrict to a single list ID."),
            .arg("completed", "--completed", "Search completed reminders instead."),
            .arg("limit", "--limit", "Max results (default: 50).", as: .integer),
        ]),
        MCPToolSpec("reminders_create", .mutating(verifyWith: "reminders_list"), "Create a new reminder.", properties: [
            .arg("title", .trailing),
            .arg("list", "--list", "Target list ID (default: default list)."),
            .arg("due", "--due", "Due date/time (YYYY-MM-DD or ISO 8601)."),
            .arg("priority", "--priority", "Priority: high, medium, low, none."),
            .arg("notes", "--notes"),
            .arg("url", "--url"),
        ]),
        MCPToolSpec("reminders_complete", .mutating(verifyWith: "reminders_list"), "Mark a reminder as completed.", properties: [
            .arg("id", .positional, "Reminder ID or prefix."),
        ]),
        MCPToolSpec("reminders_edit", .mutating(verifyWith: "reminders_list"), "Edit an existing reminder. Only the fields you pass are changed.", properties: [
            .arg("id", .positional, "Reminder ID from reminders_list / reminders_search."),
            .arg("title", "--title"),
            .arg("due", "--due", "New due date/time."),
            .arg("priority", "--priority", "New priority: high, medium, low, or none."),
            .arg("notes", "--notes"),
            .arg("url", "--url"),
            .arg("list", "--list", "Move to this list (EventKit ID from reminders_lists, not a name)."),
        ]),
        MCPToolSpec("reminders_delete", .mutating(verifyWith: "reminders_list"), "Delete a reminder. IRREVERSIBLE: the first call returns a confirmToken; call again with it (or confirm=true where the policy allows the tool) to delete. To just tick one off, use reminders_complete instead.", properties: [
            .arg("id", .positional, "Reminder ID from reminders_list / reminders_search."),
            .confirmGate("Must be true. Deletion cannot be undone."),
        ]),
        MCPToolSpec("reminders_smart_create", .mutating(verifyWith: "reminders_list"), "Create a reminder from a natural-language description using AI (resolves list names, unlike reminders_create which needs an EventKit ID).", properties: [
            .arg("description", .trailing, "Natural-language reminder, e.g. 'call the dentist Friday morning'."),
            .arg("list", "--list", "Target list name (resolved for you)."),
            .arg("provider", "--provider", "AI provider: ollama, claude, or openai."),
            .arg("model", "--model", "Model name."),
            .arg("dryRun", "--dry-run", "Show the parsed reminder without creating it."),
        ]),

        // MARK: Contacts

        MCPToolSpec("contacts_search", .readOnly, "Search contacts by name (default), email, or phone.", inProcess: MCPInProcessTools.execute, properties: [
            // --phone carries the query as its value (it rejects a positional
            // query); email and plain name search take the positional.
            .arg("query", .trailing, "Search query (a name, an email, or a phone number).", required: true, emit: .custom { args in
                guard let query = ArgHelpers.string(args, "query") else { throw MCPToolArgError.missingRequired("query") }
                if ArgHelpers.bool(args, "phone") == true { return ["--phone", query] }
                return ArgHelpers.flagIfTrue(args, "email", flagName: "--email") + ["--", query]
            }),
            .arg("fields", "--fields", "Comma-separated fields to include (e.g. id,fullName,emails)."),
            .special("phone", schema: Schema.boolean("Treat the query as a phone number (digits-only match, last-10 fallback).", default: false), emit: .none),
            .arg("email", "--email", "Treat the query as an email address.", emit: .none),
        ]),
        MCPToolSpec("contacts_show", .readOnly, "Show full contact details by identifier.", inProcess: MCPInProcessTools.execute, properties: [
            .arg("identifier", .positional, "Contact identifier."),
        ]),
        MCPToolSpec("contacts_list", .readOnly, "List all contacts with their primary email and phone. Read-only. Prefer contacts_search when you know who you're looking for.", properties: [
            .arg("group", "--group", "Restrict to a contact group name (from contacts_groups)."),
        ]),
        MCPToolSpec("contacts_groups", .readOnly, "List contact groups. Read-only."),
        MCPToolSpec("contacts_create", .mutating(verifyWith: "contacts_list"), "Create a new contact. Every field is optional, but supply at least a name or an email so the card is identifiable.", properties: [
            .arg("first", "--first", "First name."),
            .arg("last", "--last", "Last name."),
            .arg("email", "--email"),
            .arg("phone", "--phone"),
            .arg("organization", "--organization", "Organization."),
            .arg("jobTitle", "--job-title"),
        ]),
        MCPToolSpec("contacts_edit", .mutating(verifyWith: "contacts_list"), "Edit an existing contact. Only the fields you pass are changed.", properties: [
            .arg("identifier", .positional, "Contact identifier from contacts_search / contacts_show."),
            .arg("first", "--first", "New first name."),
            .arg("last", "--last", "New last name."),
            .arg("email", "--email", "New email address."),
            .arg("phone", "--phone", "New phone number."),
            .arg("organization", "--organization", "New organization."),
            .arg("jobTitle", "--job-title"),
        ]),
        MCPToolSpec("contacts_delete", .mutating(verifyWith: "contacts_list"), "Delete a contact. IRREVERSIBLE: the first call returns a confirmToken; call again with it (or confirm=true where the policy allows the tool) to delete.", properties: [
            .arg("identifier", .positional, "Contact identifier from contacts_search / contacts_show."),
            .confirmGate("Must be true. Deletion cannot be undone."),
        ]),

        // MARK: Notes

        MCPToolSpec("notes_list", .readOnly, "List Apple Notes, defaulting to 50 most recently modified.", inProcess: MCPInProcessTools.execute, properties: [
            .arg("folder", "--folder"),
            .arg("limit", "--limit", "Max notes (default: 50).", as: .integer),
        ]),
        MCPToolSpec("notes_search", .readOnly, "Search notes by title or body content.", inProcess: MCPInProcessTools.execute, properties: [
            .arg("query", .trailing),
            .arg("folder", "--folder"),
            .arg("limit", "--limit", "Max results (default: 50).", as: .integer),
        ]),
        MCPToolSpec("notes_show", .readOnly, "Show full details of a note by ID (returns plainText, not HTML).", inProcess: MCPInProcessTools.execute, properties: [
            .arg("id", .positional, "Note ID from notes_list."),
        ]),
        MCPToolSpec("notes_folders", .readOnly, "List all Apple Notes folders.", inProcess: MCPInProcessTools.execute),
        MCPToolSpec("notes_create", .mutating(verifyWith: "notes_list"), "Create a new Apple Note.", properties: [
            .arg("title", .trailing),
            .arg("body", "--body", "Note body. Plain text; newlines become formatted HTML unless html=true."),
            .arg("folder", "--folder"),
            .arg("html", "--html", "Treat body as raw HTML (skip plain-text-to-HTML conversion)."),
        ]),
        MCPToolSpec("notes_edit", .mutating(verifyWith: "notes_list"), "Edit an existing note's title or body. body REPLACES the whole note body unless append=true; pass dryRun=true first to see the current and resulting body length without writing.", properties: [
            .arg("id", .trailing, "Note ID from notes_list."),
            .arg("title", "--title", "New title."),
            .arg("body", "--body", "New body. Plain text; newlines become formatted HTML unless html=true."),
            .arg("append", "--append", "Append body instead of replacing."),
            .arg("html", "--html", "Treat body as raw HTML (skip plain-text-to-HTML conversion)."),
            .arg("dryRun", "--dry-run", "Report title, previousBodyLength and newBodyLength without writing."),
        ]),
        MCPToolSpec("notes_delete", .mutating(verifyWith: "notes_list"), "Move a note to Recently Deleted. The first call returns a confirmToken; call again with it (or confirm=true where the policy allows the tool) to delete. Recoverable from Recently Deleted for 30 days.", properties: [
            .arg("id", .positional, "Note ID from notes_list / notes_search."),
            .confirmGate("Must be true."),
        ]),

        // MARK: Messages (read-only)

        MCPToolSpec("messages_list", .readOnly, "List recent Apple Messages conversations (most recent first). Read-only.", inProcess: MCPInProcessTools.execute, properties: [
            .arg("sinceHours", "--since-hours", "Only conversations with a message in the last N hours (default: 48).", as: .integer, default: .int(48)),
            .arg("limit", "--limit", as: .integer),
        ]),
        MCPToolSpec("messages_search", .readOnly, "Search Messages bodies by substring. Read-only.", inProcess: MCPInProcessTools.execute, properties: [
            .arg("query", .trailing, "Search substring."),
            .arg("sinceHours", "--since-hours", "Restrict to last N hours.", as: .integer),
            .arg("limit", "--limit", "Maximum messages (default: 50).", as: .integer),
        ]),
        MCPToolSpec("messages_show", .readOnly, "Show messages in a conversation thread by GUID. Read-only.", inProcess: MCPInProcessTools.execute, properties: [
            .arg("conversationId", .positional, "Conversation GUID from messages_list."),
            .arg("limit", "--limit", as: .integer),
        ]),
        MCPToolSpec("messages_send", .mutating(verifyWith: "messages_list"), "Draft a message (DRAFT ONLY: MCP clients cannot trigger autonomous delivery).", trail: ["--draft"], properties: [
            .arg("to", "--to", "Recipient handle or chat GUID."),
            .arg("body", "--body"),
        ]),
        MCPToolSpec("messages_exclude_list", .readOnly, "Show the thread exclude list: conversations hidden from every messages_* read. Read-only."),
        MCPToolSpec("messages_exclude_add", .mutating(verifyWith: "messages_exclude_list"), "Hide a conversation from every messages_* read by adding its thread GUID to the exclude list.", properties: [
            .arg("thread", .positional, "Thread GUID from messages_list / messages_show."),
        ]),
        MCPToolSpec("messages_exclude_remove", .mutating(verifyWith: "messages_exclude_list"), "Un-hide a conversation by removing its thread GUID from the exclude list.", properties: [
            .arg("thread", .positional, "Thread GUID from messages_exclude_list."),
        ]),

        // MARK: Memos

        MCPToolSpec("memos_list", .readOnly, "List Voice Memos recordings (most recent first).", properties: [
            .arg("since", "--since", "Only recordings on or after YYYY-MM-DD."),
            .arg("limit", "--limit", "Maximum number of results (default: 20).", as: .integer),
        ]),
        MCPToolSpec("memos_info", .readOnly, "Show full metadata for a single Voice Memos recording by ID.", properties: [
            .arg("id", .positional, "Memo UUID from memos_list output."),
        ]),
        MCPToolSpec("memos_export", .mutating(verifyWith: nil), "Copy Voice Memos recording(s) to a directory, optionally with transcript sidecars.", properties: [
            .idOrAll("Memo UUID (omit with all=true)."),
            .arg("all", "--all"),
            .arg("output", "--output"),
            .arg("transcribe", "--transcribe", "Transcribe audio and write sidecar."),
            .arg("sidecarFormat", "--sidecar-format", "Sidecar format: txt (default), srt, markdown, rtf."),
            .arg("forceTranscribe", "--force-transcribe", "Bypass transcript cache."),
            .arg("jobs", "--jobs", as: .integer),
        ]),
        MCPToolSpec("memos_transcribe", .mutating(verifyWith: nil), "Transcribe Voice Memos audio to text. Requires mlx-audio (see `pippin doctor`).", properties: [
            .idOrAll("Memo UUID (omit with all=true)."),
            .arg("all", "--all"),
            .arg("output", "--output", "Directory to write .txt files (default: inline in JSON)."),
            .arg("force", "--force"),
            .arg("jobs", "--jobs", as: .integer),
        ]),
        MCPToolSpec("memos_capture_to_reminders", .mutating(verifyWith: "reminders_list"), "Transcribe a Voice Memos recording, extract action items via the configured LLM, and create Reminders. Commits by default in agent mode; pass dryRun=true to preview.", lead: ["--to-reminders"], properties: [
            .arg("memo", "--memo"),
            .arg("list", "--list"),
            .arg("dryRun", "--dry-run"),
            .arg("provider", "--provider", "AI provider: ollama, claude, or openai (default: ai.provider, else ollama)."),
            .arg("model", "--model"),
        ]),
        MCPToolSpec("memos_summarize", .mutating(verifyWith: nil), "Summarize a Voice Memos recording using the configured AI provider.", properties: [
            .idOrAll("Memo UUID (omit with all=true)."),
            .arg("all", "--all", "Summarize every recording."),
            .arg("template", "--template", "Template name (e.g. meeting-notes, summary, action-items)."),
            .arg("prompt", "--prompt", "Free-form prompt (overrides template)."),
            .arg("provider", "--provider", "AI provider: ollama, claude, or openai (default: ai.provider, else ollama)."),
            .arg("model", "--model"),
            .arg("since", "--since", "With all=true, only memos on or after YYYY-MM-DD."),
            .arg("output", "--output", "Write output to a directory instead of inline JSON."),
            .arg("jobs", "--jobs", as: .integer),
        ]),
        MCPToolSpec("memos_delete", .mutating(verifyWith: "memos_list"), "Delete a voice memo: its audio file moves to the Trash and its database row is removed. Fails unless confirm=true, and refuses while the Voice Memos app is running. Pass dryRun=true (with confirm=false) to see which recording an id names without changing anything.", properties: [
            .arg("id", .positional, "Memo ID from memos_list, or an unambiguous prefix of it."),
            // dryRun skips the gate: it changes nothing.
            .confirmGate("Must be true to delete. The audio is recoverable from the Trash; the recording's entry is not.") { args in
                try ArgHelpers.bool(args, "dryRun") == true ? ["--dry-run"] : ArgHelpers.forceFromConfirm(args)
            },
            .arg("dryRun", "--dry-run", "Report the recording that would be deleted and change nothing.", emit: .none),
        ]),

        // MARK: Digest, actions, system

        MCPToolSpec("digest", .readOnly, "Aggregated daily digest: unread mail, today's calendar events, due and overdue reminders, and recently modified notes.", properties: [
            .arg("mailLimit", "--mail-limit", as: .integer),
            .arg("notesLimit", "--notes-limit", "Max recent notes (default: 5).", as: .integer),
            .arg("calendarDays", "--calendar-days", "Days of upcoming events beyond today (default: 7).", as: .integer),
        ]),
        MCPToolSpec("actions_extract", .mutating(verifyWith: "reminders_list"), "Scan recent Sent mail and recently-modified Notes for commitments you made (\"I'll send you…\", \"I'll follow up…\") and emit draft reminders with a confidence score. Read-only by default; set create=true to also create the reminders in a list. Slow (per-batch AI calls): under MCP the AI pass is bounded to ~50s and returns partial results with a timedOut warning: lower limit/days or run via job_run for an exhaustive scan.", properties: [
            .arg("days", "--days", "Days back to scan (1-90, default 7).", as: .integer),
            .arg("mail", "--mail"),
            .arg("notes", "--notes"),
            .arg("account", "--account"),
            .arg("limit", "--limit", "Max items to scan per source (default: 50).", as: .integer),
            .arg("min_confidence", "--min-confidence", "Minimum confidence (0.0-1.0) to include an action (default: 0.5).", as: .number),
            .arg("provider", "--provider"),
            .arg("model", "--model"),
            .arg("api_key", "--api-key", "API key for the Claude provider."),
            .arg("list", "--list", "Reminder list name to create into (used when create=true)."),
            .arg("create", "--create", "Create reminders from the extracted actions (side-effecting)."),
        ]),
        MCPToolSpec("status", .readOnly, "System dashboard: accounts, events, reminders, permissions."),
        MCPToolSpec("doctor", .readOnly, "Check pippin's system requirements and permissions."),

        // MARK: Jobs (background pippin subprocesses)

        MCPToolSpec("job_run", .mutating(verifyWith: "job_list"), "Fork a detached pippin sub-command as a background job. Returns {id, pid, status: \"running\"} immediately; poll via job_show or block via job_wait. Use this for slow work (memos summarize, actions extract) so the caller isn't blocked. The argv must be a command that has an MCP tool of its own; batch and job run cannot be nested.", properties: [
            .arg("argv", .positional, "Argv for the pippin child process (e.g. [\"memos\", \"summarize\", \"--all\"]).", required: true, emit: .custom { args in
                guard let argvValue = args?["argv"], case let .array(items) = argvValue else {
                    throw MCPToolArgError.missingRequired("argv")
                }
                let argv: [String] = try items.map { item in
                    guard let s = item.stringValue else {
                        throw MCPToolArgError.wrongType(field: "argv[]", expected: "string")
                    }
                    return s
                }
                try MCPCommandPolicy.check(argv)
                return ["--"] + argv
            }),
        ]),
        MCPToolSpec("job_show", .readOnly, "Show a job's status + stdout/stderr tails. Use prefix match (e.g. first 6 chars) to save tokens. status error with error_code runner_lost means the job's process died without recording a result.", properties: [
            .arg("id", .positional),
            .arg("tail", "--tail", "Bytes of stdout/stderr to include (default: 4096).", as: .integer),
        ]),
        MCPToolSpec("job_list", .readOnly, "List recent background jobs. Filter by status to find only running/failed jobs.", properties: [
            .arg("limit", "--limit", as: .integer),
            .arg("status", "--status", "Filter: running, done, error, killed."),
        ]),
        MCPToolSpec("job_wait", .readOnly, "Block until a job reaches a terminal state. Prefer this over polling when you know the job is quick. Returns AgentError.wait_timed_out if deadline hits.", properties: [
            .arg("id", .positional),
            // Must end before the 60s child cap or the kill loses the job status.
            .arg("timeout", "--timeout", "Maximum seconds to wait (default and maximum: 50, under the tool-call cap).", as: .integer, default: .int(50), emit: .custom { args in
                [ArgHelpers.option("--timeout", String(min(ArgHelpers.int(args, "timeout") ?? 50, 50)))]
            }),
        ]),

        // MARK: Batch (parallel sub-command dispatch)

        MCPToolSpec("batch", .mutating(verifyWith: nil), "Run multiple pippin commands concurrently in one call. Use this to fan out (e.g. fetch mail + calendar + reminders simultaneously) instead of sequential tool calls. Each entry's response is its own envelope. An entry must be a command that has an MCP tool of its own (same flags as the CLI); batch and job run cannot be nested, and anything else returns a per-entry error.", properties: [
            // An array of objects, passed as one JSON string to --entries.
            .special("entries", schema: .object([
                "type": .string("array"),
                "description": .string("Array of {cmd, args} entries: each runs as `pippin <cmd> [args...] --format agent`."),
                "items": Schema.object(
                    properties: [
                        "cmd": Schema.string("Top-level pippin subcommand (e.g. mail, calendar, reminders)."),
                        "args": .object([
                            "type": .string("array"),
                            "description": .string("Argv tail passed to the sub-command (e.g. [\"list\", \"--account\", \"icloud\"])."),
                            "items": .object(["type": .string("string")]),
                        ]),
                    ],
                    required: ["cmd"]
                ),
            ]), required: true, leading: true, emit: .custom { args in
                guard let entriesValue = args?["entries"] else {
                    throw MCPToolArgError.missingRequired("entries")
                }
                let data = try JSONEncoder().encode(entriesValue)
                guard let json = String(data: data, encoding: .utf8) else {
                    throw MCPToolArgError.wrongType(field: "entries", expected: "JSON-encodable array")
                }
                return ["--entries", json]
            }),
            .arg("concurrency", "--concurrency", as: .integer),
        ]),

        // MARK: Safety (policy, action log, undo)

        MCPToolSpec("policy_show", .readOnly, "Show the safety policy this server applies: for every tool its rule (allow, deny, confirm) and rate limit, and whether they come from the policy file or the built-in default. Read-only; the policy file can only be edited by the user."),
        MCPToolSpec("action_log", .readOnly, "List the mutating tool calls this server ran or refused, newest first: id, time, tool, arguments (bodies and secrets shown only as length and hash), policy rule, outcome, and whether the action can be undone. Pass an entry's id to undo.", properties: [
            .arg("pageSize", "--page-size", "Rows per page when paginating.", as: .integer),
            .arg("page", "--page", "1-based page number. Ignored when cursor is set.", as: .integer),
            .arg("limit", "--limit", as: .integer),
            .arg("since", "--since"),
            .arg("tool", "--tool", "Only actions of this tool, e.g. mail_send."),
            .arg("cursor", "--cursor", "Opaque next_cursor from a previous response."),
        ]),
        MCPToolSpec("undo", .mutating(verifyWith: "action_log"), "Reverse one logged action by its id from action_log, where its entry says undo.supported=true (mail move and mark, reminders complete and edit, calendar, notes and contacts edit). Refuses with undo_target_changed if the target was changed since. Sends and deletes cannot be undone.", properties: [
            .arg("id", .positional, "Action id from action_log."),
        ]),
    ]

    /// Look up a tool by name. Returns nil if unknown.
    static func tool(named name: String) -> MCPTool? {
        tools.first { $0.name == name }
    }
}
