# PippinBench fixtures

Seeded fixture state for the competitive benchmark (`docs/competitive/methodology.md`, sections "Fixture state", "Correctness", "Safety").

**Run these scripts only inside the disposable benchmark VM.** `seed.sh` refuses to run when `kern.hv_vmm_present` is not 1. Nothing here may be run against a real Mac's Calendar, Reminders, Contacts, Notes or Messages.

The seeding path is independent of every tool under test: EventKit and Contacts from a small Swift program, `osascript` for Notes, Python `sqlite3` for the synthetic Messages store.

## Files

| File | Purpose |
| --- | --- |
| `manifest.json` | Ground truth. Every record has a stable `key`. Generated, do not edit by hand. |
| `build_manifest.py` | Regenerates `manifest.json`. Deterministic: no clock, no randomness. |
| `seed.sh` | Entry point. Builds `pb-seed`, seeds everything, writes `~/bench/state.json`. |
| `seed.swift` | `pb-seed`: `seed`, `dump`, `teardown`, `typedstream`, `untypedstream`. |
| `notes.js` | JXA for Notes: `seed`, `dump`, `teardown`. |
| `make_chatdb.py` | Builds and installs the synthetic `chat.db`; `restore` puts the original back. |
| `verify.py` | Reads the state back without any tool under test and compares it with the manifest. |
| `teardown.sh` | Removes exactly what `state.json` lists and verifies by identifier. |

## What is seeded

| Store | Container | Content |
| --- | --- | --- |
| Calendar | calendar `PippinBench` | 24 events, 28 occurrences: 12 base events (two that overlap, one all-day, one weekly series with exactly 5 occurrences, one created in Asia/Tokyo, one in America/New_York, one that spans the 2027-03-14 DST change, titles with emoji, combining marks, right-to-left text, quotes, backslashes) plus 12 events that carry the injection corpus in their notes |
| Reminders | list `PippinBench` | 27 reminders: 15 base (3 completed, 3 with no due date, neighbours that differ in every field) plus 12 that carry the injection corpus in their notes |
| Contacts | group `PippinBench` | 25 people, family names prefixed `PBX`, emails at `example.invalid`, phones `+15555550101` to `+15555550125`, all in the group |
| Notes | folder `PippinBench` (On My Mac) | 27 notes: 15 base plus 12 whose body is an injection string |
| Messages | synthetic `~/Library/Messages/chat.db` | 4 chats (two direct, two group), 5 handles, 300 messages, 1 attachment row |

Dates sit in 2027-03-08 to 2027-03-21. The weekly series starts on 2027-02-15 so that its fourth and fifth occurrences fall inside the window, one on each side of the DST change.

The manifest also holds two corpora that are not containers:

- `injection_corpus`: 12 prompt-injection test strings. Each is planted three times (note body, reminder notes, event notes); `planted` names the three records. They are inert test data aimed at `example.invalid`.
- `hostile_inputs`: 23 input strings for injection probes. They are **not seeded**. The harness replaces the literal `CANARY_PATH` with a temp path and passes each value as a title, query or id. The 10,000 character entry is stored as `{"repeat": "A", "times": 10000}`.

### Messages store

`make_chatdb.py` copies the table, index and trigger definitions from the real, empty `chat.db` that Messages created on this macOS version (kept as `chat.db.orig`), then inserts the manifest rows. No iMessage sign-in, nothing is sent.

- 289 text rows, 8 tapbacks (`associated_message_type` 2000 to 2005), 1 attachment-only row (text is U+FFFC), 1 retracted row (text NULL, `date_retracted` set), 1 group rename row (`item_type` 2).
- Text storage: 244 rows carry `text` and `attributedBody`, 42 rows carry the text **only** in `attributedBody`, 11 only in `text`. The blobs are real typedstream archives, produced in the VM by `NSArchiver` (`pb-seed typedstream`) and checked by `NSUnarchiver` in `verify.py`.
- Outbound rows keep `is_read = 0`, as Messages stores them. Some inbound tapbacks and the retracted row are also unread. The expected unread count per chat follows the rule "inbound, displayable, is_read = 0" and is 2, 0, 5, 2 for chat-a to chat-d. A reader that counts every `is_read = 0` row gets different numbers.

## Run

Copy this directory to `~/bench/fixtures` in the VM, then, inside the VM:

```sh
sh ~/bench/fixtures/seed.sh                 # idempotent; writes ~/bench/state.json
python3 ~/bench/fixtures/verify.py          # exit 0 and "verify: OK", or exit 1 with a diff
sh ~/bench/fixtures/teardown.sh             # removes what state.json lists, restores chat.db
```

To change the fixtures, edit `build_manifest.py`, run `python3 build_manifest.py > manifest.json`, copy, and seed again.

`seed.sh` first removes every calendar, reminders list, contacts group and Notes folder named `PippinBench`, and every contact whose family name starts with `PBX`, so a second run leaves exactly one copy. `teardown.sh` is stricter: it removes only the identifiers in `state.json`.

## Requirements in the VM

- Xcode command line tools (`swiftc`), `python3`, `~/grant.sh` (grants Calendar, Reminders and Contacts access to `~/bench/bin/pb-seed`).
- The ssh session must be allowed to send Apple events to Notes and System Events (TCC `kTCCServiceAppleEvents` rows for `/usr/libexec/sshd-keygen-wrapper`). Without the Notes row, `osascript` hangs on a consent dialog and `seed.sh` stops with a message.
- Notes shows a "Welcome to Notes" sheet on first launch and answers no Apple event until it is dismissed. `seed.sh` sets `hasShownWelcomeScreen` and clicks "Continue" through System Events when Notes does not answer.
- Messages must have created `chat.db` once. `seed.sh` launches it for up to 30 seconds if neither `chat.db` nor `chat.db.orig` exists.

## Limits and things that differ from a real store

- **Mail and Voice Memos** are not seeded (out of scope here; see the methodology).
- **EventKit and the DST event.** On macOS 26.6.2 a fetch by identifier returns the stored end of `evt-dst-span` (2027-03-14T10:00:00Z, 7 hours), while a date-range query returns an end one hour earlier (09:00:00Z). The manifest records the stored instants and the range-query value separately (`eventkit_range_query`), and `verify.py` checks both. A tool that reports 09:00Z for this event is repeating the platform, not inventing a value.
- **All-day event.** It is floating and was created on the VM's local day (the VM runs in UTC). The manifest stores dates, not instants.
- **Reminder due dates** carry the time zone America/New_York. Completion dates are fixed values in 2027.
- **Notes.** Titles come from the first line. Bodies use one paragraph per line; Notes rewrites U+2028 to a space, so the note bodies avoid it. A deleted folder moves to Recently Deleted, which is not scriptable; old copies from earlier seeds stay there until Notes purges them and are invisible to `notes.js dump`.
- **Synthetic `chat.db`.**
  - It uses a rollback journal, not WAL: a WAL store without its `-shm` file cannot be opened read-only.
  - The triggers are present but several call functions that only Messages registers, so plain SQLite cannot write to the store. It is meant to be read.
  - `chat.properties`, `message_summary_info` and the attachment file itself are absent. The attachment row is a reference only.
  - Tapbacks omit the newer emoji and sticker types.
  - If a tool launches Messages, `imagent` may reopen or migrate the file. Run `verify.py` again before trusting later results.
- **Typedstream blobs** hold one attribute (`__kIMMessagePartAttributeName`), encoded by `NSArchiver` from an `NSNumber`. The byte layout of that attribute may differ from blobs written by Messages; the string part is the standard layout.
