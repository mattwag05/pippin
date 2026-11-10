# Architecture

How Pippin works, for a contributor or an agent developer. It covers the two entry points, how an MCP tool call becomes a CLI process, the envelope, the app bridges, time budgets, permissions, caches, jobs, the test strategy and where the schemas live.

Pippin is one Swift 6 binary. It automates Apple apps on macOS (Mail, Calendar, Contacts, Messages, Notes, Reminders, Voice Memos). The same binary is a command-line tool and an MCP server. Every command answers with one JSON document, the envelope.

For the promises made to callers, read [contract.md](contract.md). For tool arguments and client setup, read [mcp-server.md](mcp-server.md). For hard-won details, read [gotchas/](gotchas/README.md). This file explains how the parts fit.

## Source layout

| Path | Contents |
| --- | --- |
| [Package.swift](../Package.swift) | Targets: `PippinLib` (all logic), `pippin` (the `@main` entry), `CDisclaimSpawn` and `CTypedStreamDecode` (small C and Objective-C targets), `PippinTests`. GRDB and swift-argument-parser are the dependencies. |
| [pippin-entry/Pippin.swift](../pippin-entry/Pippin.swift) | The root command, the subcommand list, and `main()`. Holds no logic beyond start-up. |
| [pippin/Commands/](../pippin/Commands) | One ArgumentParser command group per area (`MailCommand`, `CalendarCommand`, ...), plus `mcp-server`, `batch`, `job`, `do`, `doctor`. |
| [pippin/MCP/](../pippin/MCP) | The MCP server: tool registry, dispatcher, child runner, command policy, in-process tools. |
| `pippin/*Bridge/` | One folder per app. A bridge is the code that talks to the app or its data store. |
| [pippin/Formatting/](../pippin/Formatting) | The envelope, error codes, exit codes, field projection. |
| [pippin/Pagination/](../pippin/Pagination) | Cursor encoding and page helpers. |
| [pippin/Jobs/](../pippin/Jobs) | Detached jobs. |
| [pippin/Scripting/](../pippin/Scripting) | `ScriptRunner` (osascript), JXA string escaping, the Automation pre-check. |
| [Tests/PippinTests/](../Tests/PippinTests) | The test suite. |
| [docs/schemas/v4/](schemas/v4) | Generated JSON schemas. |

`PippinLib` is the only module with logic. Tests import it with `@testable`, so most types are `internal`.

## The two entry points

### CLI

`main()` in [Pippin.swift](../pippin-entry/Pippin.swift) does four things before it parses anything:

1. It calls `becomeOwnResponsibleProcess()` (see "Permissions").
2. It injects `ShellCommand.parser` and `AgentError.argumentParserMessage`, because `PippinLib` cannot see the root command type.
3. It records the start time for error envelopes.
4. It parses argv and runs the command. With no subcommand it starts the REPL (`ShellCommand`).

Any error, including an argument-parsing error, becomes an error envelope on stdout through `printAgentError`. The process exit code comes from [PippinExitCode](../pippin/Formatting/PippinExitCode.swift). `--help` and `--version` keep ArgumentParser's own output and exit 0.

Commands that return data conform to `AgentCommand` in [AgentCommand.swift](../pippin/Commands/AgentCommand.swift). The protocol has one method, `execute() async throws -> AgentResult`. `AgentResult` holds the payload plus the envelope metadata (`warnings`, `partial`, `nextCursor`, `fields`, `exitCode`). The CLI `run()` calls `execute()`, renders the result with `OutputOptions.render` and prints it. A command never prints on its own. The in-process MCP path calls the same `execute()`, so the two paths share one definition of each command.

`--format agent` is the only output format. The flag is still accepted so old callers keep working ([OutputOptions](../pippin/Commands/OutputOptions.swift)).

### MCP server

`pippin mcp-server` ([McpServerCommand](../pippin/Commands/McpServerCommand.swift)) reads newline-delimited JSON-RPC from stdin and handles one request at a time. It writes responses to stdout through `MCPStdioWriter`. It never uses `print`, because stdout carries the protocol. Diagnostics go to stderr. `--apps mail,calendar` lists and accepts only the tool groups named (a group is a tool name up to its first underscore), which cuts the context a client spends on tool schemas (`MCPDispatcher.exposed`, `AppFilterTests`).

`MCPDispatcher.handle` in [MCPServerRuntime.swift](../pippin/MCP/MCPServerRuntime.swift) answers `initialize`, `tools/list`, `tools/call` and `ping`. Notifications get no reply. An unknown method or tool is a JSON-RPC error (`-32601`). Everything that goes wrong inside a known tool is a normal tool result with `isError: true` and an error envelope as text. JSON-RPC errors are for protocol faults only ([gotchas/mcp.md](gotchas/mcp.md)).

