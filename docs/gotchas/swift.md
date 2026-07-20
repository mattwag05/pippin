# Swift 6 / ArgumentParser / Agent-Output Gotchas

Load when editing `pippin/Commands/`, adding subcommands, touching concurrency, or changing output formats.

## Default to `internal` visibility

`PippinLib` is the only module with logic; `pippin-entry` only holds `@main`. Use `public` only if a type is consumed outside PippinLib — currently nothing is. Tests reach internal helpers via `@testable import PippinLib`.

## REPL shell architecture (`ShellCommand.swift`)

- `ShellCommand` is `AsyncParsableCommand` in PippinLib; bare `pippin` defaults to REPL in `Pippin.main()`.
- Parser injection: `ShellCommand.parser` is a `nonisolated(unsafe)` static var set by `Pippin.main()` to `Pippin.parseAsRoot(_:)` — avoids circular dependency between PippinLib and executable target.
- `--format` session flag: when set, injected into every command's args before parsing.
- Non-interactive (pipe) mode: detected via `isatty(fileno(stdin))`; no prompt, no banner.
- `ExitCode` errors are caught silently (like `CleanExit`) — commands that exit non-zero don't kill the REPL.
- `shellSplit(_:)` handles single/double quote parsing for command lines.
- Session state: `SessionManager` persists active account, last-used IDs, and command history to `~/.config/pippin/session.json`. REPL auto-injects `--account` from session context for mail commands. Built-in commands: `use <account>`, `context`, `history`.

## ArgumentParser gotchas

**`ValidationError` from `run()` shows the full usage-help footer** — use a custom `LocalizedError` struct for runtime errors instead.

**Async `main()` override must cast before dispatching:**

```swift
if var asyncCommand = command as? AsyncParsableCommand {
    try await asyncCommand.run()
} else {
    try command.run()
}
```

Calling `try await command.run()` directly on a `ParsableCommand` existential invokes the sync `run()`, which prints help for command-groups instead of running subcommands.

**`--format` collision with `OutputOptions`:** Commands using `@OptionGroup var output: OutputOptions` must NOT also declare `@Option var format` — ArgumentParser throws "Multiple arguments named --format" at parse time. Rename the command-specific option (e.g. `--transcription-format`).

**Cross-cutting flags → a shared `ParsableArguments` group, not copy-paste.** When the same flag(s) recur across multiple subcommands, declare them once in a `ParsableArguments` struct and pull it in with `@OptionGroup` — the established groups are `OutputOptions` (`--format`/`--fields`), `PaginationOptions` (`--cursor`/`--page-size`), and `ContactResolutionOptions` (`--no-contacts`/`--contacts`, which also owns the resolution-precedence rule via `shouldResolve(config:)`). The flags still parse identically at the CLI (ArgumentParser flattens them). Put any decision logic the flags drive on the group itself, not on an unrelated type. pippin-wyn removed 12 duplicated `--contacts` declarations this way.

**Nested subcommand struct placement:** When inserting a new `ParsableCommand` subcommand into an existing parent, the Edit `old_string` must start *before* the parent's closing `}` — replacing text that begins after the `}` puts the struct at file scope (compiles but is not a subcommand of the parent).

## Agent output format

`OutputOptions` has `.agent` case and `isAgent` property. `printAgentJSON<T>()` uses `JSONEncoder()` with no formatting options (compact). Notes `show` in agent mode uses `NoteAgentView` (excludes HTML body field).

**Agent error interception — `ExitCode` passthrough:** Both `CleanExit` (--help/--version) AND `ExitCode` (e.g. `throw ExitCode(1)` from `DoctorCommand`) must pass through to `Pippin.exit(withError:)`, not be treated as agent errors. Check `error is CleanExit || error is ExitCode` before the agent branch.

