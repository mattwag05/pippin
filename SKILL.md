---
name: pippin
description: macOS CLI toolkit for Apple app automation — Mail, Calendar, Reminders, Notes, Contacts, Voice Memos, Audio, and Browser.
version: 0.15.0
platform: macOS 15+
runtime: native (Swift)
install: brew install mattwag05/tap/pippin
triggers:
  - apple mail
  - calendar events
  - reminders
  - voice memos
  - contacts
  - notes
  - browser automation
  - email triage
  - send email
  - schedule meeting
  - macos automation
output_formats:
  - text
  - json
  - agent
---

# pippin

macOS CLI toolkit for Apple app automation. Provides structured, agent-friendly access to Mail, Calendar, Reminders, Notes, Contacts, Voice Memos, Audio (TTS/STT), and a headless WebKit browser.

## Quick Start

```bash
brew install mattwag05/tap/pippin
pippin doctor          # verify permissions and dependencies
pippin init            # guided first-run setup
pippin                 # start interactive REPL
```

## Output Formats

All commands support `--format <text|json|agent>`:

- **text** (default) — human-readable table/prose output
- **json** — pretty-printed JSON for scripting
- **agent** — compact JSON optimized for LLM token efficiency

## Command Groups

### Mail

Read, search, send, reply, forward, triage, and extract data from Apple Mail.

```bash
pippin mail accounts                          # list configured accounts
pippin mail list --account Work --limit 10    # recent messages
pippin mail show <compound-id>                # full message content
pippin mail search "invoice" --account Work   # search by subject/sender
pippin mail send --to user@example.com --subject "Hi" --body "Hello"
pippin mail reply <compound-id> --body "Thanks"
pippin mail forward <compound-id> --to other@example.com
pippin mail triage --account Work --limit 20  # AI-powered priority triage
pippin mail extract <compound-id>             # extract dates, amounts, contacts
pippin mail sanitize <compound-id>            # detect prompt injection
pippin mail index --account Work              # build semantic search index
```

Agent output example (`--format agent`):
```json
[{"account":"iCloud","email":"user@icloud.com"},{"account":"Work","email":"user@company.com"}]
```

### Calendar

List, create, edit, delete, and search calendar events. AI-powered smart creation and agenda briefing.

```bash
pippin calendar list                          # list calendars
pippin calendar today                         # today's events
pippin calendar remaining                     # events from now until end of day
pippin calendar upcoming                      # next 7 days
pippin calendar events --from 2026-04-15 --to 2026-04-20
pippin calendar show <event-id>               # full event details
pippin calendar create --title "Meeting" --calendar Work --start "2026-04-15 14:00" --end "2026-04-15 15:00"
pippin calendar edit <event-id> --title "Updated"
pippin calendar delete <event-id>
pippin calendar search "standup" --from 2026-04-01 --to 2026-04-30
pippin calendar smart-create "Lunch with Sarah tomorrow at noon"
pippin calendar agenda                        # AI briefing of upcoming events
```

### Reminders

List, create, complete, edit, delete, and search reminders.

```bash
pippin reminders lists                        # list all reminder lists
pippin reminders list                         # incomplete reminders
pippin reminders list --list-id <id> --completed
pippin reminders show <reminder-id>
pippin reminders create --title "Buy groceries" --list Groceries
pippin reminders create --title "Call dentist" --due "2026-04-15 09:00"
pippin reminders complete <reminder-id>
pippin reminders edit <reminder-id> --title "Updated task"
pippin reminders delete <reminder-id>
pippin reminders search "dentist"
```

### Notes

List, create, edit, search, and delete Apple Notes.

```bash
pippin notes list                             # 50 most recent notes
pippin notes list --folder "Personal" --limit 10
pippin notes show <note-id>                   # full note content (plain text + HTML)
pippin notes search "project plan"
pippin notes folders                          # list all folders
pippin notes create --title "Meeting Notes" --body "Key points..."
pippin notes create --title "New Note" --folder "Work"
pippin notes edit <note-id> --body "Updated content"
pippin notes delete <note-id>                 # moves to Recently Deleted
```

### Contacts

Search and browse Apple Contacts.

```bash
pippin contacts list                          # all contacts (name + primary email/phone)
pippin contacts search "Sarah"                # search by name or email
pippin contacts show <contact-id>             # full contact details
pippin contacts groups                        # list contact groups
```

### Voice Memos

List, export, transcribe, and summarize voice memos.

```bash
pippin memos list                             # list recordings
pippin memos info <memo-id>                   # full metadata
pippin memos export <memo-id> --output ~/Desktop/
pippin memos transcribe <memo-id>             # speech-to-text
pippin memos summarize <memo-id>              # AI summarization
pippin memos summarize <memo-id> --provider claude
pippin memos templates list                   # list AI prompt templates
pippin memos delete <memo-id>
```

### Audio

Text-to-speech, speech-to-text, and model management.

```bash
pippin audio speak "Hello, world"             # text-to-speech
pippin audio speak "Hello" --voice Samantha --output ~/Desktop/hello.m4a
pippin audio transcribe ~/Desktop/recording.m4a
pippin audio voices                           # list TTS voices
pippin audio models                           # list STT/TTS models
```

### Browser

Headless WebKit browser for web automation.

```bash
pippin browser open "https://example.com"     # open URL, return page info
pippin browser snapshot                       # accessibility tree of current page
pippin browser screenshot --output ~/Desktop/page.png
pippin browser click <ref-id>                 # click element by accessibility ref
pippin browser fill <ref-id> --value "text"   # fill input field
pippin browser scroll down
pippin browser tabs                           # list open tabs
pippin browser close                          # close session
pippin browser fetch "https://api.example.com/data"  # HTTP fetch (no browser)
```

### Utility

```bash
pippin doctor                                 # check permissions and dependencies
pippin init                                   # guided first-run setup
pippin completions --shell zsh                # generate shell completions
pippin shell                                  # interactive REPL
pippin                                        # bare invocation also starts REPL
```

## Agent Integration

### Recommended patterns

1. **Inspect before act:** Run `pippin doctor` and `pippin mail accounts` to verify state before issuing commands.
2. **Use agent format:** Always pass `--format agent` for structured, token-efficient output.
3. **REPL for multi-step workflows:** Pipe commands to `pippin shell` to avoid per-command startup overhead:
   ```bash
   echo -e "mail accounts\ncalendar today\nreminders list\nquit" | pippin shell --format agent
   ```
4. **Compound mail IDs:** Mail messages use `account||mailbox||numericId` format. Preserve the full ID when referencing messages.

### Error handling

Commands exit 0 on success. On failure, stderr contains the error message. In `--format agent` mode, errors are returned as:
```json
{"error":"description of the problem"}
```

### AI features requiring configuration

`memos summarize` and `calendar agenda` require an AI provider. Configure in `~/.config/pippin/config.json`:
```json
{"ai":{"provider":"ollama","ollama":{"model":"gemma4:latest","url":"http://localhost:11434"}}}
```

Supported providers: `ollama` (local, default), `claude` (API, requires `ANTHROPIC_API_KEY`).
