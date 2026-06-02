# Roadmap

Tracked in [beads](https://github.com/gastownhall/beads) — run `bd ready` to see actively claimable work.

The original v0.x roadmap (mail watch, triage rules engine, MCP server, unified
digest, REPL completion, contacts write, smart-create for calendar/reminders,
plan-and-execute `pippin do`) all shipped before v0.22. The remaining items
below are explicitly **deferred** per their own beads' descriptions — captured
so the scope isn't lost, not actively worked on.

---

## Deferred (revisit on demand)

### Async withTimeout for EventKit bridges (`pippin-91n`) — P3

EventKit-backed bridges (Reminders, Calendar) are async, so the cooperative-
thread blocking concern doesn't apply. Hang risk is low in practice — EventKit
predicates are efficient. Captured to revisit if a real hang surfaces against
`reminders_list`, `calendar_events`, or `findConflicts` on a large vault or
wide date range. Then: add a generic `withAsyncTimeout` helper, thread
`softTimeoutMs` through, reuse `OutputOptions.emit(...,timedOut:,...)` for
the warning envelope.

### Lift Outcome<T> into a shared bridge module (`pippin-a9v`) — P3

`Outcome<T>` (results + timedOut flag, back-compat decoder) is duplicated
across `NotesBridge` and `ContactsBridge`. Lifting requires resolving the
shape mismatch: NotesBridge.Outcome has a custom `Decodable` init for JXA
JSON; ContactsBridge.Outcome is pure Swift no-Decodable. Revisit when a
third bridge picks up the pattern — duplication isn't biting yet.

### Extract MailMessageEmitter helper (`pippin-eil`) — P4

`MailCommand.Search/List` and `MailActivityCommand` each define near-identical
`timedOutHint` strings + `emitMessages` helpers. Hint text and filter hash
genuinely differ per call site, and unifying adds indirection for ~15 saved
lines per command. Revisit when a fourth caller needs the same plumbing or a
new bridge method needs `timedOut` surfacing.

---

## Shipped (v0.16.0 → v0.22.0)

> For v0.23.0 onward, [`CHANGELOG.md`](../CHANGELOG.md) is the authoritative shipped record — the per-version log below is kept only for the v0.16–v0.22 era.

### v0.22.x — Concurrency & MCP polish

- Cooperative-thread fixes (`pippin-3re`, `pippin-f1n`, `pippin-ka7`) —
  `process.waitUntilExit`, `DispatchSemaphore.wait`, and
  `sendSynchronousRequest` no longer stall the cooperative pool when called
  from async commands. New `detachBlocking` helper.
- MCP-aware AI request budget (`pippin-5et`) — Ollama 2s preflight,
  `PIPPIN_MCP=1` shortens AI timeouts to 50s under MCP.
- Mail bridge soft-timeout fixes (`pippin-kis`, `pippin-tl8`) — `mail_list`
  and `mail_activity` no longer time out under MCP clients.
- Notes JXA pre-loop budget guard (`pippin-4as`) — large vaults emit
  `timedOut: true` partial results instead of busting the ScriptRunner cap.
- BatchBudget (`pippin-55e`) — `memos export/transcribe --all` bound to 50s
  under MCP; partial results + warning instead of mid-batch SIGKILL.
- Unified `MailBridge.ScanMeta`/`ScanResponse`/`ScanOutcome` (`pippin-660`).
- `pippin doctor --latency` Mail bridge probes (`pippin-11e`).
- Surfaced previously-silent `outcome.timedOut` in DigestCommand,
  MailAICommand, StatusCommand (`pippin-6tg`, `pippin-53p`).

### v0.20.x — Bridge & agent envelope

- Agent-mode envelope v1 — every `--format agent` response carries
  `{v, status, duration_ms, data|error}`.
- ContactsBridge with `Outcome<T>` soft-timeout pattern.
- `pippin do` — natural-language plan-and-execute over the MCP tool registry.
- `pippin job` — detached background subprocesses with status/poll/wait.
- `pippin batch` — parallel sub-command dispatch in one call.

### v0.18.x — Apple app coverage

- Mail watch mode (`pippin-lhh`) — newline-delimited JSON event stream.
- Mail triage rules engine (`pippin-ace`) — persistent rules in
  `~/.config/pippin/triage-rules.json`.
- Calendar smart-create + conflict detection (`pippin-arr`).
- Reminders smart-create (`pippin-mfe`).
- REPL tab completion (`pippin-ypg`).
- Contacts read support — `search`, `show`, `groups` (write deferred,
  `pippin-83z`).

### v0.16.0

- SKILL.md agent discovery manifest (`pippin-7rd`)
- `pippin status` introspection command (`pippin-4eg`)
- `runConcurrently` refactor (`pippin-jgq`)
- Universal `--json` / `--format agent` on all commands (`pippin-6k6`)
- Session state persistence (`pippin-mqt`)
