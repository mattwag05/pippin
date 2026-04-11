# Roadmap

Planned features and improvements for pippin. Tracked in [beads](https://github.com/plandex-ai/beads) — run `bd ready` to see available work.

---

## Next Up

### MCP Server Mode (`pippin-6dp`)
Expose pippin as an MCP (Model Context Protocol) server over stdin/stdout JSON-RPC. Each command group becomes a tool — `mail_list`, `calendar_today`, `reminders_create`, etc. Any MCP-compatible client (Claude Desktop, Cursor, etc.) can use pippin natively without shelling out.

### Unified Daily Digest (`pippin-syb`)
Single `pippin digest` command that combines mail summary, calendar agenda, due reminders, and recent notes into one structured briefing. Replaces calling 4 separate commands in the morning briefing task. `--format agent` for token-efficient output.

---

## Agent & Automation

### Mail Watch Mode (`pippin-lhh`)
`pippin mail watch` — poll for new messages, emit events as newline-delimited JSON. Real-time mail monitoring for agent workflows. Options: `--account`, `--interval`, `--mailbox`.

### Mail Triage Rules Engine (`pippin-ace`)
Persistent triage rules in `~/.config/pippin/triage-rules.json` — auto-label, auto-archive, priority overrides based on sender/subject/keywords. Applied before (or instead of) the AI pass to reduce token usage for predictable patterns.

---

## AI Features

### Reminders Smart Create (`pippin-mfe`)
`pippin reminders smart-create "remind me to call the dentist next Tuesday at 9am priority high"` — AI parses due date, priority, and list assignment from natural language. Mirrors `calendar smart-create`.

### Calendar Conflict Detection (`pippin-arr`)
`pippin calendar conflicts --from --to` — find overlapping events. Integrated into `smart-create`: warn or abort if proposed event conflicts. Structured conflict details in agent mode.

---

## Shell & UX

### REPL Tab Completion (`pippin-ypg`)
Tab completion for command names, subcommands, flags, and contextual values (account names, reminder lists). Uses libedit/readline integration.

---

## Data Access

### Contacts Write Support (`pippin-83z`)
Add `create`, `edit`, `delete` to the contacts bridge (currently read-only). Uses `CNMutableContact` + `CNSaveRequest`.

---

## Completed (v0.16.0)

- ~~SKILL.md agent discovery manifest~~ (`pippin-7rd`)
- ~~`pippin status` introspection command~~ (`pippin-4eg`)
- ~~`runConcurrently` refactor~~ (`pippin-jgq`)
- ~~Universal `--json` on all commands~~ (`pippin-6k6`)
- ~~Session state persistence~~ (`pippin-mqt`)
