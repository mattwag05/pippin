# CLI reference

Every command `pippin` exposes, with its own help text. Generated from the command definitions by `CLIReferenceTests`; do not edit by hand. Regenerate with `PIPPIN_UPDATE_SCHEMAS=1 make test`. Run `pippin <command> --help` for the options of one command, and see [mcp-server.md](mcp-server.md) for the MCP tools.

| Command | What it does |
| --- | --- |
| `pippin mail accounts` | List configured Mail accounts. |
| `pippin mail mailboxes` | List mailboxes per account. |
| `pippin mail search` | Search messages by subject or sender. Use --from for sender-only searches; use --body only for slower body-content scans. |
| `pippin mail list` | List messages. Defaults to INBOX, all messages, limit 20. |
| `pippin mail activity` | Combined recent mail activity across multiple mailboxes (e.g. INBOX + Sent). Use this for scan workflows instead of N calls to mail list. |
| `pippin mail show` | Show one or more messages by compound id, or one by subject search. |
| `pippin mail verify` | Inspect a message's headers against the sender's historical baseline (phishing check). |
| `pippin mail mark` | Mark a message as read or unread. |
| `pippin mail move` | Move a message to another mailbox. |
| `pippin mail send` | Send an email message. |
| `pippin mail attachments` | List (and optionally save) attachments from a message. |
| `pippin mail reply` | Reply to a message. |
| `pippin mail forward` | Forward a message. |
| `pippin mail index` | Build or update the semantic search index for mail messages. |
| `pippin mail sanitize` | Scan a message for prompt injection patterns. |
| `pippin mail extract` | Extract structured data (dates, amounts, contacts, action items) from a message. |
| `pippin mail triage` | AI-powered triage: classify and prioritize messages using metadata only. |
| `pippin mail apply-rules` | Apply triage rules' move/mark actions to a mailbox. Previews only unless --live. |
| `pippin mail watch` | Poll for new mail and emit events as newline-delimited JSON. |
| `pippin mail cache stats` | Show cached message count and age range. |
| `pippin mail cache clear` | Delete all cached message bodies (or only those older than --older-than-days). |
| `pippin mail cache warm` | Pre-fetch recent message bodies into the cache so later reads are instant. |
| `pippin mail cache fill` | Fill or refresh Pippin's mail metadata index, which needs no Full Disk Access. |
| `pippin memos list` | List voice memo recordings. |
| `pippin memos info` | Show full metadata for a single recording. |
| `pippin memos export` | Copy recording(s) to a directory. |
| `pippin memos transcribe` | Transcribe voice memo audio to text. |
| `pippin memos delete` | Delete a voice memo: its audio file moves to the Trash and its DB row is removed. Quit Voice Memos first. |
| `pippin memos templates list` | List all available templates. |
| `pippin memos templates show` | Print the system prompt for a template. |
| `pippin memos templates add` | Copy a .md template file into ~/.config/pippin/templates/. |
| `pippin memos summarize` | Summarize a voice memo using AI. |
| `pippin memos capture` | Transcribe a voice memo, extract action items, create Reminders. |
| `pippin calendar list` | List calendars. |
| `pippin calendar events` | List calendar events. Defaults to today. |
| `pippin calendar show` | Show full details for a single event by ID. |
| `pippin calendar create` | Create a new calendar event. |
| `pippin calendar edit` | Edit an existing calendar event. |
| `pippin calendar delete` | Delete a calendar event. |
| `pippin calendar smart-create` | Create an event from a natural language description using AI. |
| `pippin calendar conflicts` | Find overlapping calendar events in a time window. |
| `pippin calendar agenda` | AI-generated briefing of upcoming events. |
| `pippin calendar search` | Search events by text across a date range. |
| `pippin calendar today` | List events for today. |
| `pippin calendar remaining` | List events from now until end of today. |
| `pippin calendar upcoming` | List events for the next 7 days. |
| `pippin contacts list` | List all contacts (name + primary email/phone). |
| `pippin contacts search` | Search contacts by name, email, or phone. |
| `pippin contacts show` | Show full contact details by identifier. |
| `pippin contacts groups` | List contact groups. |
| `pippin contacts create` | Create a new contact. |
| `pippin contacts edit` | Edit an existing contact by identifier. |
| `pippin contacts delete` | Delete a contact by identifier. |
| `pippin reminders lists` | List all reminder lists. |
| `pippin reminders list` | List reminders. Defaults to incomplete reminders. |
| `pippin reminders show` | Show full details for a single reminder by ID. |
| `pippin reminders create` | Create a new reminder. |
| `pippin reminders edit` | Edit an existing reminder. |
| `pippin reminders complete` | Mark a reminder as completed. |
| `pippin reminders delete` | Delete a reminder. |
| `pippin reminders search` | Search reminders by text. |
| `pippin reminders smart-create` | Create a reminder from a natural language description using AI. |
| `pippin notes list` | List notes. Defaults to 50 most recently modified. |
| `pippin notes show` | Show full details of a note by ID. |
| `pippin notes search` | Search notes by title or body content. |
| `pippin notes folders` | List all Notes folders. |
| `pippin notes create` | Create a new note. |
| `pippin notes edit` | Edit a note's title or body. |
| `pippin notes delete` | Move a note to Recently Deleted. |
| `pippin messages list` | List recent conversations (most recent first). |
| `pippin messages search` | Search message bodies by substring. |
| `pippin messages show` | Show messages in a conversation by GUID. |
| `pippin messages send` | Send a message. Defaults to --draft; autonomous delivery requires triple gate. |
| `pippin messages exclude list` | Show the current exclude list. |
| `pippin messages exclude add` | Add a thread GUID to the exclude list. |
| `pippin messages exclude remove` | Remove a thread GUID from the exclude list. |
| `pippin actions extract` | Scan recent Sent mail and recently-modified Notes for commitments you made and emit draft reminders. |
| `pippin digest` | Aggregated daily digest: unread mail, today's calendar, due reminders, and recent notes. |
| `pippin doctor` | Check system requirements and permissions. |
| `pippin status` | Show a system dashboard: accounts, events, reminders, permissions. |
| `pippin init` | Guided first-run setup for permissions and dependencies. |
| `pippin permissions` | Grant (interactively) and report macOS permissions for each app integration. |
| `pippin completions` | Generate shell completion scripts. |
| `pippin agent-info` | Describe pippin's agent contract: version, formats, exit codes, tool count. |
| `pippin shell` | Start an interactive REPL session. |
| `pippin mcp-server` | Run pippin as an MCP server over stdio. |
| `pippin batch` | Execute multiple pippin commands concurrently from a JSON array. |
| `pippin job run` | Fork a detached pippin sub-command; returns a job_id immediately. |
| `pippin job schedule` | Run a pippin command on a recurring schedule (a LaunchAgent that starts `job run`). |
| `pippin job schedules` | List recurring schedules with the status of their last run. |
| `pippin job unschedule` | Remove a recurring schedule (unloads and deletes its LaunchAgent). |
| `pippin job show` | Show a job's status + stdout/stderr tails. |
| `pippin job list` | List recent jobs (default: 20 most recent). |
| `pippin job wait` | Block until a job reaches a terminal state, then print its status. |
| `pippin job logs` | Print a job's stdout/stderr; --stream to tail until terminal. |
| `pippin job gc` | Prune terminal jobs older than --older-than (default: 7d). |
| `pippin do` | Plan and execute pippin tool calls for a natural-language intent. |
| `pippin policy show` | Show the effective rule (allow, deny, confirm) and rate limit for every MCP tool. Read-only. |
| `pippin log` | List actions the MCP server ran or refused, newest first. |
| `pippin undo` | Reverse a logged action by its id (from `pippin log`), where it can be reversed. |
| `pippin templates list` | List all available templates. |
| `pippin templates show` | Print the system prompt for a template. |
| `pippin templates add` | Copy a .md template file into ~/.config/pippin/templates/. |
