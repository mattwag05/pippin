# Performance baseline and targets

How long the read-only commands an agent calls most take, what they should take, and what was changed to get there. Tracks pippin-a4dr (audit findings PERF-4, PERF-5, PERF-7).

## Where and how this was measured

| | |
| --- | --- |
| Date | 2026-11-09 |
| Machine | Apple M5 Pro, 64 GB |
| macOS | 27.2 |
| Build | `xcrun --sdk macosx swift build -c release` |
| Before | branch `claude/pippin-apple-automation-3b11b3` at `e42067f` |
| After | this branch at `9871be5` |
| Apps | Mail and Notes running |

Store sizes, as counts only:

| Store | Size |
| --- | --- |
| Mail | 6 accounts, 68 mailboxes, 28,496 indexed messages, 64 MB Envelope Index |
| Messages | 16,813 messages in 2,334 chats |
| Notes | 530 notes in 42 folders |
| Reminders | 40 incomplete in 6 lists |
| Voice Memos | 51 recordings |
| Calendar, Contacts | not readable in the bench context, see "Not measured" |

Method: each command is run 5 times, a new process every time, with `--format agent` and `PIPPIN_NO_DISCLAIM=1`. The figure is wall clock from spawn to exit, median and maximum of the 5. Output is parsed in memory for a row count and a hash and is never printed or stored. Five runs give a median and a maximum, not a p95.

Reproduce with:

```bash
xcrun --sdk macosx swift build -c release
python3 scripts/bench-latency.py .build/release/pippin /tmp/pippin-bench.json 5
```

The script runs exactly these commands, each followed by `--format agent`:

```
pippin status
pippin doctor
pippin digest
pippin mail accounts
pippin mail mailboxes
pippin mail list --limit 20
pippin mail list --limit 20 --no-contacts
pippin mail search the --limit 10
pippin mail activity --preview 0
pippin calendar today
pippin calendar events --range week
pippin calendar search meeting
pippin reminders list --limit 20
pippin reminders search call
pippin contacts list
pippin contacts search john
pippin messages list --limit 10
pippin messages list --limit 10 --no-contacts
pippin messages search the
pippin messages show <the newest conversation id>
pippin memos list --limit 10
pippin notes list --limit 50
```

## Targets

Median (p50) wall clock per invocation, by what the command has to talk to:

| Class | Commands | Target p50 |
| --- | --- | --- |
| Store-backed read | mail list, search, activity, mailboxes; messages; memos; contacts | under 100 ms |
| EventKit read | calendar, reminders | under 150 ms |
| Scripted read (one osascript run) | mail accounts, notes list | under 500 ms |
| Composite | status, doctor, digest | under 1,000 ms |

## Results

Milliseconds. "Same output" means the old and new binaries returned the same envelope, compared field by field with only `duration_ms` and `generatedAt` ignored.

| Command | Class | Before median | Before max | After median | After max | Target | Result | Same output |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `status` | composite | 603 | 629 | 351 | 361 | 1,000 | pass | yes |
| `doctor` | composite | 797 | 813 | 260 | 268 | 1,000 | pass | yes |
| `digest` | composite | 883 | 910 | 419 | 432 | 1,000 | pass | yes |
| `mail accounts` | scripted | 344 | 358 | 200 | 200 | 500 | pass | yes |
| `mail mailboxes` | store | 52 | 68 | 36 | 40 | 100 | pass | yes |
| `mail list --limit 20` | store | 220 | 236 | 65 | 67 | 100 | was a miss, now pass | yes |
| `mail list --limit 20 --no-contacts` | store | 200 | 201 | 48 | 49 | 100 | was a miss, now pass | yes |
| `mail search the --limit 10` | store | 242 | 264 | 85 | 86 | 100 | was a miss, now pass | yes |
| `mail activity --preview 0` | store | 251 | 254 | 96 | 98 | 100 | was a miss, now pass (4 ms spare) | yes |
| `reminders list --limit 20` | EventKit | 71 | 73 | 71 | 71 | 150 | pass | yes |
| `reminders search call` | EventKit | 67 | 67 | 67 | 68 | 150 | pass | yes |
| `messages list --limit 10` | store | 48 | 54 | 48 | 50 | 100 | pass | yes |
| `messages list --limit 10 --no-contacts` | store | 28 | 29 | 30 | 31 | 100 | pass | yes |
| `messages search the` | store | 36 | 36 | 36 | 37 | 100 | pass | yes |
| `messages show <id>` | store | 40 | 40 | 40 | 41 | 100 | pass | yes |
| `memos list --limit 10` | store | 14 | 15 | 15 | 16 | 100 | pass | yes |
| `notes list --limit 50` | scripted | 333 | 362 | 344 | 359 | 500 | pass | yes |
| `calendar today`, `events`, `search` | EventKit | not measured | | not measured | | 150 | unknown | error envelope identical |
| `contacts list`, `search` | store | not measured | | not measured | | 100 | unknown | error envelope identical |