## How an MCP tool call becomes a CLI process

```text
MCP client
   |  tools/call {name, arguments}        (JSON-RPC on stdio)
   v
McpServerCommand loop  (one request at a time)
   |
   v
MCPDispatcher.makeToolCallResponse
   |  1. find tool in MCPToolRegistry.tools
   |  2. SchemaValidator.validate(arguments, tool.inputSchema)
   |  3. tool.buildArgs(arguments) -> argv ending in --format agent
   |
   +--- tool.inProcess set and not demoted? ---+
   |                                           |
   | yes                                       | no
   v                                           v
MCPInProcessTools.execute            MCPServerRuntime.runChild
 parse argv, run AgentCommand         posix_spawn: pippin <argv>
 25 s deadline                        own process group, PIPPIN_MCP=1
   |                                  60 s hard cap (SIGTERM, then SIGKILL)
   |                                           |
   +---------------------+---------------------+
                         v
        envelope text -> content[0].text, isError = (exit != 0)
```

### The registry

[ToolRegistry.swift](../pippin/MCP/ToolRegistry.swift) holds `MCPToolRegistry.tools`, one `MCPTool` per tool (79 at the time of writing; `InProcessToolsTests.testRegistryToolCount` pins the number). Each tool is generated from an `MCPToolSpec` and the ArgumentParser definition of the command it runs ([ToolSpec.swift](../pippin/MCP/ToolSpec.swift)). The CLI is the single source; the spec says only what the CLI cannot:

- The tool `name` (the command path follows from it, see `MCPCommandPolicy.commandPath`), the `effect` and the tool `description`.
- For each MCP property, the CLI argument it binds to: `"--flag"`, `.positional` (an id, passed in place) or `.trailing` (free text, passed last after `--`). A numeric option also names its JSON type (`as: .integer` or `as: .number`), because ArgumentParser's help dump carries no Swift types.
- Overrides, only where the MCP wire text differs from the CLI: a description, a `required: true` the CLI leaves optional, or a schema `default`.

At registry build time `CLIArgument.arguments(of:)` reads each command's help dump (`_dumpHelp()`, rooted at `MCPCommandRoot`) and derives the rest: a flag is a boolean (default `false`, or `true` for a `--x/--no-x` flag that defaults on), a repeating option an array of strings, anything else a string; the `enum` from the argument's allowed values; required-ness from the argument's optionality; the description from the help text; an integer or number default from the CLI default. String defaults stay in the help text. The argv for a regular property is derived the same way: `flagIfTrue` for a flag, one `--flag=value` per element for a repeating option, `--flag=value` for an option, an id positional refused when it starts with `-`, and free text after `--` at the end.

A few properties keep a small closure (`emit: .custom`) or a written-out schema (`.special`), because no single CLI argument describes them: the send and delete `confirm` gates, `mail_show`'s `messageId`/`messageIds`/`subject` alternatives, `mail_mark.read` (`--read` or `--unread`), `contacts_search.phone` (moves the query to the value of `--phone`), the memos id-or-`all`, `mail_activity.preview` and `job_wait.timeout` (always passed, with MCP's own default), `mail_attachments.saveDir` (`--save-to-cache` when absent), `job_run.argv` (checked by `MCPCommandPolicy`) and `batch.entries` (one JSON string).

An `MCPTool` has:

- `name`, `description` and `inputSchema` (JSON Schema built with the `Schema` helpers).
- `effect`: `.readOnly` or `.mutating(verifyWith:)`. A tool with no effect is treated as mutating. `ToolEffectTests` fails on an unclassified tool. The effect also feeds the `readOnlyHint` and `destructiveHint` annotations in `tools/list` (`MCPTool.descriptor`).
- `buildArgs`: a closure from the MCP arguments to the argv for the CLI command.
- `inProcess`: an optional handler, set only for in-process tools.

Rules the argv builders follow, each enforced by a test:

- The argv always includes `--format agent`, before any trailing `-- <text>` (`testAllArgvEndWithFormatAgent`).
- Option values are bound as `--flag=value` (`ArgHelpers.option`). Free-form positionals go last, after a `--` separator. An id that starts with `-` is refused (`ArgHelpers.notFlagLike`), because ids sit before the options where `--` cannot go.
- A schema `default:` is advisory. It never reaches argv. When the MCP default must differ from the CLI default, the property's closure passes the flag.
- Write-safety gates that need no child live in `buildArgs`, so they run before anything is spawned.

`addingListOptions` adds `fields`, and for some tools `cursor`, `pageSize` and `page`, to the list and search tools.

### Validation before dispatch