**`--fields` projection is automatic on `emit`/`printAgent` (pippin-sq6).** Both methods live on `OutputOptions`, so they default the projection list to the parsed `--fields` (`self.fields`) — **every** `output.printAgent(x)` / `output.emit(x)` call honors `--fields` with no threading. An explicit `fields:` argument still overrides (used only where a command projects a different shape, e.g. Calendar's hand-rolled json branch). Don't re-add `fields: FieldProjection.parse(output.fields)` to a `printAgent`/`emit` call — it's the default now (redundant but harmless). The per-command `isJSON` branches that pre-date this still exist for reminders/calendar/notes (they build paginated `{items,next_cursor}` dicts by hand and surface their own stderr timeout warning); those keep computing a `fieldList` because they also feed it to `jsonData(fields:)` and the bridges. All field-projection logic is consolidated onto `FieldProjection` — add new logic there, not in a copy. Rules: array → project each element; object with `items` array → project items, keep siblings; plain object → project its keys; scalar → unchanged.

## `TextFormatter.actionResult` dict overload

Use `TextFormatter.actionResult(success:action:details:[String:String])` — never hand-roll `.map { "\($0.key)=\($0.value)" }.sorted().joined()` inline.

## Cooperative-thread blocking — use `detachBlocking`

Swift 6 runs `async` functions on a fixed-size cooperative thread pool. Calling sync work that **blocks the calling thread** from inside an `async` command starves that pool — under any concurrent usage (notably `pippin mcp-server`, which fans out commands per connection) the entire process can wedge.

The blocking call sites in pippin:
- `process.waitUntilExit()` (every `*Bridge` that spawns a subprocess: AudioBridge, BrowserBridge, MailBridge via ScriptRunner, AIProviderFactory.tryGetSecret)
- `DispatchSemaphore.wait()` (every `sendSynchronousRequest` in `pippin/AIProvider/AIProvider.swift`, plus `gatherRemindersStatus` in StatusCommand)
- `DispatchGroup.wait()` (`runConcurrently` in `pippin/MailAIBridge/ConcurrencyUtils.swift`)

The fix is mechanical — wrap any sync helper called from an async command in `detachBlocking { ... }` (defined in `pippin/DetachBlocking.swift`):

```swift
public mutating func run() async throws {
    let result = try await detachBlocking {
        try SomeBridge.someBlockingCall(args)
    }
}
```

`detachBlocking` has both throwing and non-throwing overloads. Default `priority: .userInitiated` matches every existing call site (CLI commands the user is actively waiting on); override per-call only for genuine background work.

**Closure capture gotcha:** the closure passed to `detachBlocking` is `@Sendable @escaping`, so referencing `self.foo` from a `mutating func` on a struct will fail with "mutable capture of 'inout' parameter 'self' is not allowed in concurrently-executing code." Rebind to a local `let foo = self.foo` before the closure (or use a capture list `[foo]`).

**Tests with retry counters:** if a test counts retries via `var calls = 0` captured in the operation closure, that captured `var` becomes invalid once the helper hops through `detachBlocking`. Use a `final class CallCounter: @unchecked Sendable { var count = 0 }` reference type — retries are still serialized so `@unchecked` is safe.

`AIProviderFactory.tryGetSecret` and `JobRunnerInternalCommand` are deliberately left unwrapped — get-secret is fast (~100ms) and JobRunnerInternal is the only thing happening in its process.

## Swift 6 Sendable auto-synthesis + closure fields

When a struct is stored in a `static let`, Swift 6 requires it to be `Sendable`. Auto-synthesis works only if all stored properties are `Sendable` — **including closure types, which need the `@Sendable` attribute explicitly**. Error surfaces as "static property 'X' is not concurrency-safe" pointing at the `static let`, not at the offending closure field. Fix at the field (`let buildArgs: @Sendable (JSONValue?) throws -> [String]`), not the struct declaration — SwiftFormat will then strip the redundant `: Sendable` conformance line, which is fine because auto-synthesis is in effect.

## GRDB `SQL` type inference trap

In files that import GRDB, `SQL` is `ExpressibleByStringInterpolation` — string interpolation inside closures near array builders causes wrong type inference. Fix: use explicit `let x: String = ...` type annotations.

## Test / dev-tooling traps

**`CLIIntegrationTests` version assertion:** `Tests/PippinTests/CLIIntegrationTests.swift` uses `PippinVersion.version` dynamically — no manual update needed on version bumps.

**`BuiltInTemplates.all` count is hardcoded in tests:** Adding any template breaks three assertions in `Tests/PippinTests/TemplateTests.swift` — bump `testBuiltInTemplatesCount`, `testAllTemplatesReturnsBuiltIns`, and `testUserTemplatePlainContent` counts by 1 each.

**`extractJSON(from:)` is `internal`:** Top-level function in `pippin/Commands/CalendarCommand.swift`. Access is `internal` (not private) — callable from any PippinLib file without importing or redeclaring.

**`// MARK:` inside function bodies is a no-op:** Xcode's jump bar and SwiftFormat only index `// MARK:` at type/file scope. In-function MARKs look like section headers but add nothing — use plain `//` comments for inline section breaks.

**mlx-audio has no `__version__` attribute:** `import mlx_audio; mlx_audio.__version__` raises `AttributeError`. Use `from importlib.metadata import version; version('mlx-audio')` — what `AudioBridge.installedMLXAudioVersion` already does.

**Unbounded user input is the recurring crash class:** `@Option Int` (limit/page-size/calendar-days) → clamp at the bridge boundary; `Int64(Double)` and `n + 1` trap at the extremes; `Calendar.date(byAdding:)` returns nil for huge values. Guard-let, never force-unwrap a user-influenced value. See `MessagesDatabase.clampLimit`, `Cursor.resolve`, `JSONValue.intValue`, `parseRange`.

**Fixed-format dates need POSIX + Gregorian:** set `DateFormatter.locale = Locale(identifier: "en_US_POSIX")` and extract components via `Calendar(identifier: .gregorian)` (not `.current`) — a non-Gregorian device calendar (Buddhist/Japanese) otherwise misparses `--since` or renders the wrong era year (2567 for 2024).

**Multi-format date parsing — most-specific pattern first:** when trying a list of `DateFormatter` patterns, order with-seconds before minute-only and datetime before date-only. `DateFormatter` matches a *prefix*, so a `yyyy-MM-dd` pattern will happily parse `2026-06-04` out of `2026-06-04 12:30` and silently drop the time if it's tried first. See `parseCalendarDate` (pippin-3gp).

**Bounding a *synchronous* framework call** (e.g. `EKEventStore.events(matching:)`, which blocks the caller — unlike callback-based `fetchReminders`): run it on `DispatchQueue.global().async`, wait on a `DispatchSemaphore` with `.now() + .seconds(N)`, and return `[]` on timeout (never read the result the abandoned worker is still mutating). Capture the non-Sendable arg (`NSPredicate`) via a `nonisolated(unsafe) let` to satisfy the `@Sendable` closure. See `CalendarBridge.fetchEventsSync` vs `RemindersBridge.fetchRemindersSync` (pippin-mgg).

**GRDB `row["col"]` TRAPS on NULL:** decode system-DB columns optionally (`row["col"] as T?`) with a fallback. Apple's Voice Memos/Messages DBs store NULLs (e.g. ZPATH for a not-yet-downloaded recording); one NULL row otherwise crashes the whole list.

**Deleting enum cases — grep the bare `.caseName` too**, not just `Type.caseName`: Swift's implicit member syntax (`[.notAvailable, .timeout]`, `case .timeout:`) won't match a `Type\.` grep pattern, and tests commonly enumerate cases that way. A missed hit costs a full ~12-min CI round trip (TranscriberTests, 2026-07-18).

## OpenAI-compat native JSON (`jsonMode` / `response_format`, pippin-us2)

Provider behavior for `AICompletionOptions(jsonMode: true)`: **Ollama** adds `format: "json"` (on by default — safe for `gemma4`; thinking models are served via the OpenAI-compat path, not Ollama). **Claude** is a no-op (no native mode). **OpenAI-compat** sends `response_format: {"type":"json_object"}` only when `ai.openai.structuredOutputs: true` **and** the prompt contains the word "json" (`OpenAIProvider.mentionsJSON` — real OpenAI 400s the request without it).

Verified against a local MLX-based OpenAI-compatible server running Qwen3.6-35B-A3B-4bit (2026-06-12): it accepts `response_format: json_object` and returns clean JSON with `finish_reason: stop` — `response_format` alone suppresses Qwen3.6's default thinking output. The `chat_template_kwargs: {enable_thinking: false}` knob is NOT needed and is not sent, since it would 400 real OpenAI. Without `response_format`, the same model emits "Here's a thinking process…" prose and truncates at `finish_reason: length`. All consumers still strip fences (`stripAIResponseJSON`) and `do` self-repairs, so jsonMode is a best-effort enhancement, not a correctness dependency.