No measured command misses its target. Four did before.

### Not measured

Calendar and Contacts return `access_denied` in the bench context: with `PIPPIN_NO_DISCLAIM=1` the grant belongs to the launching app, which has neither. The 38 to 46 ms those commands took is the cost of the refusal, not of a read. The audit of 2026-11-09 measured the installed 0.41.1 with its own grants at 26 to 32 ms for `calendar today` and 349 ms for `contacts list` (602 contacts). If that holds, `contacts list` misses the 100 ms target. It has not been re-measured on this branch.

`status`, `doctor` and `digest` were measured with those two sections denied, so their figures leave out the Calendar and Contacts reads.

## What was slow, and what changed

### Mail list, search and activity: a cold snapshot (PERF-4)

The audit put 165 ms of a 225 ms `mail list` on copying the Envelope Index. The copy is not the cost. It is an APFS clone and takes 1 to 4 ms. The cost is the first query: the clone is a new file with an empty page cache, so SQLite faulted its pages in one random read at a time.

Measured on a 64 MB index, copy plus open plus the list query:

| Variant | ms |
| --- | --- |
| Clone, then query (before) | 188 |
| Clone, `F_RDADVISE` for the whole file, then query (after) | 34 |
| Query a snapshot that is already warm | 12 |

Fix: one `fcntl(F_RDADVISE)` after the copy asks the kernel for a single sequential read-ahead (`MailEnvelopeIndex.adviseReadAhead`). No cache, so nothing to invalidate.

A process also keeps one snapshot for as long as it is current (`MailEnvelopeIndexMemo`), so `digest` and `status` copy the index once, not once per account. Invalidation rule: the snapshot is reused only while Mail's database file and its `-wal` each have the inode, size and modification time they had just before the copy, and the account map is unchanged. Tests cover a write to the `-wal`, a same-size rewrite, a checkpoint, a replaced file and a changed account map.

Considered and not done: keeping the snapshot on disk between invocations. It would reach the 12 ms row, but it leaves a copy of mail metadata outside the directory macOS protects, and needs invalidation across processes. 22 ms is not worth either.

### Mail accounts: one Apple Event per property per account

`mail accounts` asked each account for its name, addresses and id in turn: 20 Apple Events for 6 accounts. It now asks for each property across all accounts at once, 4 events in total, and builds rows only when the three lists are the same length. Any mismatch or error runs the old per-account loop. 344 ms to 200 ms, and every command that starts by listing accounts (`status`, `doctor`, `digest`) gets the same saving.

### doctor: 15 probes in sequence (PERF-7)

The probes share no state. They now run together and report in the listed order. 797 ms to 260 ms.

### digest: four sections in sequence (PERF-7)

Mail, calendar, reminders and notes are now gathered together. Warnings stay in section order. 883 ms to 419 ms.

### status: the same question asked twice (PERF-7)

The sections already ran concurrently, but the permissions table asked Mail for its accounts and Notes for its folders a second time, in sequence, and that task was the slowest. Each is now asked once and shared, and the note count no longer waits for the folder list. 603 ms to 351 ms.

The two Voice Memos probes are kept in sequence. Run at the same moment, one of the two connections to the live database failed in each of four runs, which showed up as a missing section or a denied permission. The comparison of old and new output caught this before it was committed, and a test pins the order.

### Contact resolution (PERF-5): left as it is

The handle to name index is already cached on disk and keyed by the Contacts history token, so the address book is not enumerated per command. What remains is the lookup of that token and the cache read, which run after the query. Here that is about 17 ms (`mail list` 65 ms against 48 ms with `--no-contacts`), measured with Contacts denied. Running it alongside the query would save at most the shorter of the two, on commands that already meet their target, and the granted case could not be measured in this context.

## Measured floors

What a command cannot go below without changing how it talks to the app:

| Floor | Median ms |
| --- | --- |
| `pippin --version` (process start) | 8 |
| `osascript -l JavaScript -e 1` (interpreter start, no app) | 26 |
| One osascript run with one Apple Event to Mail | 104 |
| One osascript run with one Apple Event to Notes | 109 |
| The accounts script run directly in osascript (4 Apple Events) | 125 |

So `mail accounts` at 200 ms is about 75 ms above its script, `status` and `digest` cannot go below one scripted read of Mail or Notes, and `notes list --limit 50` at 344 ms is the bulk AppleScript read itself.

## Known limits of this baseline

- One machine, one data set, warm apps. A cold Mail or Notes launch is not covered.
- The read-ahead cost grows with the size of the Envelope Index. At 28,496 messages it is 34 ms. It has not been measured at 100,000.
- `mail activity --preview 0` passes with 4 ms to spare.