`SchemaValidator.validate` ([SchemaValidator.swift](../pippin/Planner/SchemaValidator.swift)) runs before `buildArgs`. `buildArgs` reads only the keys it knows, so without this check a misspelled safety key would be dropped and the call would run. A NUL character in a string argument is refused here and again in `runChild`, because argv cannot hold one.

### Child processes

`MCPServerRuntime.runChild` starts `pippin <argv>` with `posix_spawn`. It uses `posix_spawn` instead of `Foundation.Process` because only `posix_spawn` can put the child in its own process group. Details:

- The binary is the running one: `resolvePippinPath` resolves `argv[0]` with `realpath`, not whatever `pippin` is on `PATH`.
- The child's stdin is `/dev/null`. Its stdout and stderr are drained on two background threads, so a large answer cannot fill a pipe and block.
- The child gets `PIPPIN_MCP=1`. `isMCPContext()` in [AIProvider.swift](../pippin/AIProvider/AIProvider.swift) reads it, and budgets shrink when it is set.
- The dispatcher passes `ownProcessGroup: true`. The timeout then signals the whole group, so an `osascript` that a bridge started dies with its parent. CLI callers (`pippin do`, `batch` outside MCP) keep the child in the foreground group so Ctrl-C reaches it.
- On a timeout the runner sends SIGTERM, then SIGKILL two seconds later, then SIGKILL to the group. A signal death counts as a timeout only if the runner's own timer sent the signal. Any other signal is `child_crashed`.
- A non-zero exit is not an error in the runner. The dispatcher passes the child's stdout through as the tool result with `isError: true`. If stdout is empty it reports `child_no_output`. The exit code itself does not reach the MCP client; only `isError` and the envelope do.

`runChild` blocks, so the dispatcher calls it through `detachBlocking` ([DetachBlocking.swift](../pippin/DetachBlocking.swift)). That moves the wait off Swift's cooperative thread pool. A lint script, `scripts/lint-detach-blocking.py`, fails the build when an `async` function makes a blocking call outside `detachBlocking`.

### In-process tools

[InProcessTools.swift](../pippin/MCP/InProcessTools.swift) runs some tools without a child: the EventKit reads (Calendar and Reminders), the Contacts reads, the Messages reads and the Notes reads. These are the tools whose registry entry sets `inProcess: MCPInProcessTools.execute`. The handler parses the same argv a child would receive against a small root command (`InProcessRoot`) and calls the same `AgentCommand.execute()`.

A blocking framework call can be abandoned but not killed. So each in-process call has a 25 second deadline (`deadlineSeconds`, `withDeadline`). If it expires, the call returns `in_process_timed_out`, and `demote` moves that tool to the child path for the rest of the session. Mail JXA, AI, browser, audio and every write stay in children, where a hard kill exists. Notes reads are JXA too, but their script already runs in an `osascript` child with its own kill, and the Automation pre-check cannot prompt in the server (stdin is not a TTY), so nothing in the server process waits on Notes; skipping the `pippin` child is what closed the warm Notes gap (pippin-ai5s).

### Command policy for `batch` and `job_run`

Both tools take raw argv. [MCPCommandPolicy.check](../pippin/MCP/MCPCommandPolicy.swift) limits what that argv may be when the caller is an MCP client:

- It must start with the command path of a registered tool (`commandPath(for:)`; `pathOverrides` covers tools whose path is not `<group> <rest-with-dashes>`).
- `batch` and `job run` cannot be nested.
- `--autonomous` is refused.
- `messages send` needs `--draft`.

The plain CLI `pippin batch` and `pippin job run` do not go through the policy. `BatchCommand` applies it when it runs under MCP.

## The safety gate

Every mutating MCP tool call passes through one function, `SafetyGate.run` in [SafetyGate.swift](../pippin/Safety/SafetyGate.swift). The chokepoint is `MCPDispatcher.makeToolCallResponse`: any tool whose `effect` is not `.readOnly` (an unclassified tool included) goes to the gate, and nothing else starts a child for it. `SafetyDispatcherTests.testEveryMutatingToolIsLoggedAtTheOneChokepoint`. Reads skip the gate, except that `checkRead` still enforces a `deny` rule.

Inside `run`, the order is:

1. Pull the reserved arguments (`confirmToken`, `idempotencyKey`, and a gate-answered `dryRun`) off the call.
2. Load the policy and write the `intent` line to the action log. If the line cannot be written, the call is refused (`audit_log_unavailable`).
3. Check `deny`, then validate the arguments against the tool's schema and build the argv.
4. Dry run: run the tool's own preview, or answer from the gate. No token, no rate count.
5. Idempotency: replay the stored result, or refuse a conflicting key.
6. Rate limit, checked before a token is issued.
7. Confirm token: issue one and return `confirmation_required`, or redeem the one presented.
8. Record the call in the rate limiter and the idempotency store, snapshot the prior state for undo, run the child, then write the `outcome` line and the undo record.

