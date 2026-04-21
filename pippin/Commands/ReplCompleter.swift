import Foundation

/// Provides command completion for the REPL.
enum ReplCompleter {
    /// All top-level commands available in the REPL.
    static let commands = [
        "mail", "memos", "calendar", "audio", "contacts", "browser",
        "reminders", "notes", "doctor", "status", "use", "context",
        "history", "help", "version", "quit", "exit",
    ]

    /// Subcommands for each top-level command.
    /// NOTE: Keep this in sync with actual command implementations in Commands/*.swift.
    /// This is also used by ShellCommand.run() for command dispatch.
    static let subcommands: [String: [String]] = [
        "mail": ["accounts", "list", "search", "send", "flag", "unflag", "delete", "watch", "triage"],
        "memos": ["list", "search", "summarize", "templates", "export"],
        "calendar": ["list", "agenda", "today", "conflicts"],
        "audio": ["say", "listen", "transcribe"],
        "contacts": ["search", "show"],
        "browser": ["open", "click", "type"],
        "reminders": ["list", "create", "complete", "delete"],
        "notes": ["list", "search", "show"],
        "doctor": [],
        "status": [],
    ]

    /// Flags for each command.subcommand, keyed as "command.subcommand".
    /// NOTE: Update this when adding new subcommands or flags to the CLI.
    static let flags: [String: [String]] = [
        "mail.list": ["--account", "--mailbox", "--limit", "--format"],
        "mail.search": ["--account", "--body", "--limit", "--format"],
        "mail.send": ["--account", "--to", "--subject", "--body"],
        "mail.triage": ["--account", "--mailbox", "--limit", "--format", "--provider", "--model", "--api-key", "--no-rules", "--rules-file"],
        "memos.list": ["--limit", "--format"],
        "memos.summarize": ["--provider", "--model", "--format"],
        "calendar.list": ["--format"],
        "calendar.agenda": ["--days", "--format"],
        "reminders.list": ["--list", "--completed", "--format"],
        "reminders.create": ["--title", "--list", "--due", "--notes"],
        "contacts.search": ["--query", "--format"],
    ]

    /// Get completion suggestions for the current input.
    /// - Parameter input: The current input line.
    /// - Returns: Array of completion suggestions.
    static func completions(for input: String) -> [String] {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return commands }

        let parts = shellSplit(trimmed)
        guard !parts.isEmpty else { return [] }

        // Single word — suggest matching commands
        if parts.count == 1 {
            return commands.filter { $0.hasPrefix(parts[0].lowercased()) }
        }

        let command = parts[0].lowercased()

        // After command — suggest subcommands or flags
        if parts.count == 2 {
            let partial = parts[1].lowercased()
            if partial.hasPrefix("-") {
                // Suggest command-level flags (before a subcommand is chosen)
                // Look for common flags keyed as "command._" or default to empty
                let key = "\(command)._"
                if let cmdFlags = flags[key] {
                    return cmdFlags.filter { $0.hasPrefix(partial) }
                }
                return []
            } else {
                // Suggest subcommands
                if let subs = subcommands[command] {
                    return subs.filter { $0.hasPrefix(partial) }
                }
                return []
            }
        }

        // Three or more words — suggest flags or account/list names based on context
        let subcommand = parts[1].lowercased()
        let key = "\(command).\(subcommand)"
        let partial = parts.last?.lowercased() ?? ""

        if partial.hasPrefix("-") {
            if let cmdFlags = flags[key] {
                return cmdFlags.filter { $0.hasPrefix(partial) }
            }
        }

        return []
    }
}
