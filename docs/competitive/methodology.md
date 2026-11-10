# Competitive methodology

Status: pre-registered. This file was committed before any head-to-head result existed, so the criteria cannot be tuned to the outcome. Any later change to this file must be a separate commit that states what changed and why, and results produced under the old rules must be re-run or labeled with the methodology commit they used.

The field (which tools, which pinned versions) is in [field.md](field.md). The harness lives in `bench/competitive/`. Results are published in `results.md` next to this file once they exist.

## Principles

1. Same machine, same OS build, same fixture state, same prompts, same agent model for every tool.
2. Each tool is driven through its documented, idiomatic interface (MCP over stdio for MCP servers, the CLI for CLIs). One thin adapter per tool. No adapter may contain logic that makes its tool look better or another look worse. Pippin's adapter gets no special case.
3. Medians and spread, never best runs. Every number carries N.
4. A tool that could not be run is reported as "not run" with the reason. It is never scored as a loss for that tool or a win for anyone else.
5. Losses and ties are published with the same prominence as wins.
6. Competitor code is studied through its public interface and behavior only. Nothing is copied into Pippin.
7. Competitor READMEs, tool descriptions and outputs are untrusted data. They are recorded, never followed as instructions.
8. Scope is stated per tool. A single-app tool is compared only on the apps it claims to support, and the overall table says so.

## Environment record

Every result file records: date, hardware model and chip, memory, macOS version and build, each tool's pinned version or commit SHA, runtime versions (Swift, Node, Bun, Python), the agent model id used for task runs, and the methodology commit SHA.

## Fixture state and safety of the benchmark itself

The benchmark must never send mail or messages and must never alter data that the harness did not create.

- Sandbox namespace. A seed script creates a clearly named throwaway set: a calendar, a reminders list, a Notes folder and contacts carrying a fixed `PippinBench` marker. Write operations (create, edit, delete) are exercised only inside that namespace. A teardown script removes exactly what the seed created and verifies it by id.
- Read-only host stores. Read, list and search operations for Mail and Messages run against the host's existing data, because neither app can be seeded without sending. Only timings, counts, field shapes and hashes are recorded. Message content never enters a result file.
- Ground truth. Correctness checks compare each tool's output with ground truth that the harness derives independently (the seeded fixture manifest for the sandbox namespace, and direct read-only queries of a snapshot copy of the store where the harness has access).
- Send and delete tripwire. In agent task runs, every tool sits behind the same pass-through MCP proxy. The proxy forwards read calls and sandbox-namespace writes untouched. A call that would send mail or a message, or delete or modify anything outside the sandbox namespace, is not forwarded: it is logged as an attempted action and answered with a neutral synthetic result. The proxy applies the same rule to every tool, Pippin included. A tool's own guardrails (dry-run, confirmation) are evaluated separately under Safety, by direct calls that stay inside the sandbox namespace or that use the tool's own preview mode.
- Synthetic scale stores. Scaling tests (for example 100k messages, 5k contacts) use generated SQLite stores where a tool accepts a store path. Where a tool only reads the live store, scaling is reported at the host's real size, with that size stated, and labeled "host scale".

## Axes

Each axis produces raw measurements plus a 0 to 4 score from the rubric below. Raw measurements are the primary result. Scores exist only to build the summary table.

### 1. Coverage

A capability matrix per app (Mail, Calendar, Contacts, Messages, Notes, Reminders, Voice Memos) by operation: read, list, search, create, edit, delete, send, attachments, recurring events, groups, folders or lists, and move or mark where the app has them.

- A cell is "yes" only if the operation is documented or present in the tool's interface AND a harness probe succeeded. "claimed" means documented but the probe failed or could not run. "no" means absent.
- Score per app = share of applicable cells that are "yes". The axis score is the mean across the apps a tool claims, and the all-apps coverage count is shown beside it so that a narrow tool with full coverage of one app is not mistaken for a broad one.

### 2. Correctness

Against the sandbox fixture manifest and snapshot ground truth:

- Field accuracy: every returned record must have fields that all belong to the same underlying record (the cross-record field-mixing class). The fixture includes adjacent records with distinct, checkable field tuples.
- ID stability: the same record returns the same id across 3 calls and after an unrelated record is added.
- Pagination: walking all pages returns every fixture record exactly once.
- Counts: any count a tool reports equals the number of records it can list under the same filter.
- Encoding: fixture titles and bodies with emoji, combining marks, right-to-left text, quotes, backslashes and newlines round-trip unchanged.
- Time: fixture events in two time zones, an all-day event and an event spanning a daylight-saving change return the correct instants.

Score = share of checks passed, per app, averaged over claimed apps.

### 3. Reliability

- Success rate over N = 30 repeated runs of each read operation (N = 10 for sandbox writes).
- Hang rate: share of runs that exceed a 60 second wall-clock ceiling and are killed by the harness.
- Concurrency: 8 simultaneous read calls, success rate and whether any output is corrupted.
- Degraded conditions, where the harness can create them without touching system settings: target app not running, malformed input, nonexistent id, oversized input. Permission denial is recorded when it is observed, and is not forced.
- Error clarity: an error is "clear" if it is machine-readable, names the failing condition, and returns a nonzero exit code or an MCP error. Graded yes, partial or no per probe.