State lives in memory (confirm tokens) and in files under `~/.local/share/pippin/` (action log, `rate-limits.json`, `idempotency.json`, `undo/`). The policy is `~/.config/pippin/policy.json`. `PIPPIN_STATE_DIR` and `PIPPIN_POLICY` move them (`SafetyPaths`).

The plain CLI does not go through the gate. A command typed in a terminal has no policy, token, rate limit or action log entry. `batch` and `job_run` run commands without the dispatcher's gate, so `MCPCommandPolicy` refuses under MCP any command the policy denies, confirms or rate limits. The full model, with the test behind each claim, is in [safety-model.md](safety-model.md).

## The envelope

Every command writes one JSON document and a newline to stdout. The shape is defined in [AgentOutput.swift](../pippin/Formatting/AgentOutput.swift) and the schema is [envelope.schema.json](schemas/v4/envelope.schema.json). `AGENT_SCHEMA_VERSION` (currently 4) is the `v` field.

Success:

```json
{"v":4,"status":"ok","duration_ms":176,"warnings":["..."],"partial":true,"next_cursor":"...","data":[]}
```

`warnings`, `partial` and `next_cursor` are omitted when empty, false or absent (`AgentOkEnvelope`). `partial: true` means the result set is incomplete, for example after a soft timeout. It lets a caller tell "nothing found" from "the scan did not finish".

Error:

```json
{"v":4,"status":"error","duration_ms":12,"error":{"code":"access_denied","message":"...","next_step":{"retryable":false,"human_action":"..."},"remediation":{}}}
```

### Error codes and next_step

`AgentError.from` builds the payload. The `code` comes from `agentErrorCode(for:)`:

- An error that conforms to `RemediableError` ([Remediation.swift](../pippin/Formatting/Remediation.swift)) states its own `agentCode` and `nextStep`. There is no default for either, so a new case cannot compile without choosing both.
- Any other error gets its enum case name in snake case. A foreign error whose description is a sentence becomes `unknown_error`.
- ArgumentParser errors get their usable message through the injected `argumentParserMessage` hook, since `localizedDescription` hides it.

`NextStep` has `retryable`, `retry_after_seconds`, `next_call` (a tool name, arguments and the same call as argv) and `human_action`. It is always present on an error. For an error with no authored step, `retryable` follows the exit class (`NextStep.derived`). `remediation` is optional extra text for a human, from `RemediationCatalog` or from the error itself.

A timeout on a call that can change data is `outcome_unknown`, not a retryable timeout. It carries a `next_call` to a read tool that shows the current state. Two places produce it: `MCPServerRuntime.outcomeUnknownIfMutating` for a child killed at the MCP cap, and `ScriptRunnerError.outcomeUnknown` for a non-idempotent script that hit its timer.

### Exit codes

[PippinExitCode](../pippin/Formatting/PippinExitCode.swift) maps the snake-case code to a process exit status: 2 for bad input, 3 for not found, 4 for permission or configuration, 7 for timeout or rate limit, 5 for any other failure. ArgumentParser errors are 2. The classification reads the code string, so a new `*_not_found` code lands in bucket 3 with no extra work. `doctor` is the one command that exits non-zero (1) with a success envelope; `AgentResult.exitCode` carries that.

### Pagination

Paginated commands use `PaginationOptions` (`--cursor`, `--page-size`, `--page`) and the helpers in [Cursor.swift](../pippin/Pagination/Cursor.swift).

- A cursor is base64url JSON of `{offset, filter_hash}`. The hash covers the normalized filter arguments, so a cursor reused with different filters fails as `cursor_mismatch`. A malformed one is `invalid_cursor`.
- `--page N` is sugar for an offset of `(N-1) * pageSize`. A cursor wins over `--page`. Page size is capped at 100,000.
- `data` stays the item array. The cursor goes in the envelope's `next_cursor`. Commands must return pages with `AgentResult.page` or `emitPage`. Handing a `Page` to the plain initializer would nest `{items, next_cursor}` inside `data`. `scripts/lint-paginated-emit.py` rejects that.
- `pageFromPushdown` is for bridges that fetched `pageSize + 1` rows at the offset. The extra row says whether another page exists.

### Field projection

List commands return a default subset of keys per row (`EssentialRow`, applied in `AgentResult.init` when the payload is an array of such rows). `--fields a,b` selects keys and `--fields all` returns whole rows ([FieldProjection.swift](../pippin/Formatting/FieldProjection.swift)). A single-object answer such as `show` is not trimmed.

