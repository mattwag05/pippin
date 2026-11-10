# Canonical operations

The harness speaks one vocabulary to every tool. An adapter (`adapters/<tool>.py`) turns a canonical operation and its canonical arguments into that tool's own call, and turns the tool's reply back into normalized records. An operation a tool does not document is simply absent from that adapter's `OPS`.

## Conventions

- Arguments are a flat dict. Optional arguments are omitted, never passed as null. An adapter ignores arguments its tool has no place for, and says so in `NOTES` when that changes the meaning.
- Containers are given both ways where a fixture knows both: `list` and `list_id`, `calendar` and `calendar_id`. Each adapter uses the form its tool documents. `folder` is a name.
- Dates and times in arguments are ISO 8601. A date without a time (`2026-12-01`) means a whole day.
- `id` is whatever the same tool returned from a list or search call. Ids are not portable between tools (for example, one event has a different id in Pippin than in the EventKit-identifier tools, and some CLIs use a position in the last listing).
- A parser returns a list of dicts. A record carries only the keys the tool provided. Values are passed through as the tool gave them, apart from unwrapping (envelopes, untrusted-content markers, `{label, value}` pairs). The harness, not the adapter, normalizes dates to instants and compares to ground truth.
- Every record has `id` and `title` when the tool gives them. `title` is the display name of the thing: a subject for mail, a full name for a contact, a name for a list, folder, calendar, mailbox or group.
- Write operations (create, edit, complete, delete, move, mark, send) return the affected record as `[{id, title, ...}]` when the reply is machine-parseable, otherwise the adapter has no parser for that operation.
- Sends and deletes are real calls. Where a tool needs an explicit flag to act without a prompt or preview (`confirm: true`, `--force`), the adapter passes it and names it in `NOTES`; the tool's own preview path is measured separately under Safety.

## Reminders

Record keys: `id`, `title`, `due`, `completed`, `list`, `notes`. List record keys: `id`, `title`.

| Operation | Arguments | Returns |
| --- | --- | --- |
| `reminders.lists` | none | list records |
| `reminders.list` | `list`, `list_id`, `include_completed` (bool, optional), `limit` (optional) | reminder records |
| `reminders.search` | `query`, `list` (optional), `list_id` (optional), `limit` (optional) | reminder records |
| `reminders.create` | `list`, `list_id` (optional), `title`, `due` (ISO 8601, optional), `notes` (optional) | the new reminder |
| `reminders.edit` | `id`, `list` (the list the reminder is in), `title` (optional), `due` (optional), `notes` (optional) | the reminder |
| `reminders.complete` | `id`, `list` | the reminder |
| `reminders.delete` | `id`, `list` | the reminder, if reported |

## Calendar

Record keys: `id`, `title`, `start`, `end`, `calendar`, `all_day`, `location`, `notes`. Calendar record keys: `id`, `title`.

| Operation | Arguments | Returns |
| --- | --- | --- |
| `calendar.calendars` | none | calendar records |
| `calendar.events` | `start`, `end`, `calendar` (optional), `calendar_id` (optional), `limit` (optional) | event records |
| `calendar.search` | `query`, `start`, `end`, `limit` (optional) | event records |
| `calendar.create` | `calendar`, `calendar_id`, `title`, `start`, `end`, `location` (optional), `notes` (optional), `all_day` (bool, optional) | the new event |
| `calendar.edit` | `id`, `title` (optional), `start` (optional), `end` (optional), `location` (optional), `notes` (optional) | the event |
| `calendar.delete` | `id` | the event, if reported |

## Contacts

Record keys: `id`, `title` (full name), `first`, `last`, `emails` (list of strings), `phones` (list of strings). Group record keys: `id`, `title`.

| Operation | Arguments | Returns |
| --- | --- | --- |
| `contacts.list` | `limit` (optional) | contact records |
| `contacts.search` | `query`, `limit` (optional) | contact records |
| `contacts.show` | `id` | one contact record |
| `contacts.create` | `first`, `last`, `email` (optional), `phone` (optional), `organization` (optional) | the new contact |
| `contacts.edit` | `id`, plus any of `first`, `last`, `email`, `phone`, `organization` | the contact |
| `contacts.delete` | `id` | the contact, if reported |
| `contacts.groups` | none | group records |

## Notes