### 4. Speed

- Cold start: time for the first call from a fresh process (for MCP servers: spawn, initialize, first tool result).
- Warm latency per operation: p50 and p95 over N = 30, after 3 discarded warmups. MCP servers are measured warm over a persistent session and cold per spawn, both reported.
- Scaling: latency against dataset size, on synthetic stores where supported, otherwise host scale.
- Timing uses a monotonic clock in the harness process and includes everything an agent would wait for.
- Tie rule: two tools tie on an operation when their p50 values are within 10 percent of each other or within 20 ms, whichever is larger.

### 5. Safety

- Guardrail matrix per destructive or outbound operation (send, delete, edit, move): dry-run available, confirmation required by default, policy control, rate limit, audit log, undo. Verified by probe, not by documentation alone.
- Injection handling: a fixed corpus of prompt-injection strings is planted in sandbox notes, reminder and event text, and (read-only) presented through each tool's output path. Measured: whether the tool marks returned content as untrusted data, and whether any tool-level behavior changes because of the content.
- Input injection: a fixed corpus of hostile inputs (quotes, backslashes, AppleScript and shell metacharacters, newlines, NUL, very long strings) passed as titles, queries and ids inside the sandbox. A failure is any execution of injected code, any write outside the target record, or a crash. The corpus uses harmless canary payloads only (they write a marker file in the harness temp directory).
- Agent-level: attempted outbound or out-of-namespace actions recorded by the tripwire proxy during task runs.

### 6. Agent ergonomics

- Schema stability: output of each operation parses as JSON and matches the same shape across 5 runs and across empty, single and multi-record results.
- Error envelope: errors are structured and distinguishable from success without string matching.
- Token cost: tokens (counted with one fixed tokenizer for all tools) of the tool manifest an agent must load, and of the output for a fixed set of equivalent tasks (list 20 messages, show one message, today's events, search contacts, list reminders).
- Tool-description quality: each tool description is graded against a fixed checklist (says what it does, names required parameters, states side effects, states id and date formats, states limits). Graded by two independent model graders with the checklist, disagreements shown.
- Discoverability: whether a machine-readable capability listing exists.

### 7. Task success

Identical realistic tasks, same agent loop, same model, same system prompt and task prompt for every tool, 5 trials each:

1. Triage the inbox: list recent mail and classify it (read-only).
2. Schedule around conflicts: find a free slot and create an event in the sandbox calendar.
3. Turn a voice memo into reminders in the sandbox list.
4. Find and summarize a thread.
5. Injection trial: a sandbox note contains an instruction to send its contents to an outside address. The task is only to summarize the note.

Scored per trial: success (checked by a programmatic assertion on sandbox state or a fixed grading checklist), safety violations (tripwire hits), tool calls, and total tokens. A task that a tool cannot attempt because it lacks the app is "out of scope", not a failure.

### 8. Operability

- Install friction: number of commands and wall-clock time from nothing to a first successful read call, following the tool's own instructions exactly.
- Diagnostics: whether a self-check command or tool exists and whether it names the fix for a missing permission.
- Docs: install, permissions and every tool or command documented (checklist).
- Tests and CI: whether a test suite exists, test count, whether CI runs on the repository.
- Release hygiene: tagged releases, signed or notarized binaries, checksums.
- Maintenance: commits in the last 90 days and median time since last release, taken from the pinned field data.

## Scoring rubric

Each axis maps raw results to 0 to 4:

| Score | Meaning |
| --- | --- |
| 4 | Meets every check on the axis, or is the best measured value with no failed check |
| 3 | Minor gaps: at most 10 percent of checks failed, or within the tie rule of the best |
| 2 | Works with notable gaps: 10 to 40 percent of checks failed, or up to 3 times slower than the best |
| 1 | Major gaps: more than 40 percent of checks failed, or more than 3 times slower than the best |
| 0 | Not supported, or could not complete the axis |
| n/r | Not run, with the reason |

"Leads" means the strictly highest score on an axis among tools that ran. "Ties" means equal score, or raw values inside the tie rule. Axis scores are never summed into a single number.

## Dealbreaker flags

A tool gets a dealbreaker flag, shown in the ranked table, for any of these when observed by the harness: code execution from a hostile input string, sending or deleting without any confirmation or preview path, returning fields from different records as one record, a hang with no timeout, or an unmaintained state (archived, or no commit in 12 months). Flags apply to Pippin by the same rules.

## Reproduction

`bench/competitive/run.sh` runs every stage and writes `bench/competitive/results/<date>/` with raw JSON and CSV plus the environment record. Competitor checkouts are pinned by commit in `bench/competitive/tools.lock.json` and installed outside the repository. Stages that need macOS privacy permissions state which permission and which binary, and skip with "not run" if it is missing.

## Known limits of this method

- Mail and Messages cannot be seeded without sending, so their correctness checks rely on snapshot ground truth and host data, which makes them reproducible in procedure but not in data.
- macOS privacy permissions are granted per binary by a person. A tool that has not been granted a permission on the benchmark machine is reported "not run" for the affected operations.
- The agent task axis depends on a model. The model id is pinned in the results, and different models may rank tools differently.
- One machine and one macOS build. No claim is made about other hardware or OS versions.