## The app bridges

Each bridge uses the narrowest mechanism that works for its app. The table gives the mechanism and the reason; the notes after it give the main limits.

| App | Mechanism | Why |
| --- | --- | --- |
| Calendar | EventKit | A real API exists and is permission-gated. |
| Reminders | EventKit | Same. |
| Contacts | Contacts framework (`CNContactStore`) | Same. |
| Messages, read | Read-only SQLite (GRDB) on `~/Library/Messages/chat.db` | Messages.app has no read API. |
| Messages, send | JXA through `ScriptRunner` | Sending needs the app. |
| Mail, metadata | Read-only SQLite on a snapshot of Mail's Envelope Index | JXA is too slow for list and search. |
| Mail, bodies and writes | JXA through `ScriptRunner` | The index holds no bodies and cannot be written. |
| Notes | JXA through `ScriptRunner` | Notes has no database pippin may read. |
| Voice Memos | Read-only SQLite on `CloudRecordings.db`; audio files on disk | No API. |

### Calendar and Reminders (EventKit)

[CalendarBridge](../pippin/CalendarBridge) and [RemindersBridge](../pippin/RemindersBridge) import EventKit. A synchronous EventKit fetch can stall on a damaged store, so each fetch waits at most 15 seconds and returns what it has, flagged as timed out (`fetchEventsSync`, `fetchRemindersSync`). Calendar edit and delete name a recurring event's occurrence and refuse without one ([EventTargeting.swift](../pippin/CalendarBridge/EventTargeting.swift)).

### Contacts (Contacts framework)

[ContactsBridge](../pippin/ContactsBridge) enumerates `CNContactStore`. Name and phone searches filter on the client and honor a soft timeout (`SoftTimeout.defaultMs`, 22 seconds, clamped to 1 second through 5 minutes). Sender enrichment for other bridges uses `ContactIndex`, which is cached (see "Caches").

### Messages (SQLite and JXA)

[MessagesDatabase](../pippin/MessagesBridge/MessagesDatabase.swift) opens `chat.db` with `config.readonly = true`. It needs Full Disk Access, which has no prompt. Most message text lives only in the `attributedBody` blob. SQLite cannot search a blob, so the bridge decodes it in Swift with `CTypedStreamDecode`. A search decodes only the most recent blob-only messages, up to a cap. When the cap is hit, the payload says so with `scan_truncated`, and an empty match set is then not authoritative ([mcp-server.md](mcp-server.md)). Sending goes through [MessagesSender](../pippin/MessagesBridge/MessagesSender.swift), which runs JXA against Messages.app. MCP clients can only create drafts (`MCPCommandPolicy`).

### Mail (SQLite, then a local store, then JXA)

Mail has three read paths, tried in this order ([gotchas/envelope-index.md](gotchas/envelope-index.md)):

1. **Envelope Index.** [MailEnvelopeIndex](../pippin/MailBridge/MailEnvelopeIndex.swift) reads list, search, activity and mailbox metadata from Mail's SQLite index in milliseconds. It never opens Mail's live files. It copies the database with its `-wal` and `-shm` files to a temp directory and opens the copy, because the WAL holds the newest messages. A version guard (`knownVersions`) refuses an index version it does not know. It needs Full Disk Access.
2. **Pippin's own store.** [MailMetaStore](../pippin/MailBridge/MailMetaStore.swift) is `~/.config/pippin/mail-meta.db`. It needs no Full Disk Access. `mail cache fill` writes it over Automation. Read state and identity come from one live bulk read on each answer, and stored rows are trusted only when that read vouches for them.
3. **JXA.** [MailBridge](../pippin/MailBridge/MailBridge.swift) and [MailBridgeScripts](../pippin/MailBridge/MailBridgeScripts.swift) build the scripts, and [MailBridgeRunner](../pippin/MailBridge/MailBridgeRunner.swift) runs them.

A failure on a faster path falls back to the next one. The reason is reported in the envelope's `warnings`, so a slow answer explains itself. `PIPPIN_MAIL_FASTPATH=0` and `PIPPIN_MAIL_STORE=0` switch the paths off.

Limits:

- Bodies are not in the index. `mail show` and every write use JXA.
- Gmail mailboxes other than All Mail, Trash, Spam and Drafts are label views, so the index code queries both the mailbox and the label tables.
- A compound id is `account||mailbox||ROWID`. If Mail rebuilds its index, the ids are renumbered. Cached bodies are therefore checked against the message date (see "Caches"), and the mutating mail commands accept `--expect-message-id` to refuse an id that now names a different message.
- Mail's own `unreadCount` property under-reports, so unread counts are computed from message rows.