Record keys: `id`, `title`, `folder`, `modified`, and `body` from `notes.show`. Folder record keys: `id`, `title`. A tool that guards writes with a revision token also returns `content_hash` from `notes.show`.

| Operation | Arguments | Returns |
| --- | --- | --- |
| `notes.folders` | none | folder records |
| `notes.list` | `folder` (optional), `limit` (optional) | note records |
| `notes.search` | `query`, `folder` (optional), `limit` (optional) | note records |
| `notes.show` | `id` | one note record with `body` |
| `notes.create` | `folder`, `title`, `body` | the new note |
| `notes.edit` | `id`, `title` (optional), `body` (optional), `content_hash` (only for tools that require it, taken from `notes.show`) | the note |
| `notes.delete` | `id`, `content_hash` (only for tools that require it) | the note, if reported |

## Messages

Chat record keys: `id`, `title`, `participants` (list of handles), `date` (last activity). Message record keys: `id`, `chat`, `sender`, `text`, `date`, `is_from_me`.

| Operation | Arguments | Returns |
| --- | --- | --- |
| `messages.chats` | `limit` (optional), `hours` (look-back window, optional) | chat records |
| `messages.history` | `chat` (a chat id from `messages.chats`), `limit` (optional), `hours` (optional, for tools that window by time) | message records |
| `messages.search` | `query`, `limit` (optional), `hours` (optional) | message records |
| `messages.send` | `to` (one phone number or email), `text` | nothing parsed |

## Mail

Message record keys: `id`, `title` (subject), `sender`, `date`, `read`, `mailbox`, `account`, and `body` from `mail.show`. Account record keys: `id`, `title`, `email`. Mailbox record keys: `id`, `title`, `account`, `unread`. Attachment record keys: `title` (file name), `size`, `mime`.

| Operation | Arguments | Returns |
| --- | --- | --- |
| `mail.accounts` | none | account records |
| `mail.mailboxes` | `account` (optional) | mailbox records |
| `mail.list` | `account` (optional), `mailbox` (optional, the inbox when omitted), `limit` (optional) | message records |
| `mail.search` | `query`, `account` (optional), `mailbox` (optional), `limit` (optional) | message records |
| `mail.show` | `id`, `account` (optional), `mailbox` (optional) | one message record with `body` |
| `mail.send` | `to` (list of addresses), `subject`, `body`, `account` (optional) | nothing parsed |
| `mail.move` | `id`, `to_mailbox`, `account` (optional) | nothing parsed |
| `mail.mark` | `id`, `read` (bool), `account` (optional) | nothing parsed |
| `mail.attachments` | `id`, `account` (optional), `mailbox` (optional) | attachment records |

## Voice Memos

Record keys: `id`, `title`, `date`, `duration` (seconds), and `text` from `memos.transcribe`.

| Operation | Arguments | Returns |
| --- | --- | --- |
| `memos.list` | `limit` (optional) | memo records |
| `memos.show` | `id` | one memo record |
| `memos.transcribe` | `id` | one memo record with `text` |
| `memos.delete` | `id` | nothing parsed |

## Adapter coverage at lock time

Counts are operations present in `OPS`. "Exercised" means a read ran through the adapter inside the benchmark VM and the parser returned the expected record. Everything else is marked untested in the adapter's `NOTES`.

| Adapter | Kind | Ops | Exercised |
| --- | --- | --- | --- |
| `pippin` | mcp | 44 | reminders, calendar, contacts, notes and messages reads (17 ops). Mail and Voice Memos had no store in the VM |
| `imsg` | cli | 4 | chats, history, search |
| `remindctl` | cli | 7 | lists, list, search |
| `reminders_cli` | cli | 6 | lists, list |
| `memo` | cli | 4 | all four (plain text) |
| `sweetrb_mail` | mcp | 9 | calls ran, no mail data to parse |
| `pf_mail` | mcp | 9 | calls ran, no mail data to parse |
| `sweetrb_notes` | mcp | 7 | folders, list, search, show |
| `apple_events` | mcp | 13 | all six reads |
| `mac_messages` | mcp | 4 | chats, history, search (plain text, no parsers) |
| `apple_pim` | mcp | 28 | reminders, calendar and contacts reads, mail accounts and mailboxes (12 ops) |
| `imcp` | mcp | 0 | not run: needs interactive approval |
