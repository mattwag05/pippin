# Roadmap

Planned features and improvements for pippin. Tracked in [beads](https://github.com/plandex-ai/beads) — run `bd ready` to see available work.

---

## Bugs (from Pi Agent Testing)

### Contacts Search Crash (`pippin-crl`) — P1
`pippin contacts search` crashes while `contacts list` works fine. Likely CNContactStore query construction issue.

### Browser Snapshot Undefined Page (`pippin-1gb`) — P1
`pippin browser snapshot` fails with "Cannot read properties of undefined (reading 'snapshot')". Page object not initialized in persistent context. Blocks click/fill (which depend on @ref IDs from snapshot).

### Browser NODE_PATH Resolution (`pippin-izt`) — P1
Browser commands fail unless `NODE_PATH=/opt/homebrew/lib/node_modules` is set. Node can't find globally-installed Playwright at runtime even though `pippin doctor` reports it as found.

### Mail Search Null allMsgs (`pippin-3sk`) — P2
`pippin mail search` crashes with TypeError when JXA `allMsgs` is null (mailbox not accessible or not loaded). Needs null guard in generated search script.

### Doctor Doesn't Find pipx Installs (`pippin-6mj`) — P2
`pippin doctor` checks mlx-audio via system Python import but misses pipx installations. Should also check `pipx list` or common pipx venv paths.

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
