# Gotchas

Hard-won patterns and traps. Keep CLAUDE.md focused on architecture and pointers; load these on demand when working in the relevant area.

| File | Load when |
|------|-----------|
| [jxa.md](jxa.md) | Editing any `*Bridge/` directory — Mail, Notes, Reminders, Calendar, Audio, Contacts, Browser. JXA + EventKit + IMAP traps. |
| [swift.md](swift.md) | Editing `pippin/Commands/`, adding subcommands, touching Swift 6 concurrency, or changing `OutputOptions`/agent JSON. |
| [build.md](build.md) | CI failing, `swiftformat`/`swiftlint` misbehaving, `swift test` won't resolve, juggling worktrees. |
| [mcp.md](mcp.md) | Editing `pippin/MCP/` or `McpServerCommand.swift`. For usage/wiring, see [../mcp-server.md](../mcp-server.md). |

These files are kept short on purpose — each entry is a single trap with the fix. When you discover a new gotcha, append to the appropriate file rather than inlining in CLAUDE.md.