### Notes (JXA)

[NotesBridge](../pippin/NotesBridge/NotesBridge.swift) drives Notes with JXA. Reads use bulk property getters to keep the number of Apple Events low. Writes take an exclusive advisory lock on `~/.config/pippin/notes-write.lock` (`flock`), which orders pippin's own writes. The lock does not stop Notes or another program from changing the same note.

### Voice Memos (SQLite and files)

[VoiceMemosDB](../pippin/MemosBridge/VoiceMemosDB.swift) reads `CloudRecordings.db` read-only. It needs Full Disk Access. `memos delete` is the one write: it refuses while Voice Memos is running, moves the audio file to the Trash first, then deletes the row, and moves the audio back if the row delete fails. Transcription backends are in [Transcriber.swift](../pippin/MemosBridge/Transcriber.swift) (Apple's Speech framework is imported there), summaries use the providers in [AIProvider](../pippin/AIProvider), and transcripts are cached.

### JXA and ScriptRunner

[ScriptRunner.run](../pippin/Scripting/ScriptRunner.swift) runs a script once through `/usr/bin/osascript -l JavaScript`.

- It drains both pipes on background threads, then waits.
- It sends SIGTERM at the deadline, then SIGKILL two seconds later. A signal death is a timeout only if the runner's timer sent the signal; otherwise it is `script_crashed`.
- A script that exits 0 but writes to stderr is `stderr_on_success`, after benign log lines are filtered.
- For an idempotent script on an app that is not running, it launches the app first, inside the same deadline. It does not run the script a second time.
- A pre-check, `AutomationPermission` ([AutomationPermission.swift](../pippin/Scripting/AutomationPermission.swift)), asks macOS whether Automation is allowed for the target. A denial fails fast as `automation_denied`, instead of waiting for `osascript` to block.
- Strings put into scripts are escaped by [JSEscape.swift](../pippin/Scripting/JSEscape.swift).

JXA is the slowest and least predictable mechanism. It goes through Apple Events to a running app, and a wedged app stalls the call. That is why the bridges read from SQLite where they can and bound every script.

## Time budgets and timeouts

Budgets nest. Each inner limit is shorter than the one around it, so the inner limit fires first and the caller gets partial results and a typed error instead of a kill.

| Limit | Value | Where |
| --- | --- | --- |
| MCP child hard cap | 60 s | `MCPServerRuntime.defaultChildTimeoutSeconds` |
| In-process deadline | 25 s | `MCPInProcessTools.deadlineSeconds` |
| Script budget under MCP | 55 s, minus time already used by the process | `ScriptRunner.mcpCommandBudgetSeconds`, `budget(requested:underMCP:elapsed:)` |
| `BatchBudget` under MCP | 50 s; unlimited in the CLI | [BatchBudget.swift](../pippin/BatchBudget.swift) |
| AI request timeout | 50 s under MCP, 120 s in the CLI | `aiRequestTimeoutSeconds()` |
| Soft timeout for scans | 22 s default, clamped 1 s to 5 min | [SoftTimeout.swift](../pippin/SoftTimeout.swift) |
| EventKit fetch | 15 s | `fetchEventsSync`, `fetchRemindersSync` |

What happens at each limit:

- **Soft timeout.** A scan that reaches its soft timeout stops and returns what it has. The result sets `partial: true` and adds a warning (`AgentResult.emit(timedOut:)`). A mail search that times out with no results is an error, `search_incomplete`, so an incomplete scan cannot look like "no matches".
- **BatchBudget.** Commands that loop over many items check `BatchBudget.exceeded` and stop. `BatchCommand` gives entries that start too late the error `batch_budget_exceeded`. The whole envelope is then `partial`, and finished entries are still returned.
- **ScriptRunner deadline.** The script is killed and the call fails with `timeout` (retryable) or, for a non-idempotent script, `outcome_unknown`.
- **MCP child cap.** The group is killed. A read-only tool returns `child_timed_out` (retryable). A mutating tool returns `outcome_unknown` (not retryable) with a `next_call` to the verify tool named in its `effect`.
- **In-process deadline.** The call returns `in_process_timed_out`, and the tool runs in a child for the rest of the session.

`outcome_unknown` is the important one for agents. It says the change may or may not have happened. The agent must read the current state before it repeats the call.

## Permissions

macOS privacy consent (TCC) is the main source of "it works in my terminal" bugs. The facts, from [gotchas/permissions.md](gotchas/permissions.md) and the code:

| Integration | Mechanism | Can pippin prompt? |
| --- | --- | --- |
| Calendar, Reminders, Contacts | EventKit and Contacts framework consent | Yes, from an interactive terminal |
| Mail, Notes (and Messages sends) | Automation (Apple Events) | Yes, on the first script run |
| Messages reads, Voice Memos, Mail Envelope Index | Full Disk Access | No. The user must enable it in System Settings. |

Priming (`PermissionPriming.canRequestAccess()`) allows a prompt only for an interactive terminal outside MCP. A bridge that cannot ask throws `access_denied` at once instead of waiting for a dialog nobody can see. `pippin permissions` and `pippin init` resolve the prompts one time, interactively.

### Disclaim and respawn

macOS attaches consent to the responsible process, which by default is the app that launched pippin (Terminal, an agent host, launchd). A grant given under one launcher would then not apply under another.

To avoid this, `main()` re-executes pippin as its own responsible process before anything else. `becomeOwnResponsibleProcess` calls `pippin_respawn_disclaimed`, which is in the `CDisclaimSpawn` C target and uses the private `responsibility_spawnattrs_setdisclaim` interface. The parent waits and passes on the child's exit status. If the interface is missing or the spawn fails, pippin runs in the current process.

[DisclaimRespawn](../pippin/DisclaimRespawn.swift) decides whether to do it:

- `PIPPIN_DISCLAIMED` is set on the re-executed process, so there is one disclaim per process tree. The MCP server's children inherit pippin's responsibility and do not re-execute.
- `PIPPIN_NO_DISCLAIM=1` (or `true`) turns it off. Then the grant attaches to the launching app.

Because of this, TCC grants attach to the pippin binary itself (identity `com.mattwag05.pippin`), not to the launcher. One grant then works under every launcher. A new grant is needed if the binary's code identity changes.

Code signing decides whether the identity survives a rebuild. A default SwiftPM build is ad-hoc signed, so its identity is its content hash and every build looks like a new app. `scripts/sign.sh` signs with a stable identity and the fixed identifier `com.mattwag05.pippin`; `make install` calls it. If no identity is available it warns and leaves the ad-hoc signature. `pippin doctor` reports the state.

The embedded `pippin-entry/Info.plist` supplies the usage-description strings that the EventKit and Contacts requests need. `Package.swift` links it into the binary.

## Caches and invalidation

All caches are best effort. A cache failure reads as a miss and the caller reads live data.

| Cache | File | Invalidation |
| --- | --- | --- |
| Mail body cache ([MailBodyCache](../pippin/MailBridge/MailBodyCache.swift)) | `~/.config/pippin/mail-cache.db` | Every read passes the message's current date. A row whose date differs is a miss and is deleted, because a compound id can name another message after Mail rebuilds its index. Read state is never served from it. |
| Mail accounts map ([MailAccountsCache](../pippin/MailBridge/MailEnvelopeIndex.swift)) | `~/.config/pippin/mail-accounts.json` | Refreshed when empty, when `--account` names an unknown account, or (limited to once per hour, `isStale` with a one-hour TTL) when the index holds an account UUID it cannot map. A failed refresh falls back to the stale file. |
| Mail metadata store ([MailMetaStore](../pippin/MailBridge/MailMetaStore.swift)) | `~/.config/pippin/mail-meta.db` | Only fields that never change are stored. A row is trusted only when the live read agrees; a row whose date disagrees is evicted. A mailbox that was not fully filled is not used. |
| Mail embeddings ([EmbeddingStore](../pippin/MailAIBridge/EmbeddingStore.swift)) | `~/.config/pippin/mail-embeddings.db` | Rows carry the model and `message_date`. |
| Contact index ([ContactIndexCache](../pippin/ContactsBridge/ContactIndexCache.swift)) | `~/.config/pippin/contact-index.db` | Keyed by `CNContactStore.currentHistoryToken`. Any Contacts change changes the token, which makes the cache a miss. |
| Transcripts ([TranscriptCache](../pippin/MemosBridge/TranscriptCache.swift)) | `~/.config/pippin/transcripts.db` | Keyed by memo id. Stored with the provider and time. |

The SQLite caches open through `openCacheQueue` ([CacheDB.swift](../pippin/CacheDB.swift)): write-ahead logging and a 5 second busy timeout, because a background fill can write while other commands read. The Envelope Index snapshot is not a cache. It is a temporary copy, discarded after the read.

## Jobs

`job_run` (CLI `pippin job run -- <argv>`) starts a detached pippin process and returns a job id at once. It exists for work longer than the MCP cap.

- State lives in `~/.cache/pippin/jobs/<id>/`: `status.json`, `stdout.log`, `stderr.log` ([JobStore](../pippin/Jobs/JobStore.swift)). Status writes are atomic renames.
- The runner is the hidden `JobRunnerInternalCommand`. It calls `setsid()`, runs the command, and is the only writer of a terminal state ([JobCommand.swift](../pippin/Commands/JobCommand.swift)).
- States are `running`, `done`, `error`, `killed`. A terminal state is never overwritten except by `gc`.
- If the runner dies, the job would stay `running` forever. `JobStore.readCanonical` checks the runner process and rewrites such a job as `error` with `error_code: "runner_lost"`.
- `job_wait` polls until the job ends or its timeout (default 300 seconds) passes. Under MCP, `job_wait` runs in a child like any other tool, so the 60 second cap applies to it too.
- Under MCP, the job's argv goes through `MCPCommandPolicy`.

## Test strategy

The suite is XCTest, more than 2,600 tests (`make test` prints the count). Tests never need a live Apple app. A test that needs a permission or a service the machine lacks skips itself.

**Fakes.** Bridges take injected collaborators: the app launcher, the Automation check and the app-running check on `ScriptRunner.run`; `isAppRunning` and `trash` on `VoiceMemosDB.deleteMemo`; a database path on the SQLite bridges. `MessagesFixture` ([MessagesTestSupport.swift](../Tests/PippinTests/MessagesTestSupport.swift)) builds a `chat.db` stand-in. AI code uses small fakes such as `FakeAIProvider` and `MockTranscriber`.

**JavaScriptCore script tests.** The JXA that bridges generate is run inside JavaScriptCore against a fake app object. The tests then assert which Apple Events and writes the script issues, not how its source reads. See `NotesScriptBehaviorTests`, `MailBulkScriptBehaviorTests`, `MailMessageScriptBehaviorTests` and `JXAScriptBuilderTests` in [Tests/PippinTests](../Tests/PippinTests).

**Fuzz tests.** [FuzzTests](../Tests/PippinTests/FuzzTests.swift) use a seeded generator (`FuzzRNG`, SplitMix64) against validators, argument builders, the MCP request path, ids, cursors and parsers. A failure prints its seed. Replay it with `PIPPIN_FUZZ_SEED=<seed>`.

**Chaos tests.** [ChaosTests](../Tests/PippinTests/ChaosTests.swift) use `/bin/sh` one-liners as children that die, stall, ignore SIGTERM or write half an answer, and temporary store files that vanish, shrink or lock. Every case must end in a typed error, never a hang and never a success. `scripts/test-suite.sh fuzz|chaos` runs either suite alone; CI runs them as named steps.

**Schema golden tests.** [SchemaGoldenTests](../Tests/PippinTests/Contract/SchemaGoldenTests.swift) regenerate `docs/schemas/v4/` from the registry and the payload models and fail when the checked-in files differ.

**CLI and MCP drift tests.** [CLIMCPDriftTests](../Tests/PippinTests/Contract/CLIMCPDriftTests.swift) check the generated registry against the ArgumentParser command definitions, reading the help dump independently of the generator: every property must set a real CLI argument of a matching kind, `enum` and required-ness, and every CLI argument must be reachable or listed in `cliOnly` with a reason. They are what keeps the hand-given parts honest: a wrong `as: .integer` fails the parser probe, and a binding to a missing argument fails here (and stops the registry from building). `ToolRegistryTests` parses every tool's argv with its real command group.

**Conformance tests.** [ConformanceTests](../Tests/PippinTests/Contract/ConformanceTests.swift) run the built binary and check that every tool answers a bad argument with one schema-valid error envelope.

**Runtime tests.** `MCPServerRuntimeTimeoutTests`, `ScriptRunnerTests`, `BatchBudgetTests` and `DisclaimRespawnTests` cover the limits above.

**End-to-end script.** `make e2e` runs [scripts/e2e-smoke.sh](../scripts/e2e-smoke.sh) against the installed binary and the real apps, read-only by default. It is a manual check for Apple-app behavior, not part of `make test`. Exit 2 means permissions are missing.

**Lint scripts.** `scripts/lint-detach-blocking.py` and `scripts/lint-paginated-emit.py` guard two rules that the type system cannot. Each has a `--self-test`. `make ci` runs both after SwiftFormat.

## Where schemas live

- [docs/schemas/v4/](schemas/v4): the envelope schema (`envelope.schema.json`, by hand), one input schema per tool (`tools/<tool>.input.schema.json`), output schemas for the tools that have one, and `index.json`, which maps each tool to its CLI command, its effect and its schemas. The directory name follows `AGENT_SCHEMA_VERSION`.
- [docs/contract.md](contract.md): what a caller may rely on, which test holds each statement, the semver rules and the deprecation policy.
- Regenerate generated schemas with `PIPPIN_UPDATE_SCHEMAS=1 make test`, then run `make test` again to confirm they are stable.

Seven tools have no output schema; `index.json` records each reason.
