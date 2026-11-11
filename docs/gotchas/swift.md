# Swift 6 / ArgumentParser / Agent-Output Gotchas

Load when editing `pippin/Commands/`, adding subcommands, touching concurrency, or changing output formats.

## Default to `internal` visibility

`PippinLib` is the only module with logic; `pippin-entry` only holds `@main`. Use `public` only if a type is consumed outside PippinLib: currently nothing is. Tests reach internal helpers via `@testable import PippinLib`.

## REPL shell architecture (`ShellCommand.swift`)

- `ShellCommand` is `AsyncParsableCommand` in PippinLib; bare `pippin` defaults to REPL in `Pippin.main()`.
- Parser injection: `ShellCommand.parser` is a `nonisolated(unsafe)` static var set by `Pippin.main()` to `Pippin.parseAsRoot(_:)`: avoids circular dependency between PippinLib and executable target.
- `--format` session flag: when set, injected into every command's args before parsing.
- Non-interactive (pipe) mode: detected via `isatty(fileno(stdin))`; no prompt, no banner.
- `ExitCode` errors are caught silently (like `CleanExit`): commands that exit non-zero don't kill the REPL.
- `shellSplit(_:)` handles single/double quote parsing for command lines.
- Session state: `SessionManager` persists active account, last-used IDs, and command history to `~/.config/pippin/session.json`. REPL auto-injects `--account` from session context for mail commands. Built-in commands: `use <account>`, `context`, `history`.

## ArgumentParser gotchas

**`ValidationError` from `run()` shows the full usage-help footer**: use a custom `LocalizedError` struct for runtime errors instead.

**Async `main()` override must cast before dispatching:**

```swift
if var asyncCommand = command as? AsyncParsableCommand {
    try await asyncCommand.run()
} else {
    try command.run()
}
```

Calling `try await command.run()` directly on a `ParsableCommand` existential invokes the sync `run()`, which prints help for command-groups instead of running subcommands.

**`--format` collision with `OutputOptions`:** Commands using `@OptionGroup var output: OutputOptions` must NOT also declare `@Option var format`: ArgumentParser throws "Multiple arguments named --format" at parse time. Rename the command-specific option (e.g. `--transcription-format`).

**Cross-cutting flags → a shared `ParsableArguments` group, not copy-paste.** When the same flag(s) recur across multiple subcommands, declare them once in a `ParsableArguments` struct and pull it in with `@OptionGroup`: the established groups are `OutputOptions` (`--format`/`--fields`), `PaginationOptions` (`--cursor`/`--page-size`), and `ContactResolutionOptions` (`--no-contacts`/`--contacts`, which also owns the resolution-precedence rule via `shouldResolve(config:)`). The flags still parse identically at the CLI (ArgumentParser flattens them). Put any decision logic the flags drive on the group itself, not on an unrelated type. pippin-wyn removed 12 duplicated `--contacts` declarations this way.

**Nested subcommand struct placement:** When inserting a new `ParsableCommand` subcommand into an existing parent, the Edit `old_string` must start *before* the parent's closing `}`: replacing text that begins after the `}` puts the struct at file scope (compiles but is not a subcommand of the parent).

## Agent output format

Commands conform to `AgentCommand` and return an `AgentResult` from `execute()`; `run()` renders it through `OutputOptions.render(_:)`, and the in-process MCP path calls `execute()` directly. Never print from a command. `render` uses `JSONEncoder()` with no formatting options (compact). Notes `show` uses `NoteAgentView` (excludes the HTML body field).

**Agent error interception: `ExitCode` passthrough:** Both `CleanExit` (--help/--version) AND `ExitCode` (e.g. `throw ExitCode(1)` from `DoctorCommand`) must pass through to `Pippin.exit(withError:)`, not be treated as agent errors. `--help` and `--version` also pass through: check `Pippin.exitCode(for: error) == .success` as well, or they become error envelopes with exit 2.

## Paginated agent output (pippin-37az)

**A `Page` must go through `AgentResult.page`/`emitPage`, never the plain `AgentResult(...)` initializer or `emit`.** Envelope v3 keeps `data` the same type whether or not a pagination flag was passed: the items ARE the `data`, and the cursor is hoisted to a top-level `next_cursor`. Handing a `Page` to the plain printer re-nests `{items, next_cursor}` inside `data`: the v2 bug, where a consumer iterating `.data` silently iterated dict keys and got the string `"items"` instead of rows.

Two guard designs were tried and REJECTED before settling on a lint (`scripts/lint-paginated-emit.py`, wired into `make ci` and `.forgejo/workflows/ci.yaml`):

- **An `@available(*, unavailable)` `Page` overload does NOT win overload resolution.** Swift prefers the *available* generic `some Encodable` overload, so the plain call with a `Page` still compiled clean. An unavailable overload is only a guard when it's the sole candidate; as a more-specialized sibling of a viable generic it is dead code. Verified by building a deliberately regressed call site.
- **The CLI integration sweep can't cover it.** Every paginated command is permission-gated, and TCC grants attach to the *launching* process, so inside `swift test` only 2 of the 6 are reachable: a regressed call site passed the sweep with the wrong shape on the wire. The sweep is still worth keeping (it asserts on whatever the environment can reach), but it is not the gate.

**`--fields` projection is automatic (pippin-sq6, pippin-w5j3).** `OutputOptions.render(_:)` applies the parsed `--fields` to every `AgentResult`, so commands do not thread it. An explicit `fields:` on `AgentResult` overrides it. With no `--fields`, an array of an `EssentialRow` type projects to `essentialFields`; `--fields all` returns whole rows, and `AgentResult(untrimmed: true)` opts a command out. Single-object answers (`show`) stay whole. A requested field present on no row adds a warning.

## Cooperative-thread blocking: use `detachBlocking`

Swift 6 runs `async` functions on a fixed-size cooperative thread pool. Calling sync work that **blocks the calling thread** from inside an `async` command starves that pool: under any concurrent usage (notably `pippin mcp-server`, which fans out commands per connection) the entire process can wedge.

The blocking call sites in pippin:
- `process.waitUntilExit()` (every `*Bridge` that spawns a subprocess: AudioBridge, BrowserBridge, MailBridge via ScriptRunner, AIProviderFactory.tryGetSecret)
- `DispatchSemaphore.wait()` (every `sendSynchronousRequest` in `pippin/AIProvider/AIProvider.swift`, plus `gatherRemindersStatus` in StatusCommand)
- `DispatchGroup.wait()` (`runConcurrently` in `pippin/MailAIBridge/ConcurrencyUtils.swift`)

The fix is mechanical: wrap any sync helper called from an async command in `detachBlocking { ... }` (defined in `pippin/DetachBlocking.swift`):

```swift
public mutating func run() async throws {
    let result = try await detachBlocking {
        try SomeBridge.someBlockingCall(args)
    }
}
```

`detachBlocking` has both throwing and non-throwing overloads. It hops to `DispatchQueue.global(qos: .userInitiated)` through a checked continuation. Do not reimplement it as `Task.detached`: a detached task still runs on the cooperative pool, so it parks a pool thread just the same (pippin-vb4a).

**Closure capture gotcha:** the closure passed to `detachBlocking` is `@Sendable @escaping`, so referencing `self.foo` from a `mutating func` on a struct will fail with "mutable capture of 'inout' parameter 'self' is not allowed in concurrently-executing code." Rebind to a local `let foo = self.foo` before the closure (or use a capture list `[foo]`).

**Tests with retry counters:** if a test counts retries via `var calls = 0` captured in the operation closure, that captured `var` becomes invalid once the helper hops through `detachBlocking`. Use a `final class CallCounter: @unchecked Sendable { var count = 0 }` reference type: retries are still serialized so `@unchecked` is safe.

`AIProviderFactory.tryGetSecret` and `JobRunnerInternalCommand` are deliberately left unwrapped: get-secret is fast (~100ms) and JobRunnerInternal is the only thing happening in its process.

## Swift 6 Sendable auto-synthesis + closure fields

When a struct is stored in a `static let`, Swift 6 requires it to be `Sendable`. Auto-synthesis works only if all stored properties are `Sendable`: **including closure types, which need the `@Sendable` attribute explicitly**. Error surfaces as "static property 'X' is not concurrency-safe" pointing at the `static let`, not at the offending closure field. Fix at the field (`let buildArgs: @Sendable (JSONValue?) throws -> [String]`), not the struct declaration: SwiftFormat will then strip the redundant `: Sendable` conformance line, which is fine because auto-synthesis is in effect.

## GRDB `SQL` type inference trap

In files that import GRDB, `SQL` is `ExpressibleByStringInterpolation`: string interpolation inside closures near array builders causes wrong type inference. Fix: use explicit `let x: String = ...` type annotations.

## Test / dev-tooling traps

**Draining a subprocess pipe: read BEFORE `waitUntilExit()`, concurrently.** Reading after the wait deadlocks the instant a child writes more than the ~64KB pipe buffer: child blocks writing, parent blocks waiting, forever. `CLIIntegrationTests.runProcess` had this latently; it detonated when `mcp-server --list-tools` crossed 64KB at 76 tools (66,752 B), wedging `make ci` with **no failure and no output**. Copy the `DispatchGroup` + two `nonisolated(unsafe) var` drain in `MCPServerRuntime.runChild` / `AIProviderFactory.tryGetSecret`. Tell: a "slow" test run that never finishes: `sample <xctest-pid>` names the real test, since the last flushed log line points at an unrelated suite.

**`CLIIntegrationTests` version assertion:** `Tests/PippinTests/CLIIntegrationTests.swift` uses `PippinVersion.version` dynamically: no manual update needed on version bumps.

**`BuiltInTemplates.all` count is hardcoded in tests:** Adding any template breaks three assertions in `Tests/PippinTests/TemplateTests.swift`: bump `testBuiltInTemplatesCount`, `testAllTemplatesReturnsBuiltIns`, and `testUserTemplatePlainContent` counts by 1 each.

**`extractJSON(from:)` is `internal`:** Top-level function in `pippin/Commands/CalendarCommand.swift`. Access is `internal` (not private): callable from any PippinLib file without importing or redeclaring.

**`// MARK:` inside function bodies is a no-op:** Xcode's jump bar and SwiftFormat only index `// MARK:` at type/file scope. In-function MARKs look like section headers but add nothing: use plain `//` comments for inline section breaks.

**mlx-audio has no `__version__` attribute:** `import mlx_audio; mlx_audio.__version__` raises `AttributeError`. Use `from importlib.metadata import version; version('mlx-audio')`: what `AudioBridge.installedMLXAudioVersion` already does.

**Unbounded user input is the recurring crash class:** `@Option Int` (limit/page-size/calendar-days) → clamp at the bridge boundary; `Int64(Double)` and `n + 1` trap at the extremes; `Calendar.date(byAdding:)` returns nil for huge values. Guard-let, never force-unwrap a user-influenced value. See `MessagesDatabase.clampLimit`, `Cursor.resolve`, `JSONValue.intValue`, `parseRange`.

**Fixed-format dates need POSIX + Gregorian:** set `DateFormatter.locale = Locale(identifier: "en_US_POSIX")` and extract components via `Calendar(identifier: .gregorian)` (not `.current`): a non-Gregorian device calendar (Buddhist/Japanese) otherwise misparses `--since` or renders the wrong era year (2567 for 2024).

**Multi-format date parsing: most-specific pattern first:** when trying a list of `DateFormatter` patterns, order with-seconds before minute-only and datetime before date-only. `DateFormatter` matches a *prefix*, so a `yyyy-MM-dd` pattern will happily parse `2026-06-04` out of `2026-06-04 12:30` and silently drop the time if it's tried first. See `parseCalendarDate` (pippin-3gp).

**Bounding a *synchronous* framework call** (e.g. `EKEventStore.events(matching:)`, which blocks the caller: unlike callback-based `fetchReminders`): run it on `DispatchQueue.global().async`, wait on a `DispatchSemaphore` with `.now() + .seconds(N)`, and return `[]` on timeout (never read the result the abandoned worker is still mutating). Capture the non-Sendable arg (`NSPredicate`) via a `nonisolated(unsafe) let` to satisfy the `@Sendable` closure. See `CalendarBridge.fetchEventsSync` vs `RemindersBridge.fetchRemindersSync` (pippin-mgg).

**GRDB `row["col"]` TRAPS on NULL:** decode system-DB columns optionally (`row["col"] as T?`) with a fallback. Apple's Voice Memos/Messages DBs store NULLs (e.g. ZPATH for a not-yet-downloaded recording); one NULL row otherwise crashes the whole list.

**Deleting enum cases: grep the bare `.caseName` too**, not just `Type.caseName`: Swift's implicit member syntax (`[.notAvailable, .timeout]`, `case .timeout:`) won't match a `Type\.` grep pattern, and tests commonly enumerate cases that way. A missed hit costs a full CI round trip (~3 min; TranscriberTests, 2026-07-18).

## OpenAI-compat native JSON (`jsonMode` / `response_format`, pippin-us2)

Provider behavior for `AICompletionOptions(jsonMode: true)`: **Ollama** adds `format: "json"` (on by default: safe for `gemma4`; thinking models are served via the OpenAI-compat path, not Ollama). **Claude** is a no-op (no native mode). **OpenAI-compat** sends `response_format: {"type":"json_object"}` only when `ai.openai.structuredOutputs: true` **and** the prompt contains the word "json" (`OpenAIProvider.mentionsJSON`: real OpenAI 400s the request without it).

Historical evidence, verified against a local MLX-based OpenAI-compatible server running Qwen3.6-35B-A3B-4bit (2026-06-12): it accepts `response_format: json_object` and returns clean JSON with `finish_reason: stop`: `response_format` alone suppresses Qwen3.6's default thinking output. The current Pippin local default is Qwen3.8-27B-oQ4e-mtp, so repeat this behavior check if changing its structured-output path. The `chat_template_kwargs: {enable_thinking: false}` knob is NOT needed and is not sent, since it would 400 real OpenAI. Without `response_format`, the same model emits "Here's a thinking process…" prose and truncates at `finish_reason: length`. All consumers still strip fences (`stripAIResponseJSON`) and `do` self-repairs, so jsonMode is a best-effort enhancement, not a correctness dependency.

## Apple on-device backends (pippin-edjh)

- **NaturalLanguage embeddings were rejected.** `NLEmbedding.sentenceEmbedding` and mean-pooled `NLContextualEmbedding` both ranked unrelated mail above the obvious match for plain queries; neither is a retrieval model.
- **Foundation Models ships as the experimental `apple` completion provider (pippin-npqt).** `pippin/AIProvider/AppleFoundationModelsProvider.swift` holds every FoundationModels call. A free-form JSON prototype returned malformed JSON for 2 of 12 messages in `mail triage`, so `jsonMode` calls use guided generation: `LanguageModelSession(model: .default, instructions:)` then `respond(to:schema:includeSchemaInPrompt:options:)`, and the reply is `response.content.jsonString` (a `GeneratedContent`). Free text uses `respond(to:options:)` and `.content`.
- **Schemas come from the features, not from JSON Schema.** No feature had a schema, so `AICompletionOptions.schema` takes a small `AIOutputSchema` that each JSON feature supplies next to the type it decodes, and `dynamicSchema(_:name:)` converts it to `DynamicGenerationSchema` (`init(type: String.self)`, `init(name:anyOf: [String])`, `init(arrayOf:minimumElements:maximumElements:)`, `init(name:properties:)` with `Property(name:schema:isOptional:)`), wrapped by `GenerationSchema(root:dependencies: [])`. Object and choice names derive from the field path because `GenerationSchema` throws `SchemaError.duplicateType` on a repeated name. `GenerationSchema` is `Codable` and encodes as JSON Schema (`$defs`, `enum`, `minItems`), which is what the conversion tests assert against. Triage pins `compoundId` to the batch's IDs and the array length to the batch size, which is what made coverage 100%. The `do` planner sends no schema: its step args are free-form per tool.
- **Availability and context.** `SystemLanguageModel.default.availability` is `.available` or `.unavailable(reason)` with `deviceNotEligible`, `appleIntelligenceNotEnabled`, `modelNotReady` (non-frozen, so `@unknown default`). `SystemLanguageModel.default.contextSize` is 8,192 on macOS 27.2 (back-deployed; it returns 4,096 before 27). These map to `AIProviderError.modelUnavailable` (code `not_available`, exit 4), `.guardrailRefusal` and `.contextExceeded(limit:tokens:)`.
- **macOS 27.2 still throws the deprecated error type.** macOS 27 added `LanguageModelError.contextSizeExceeded` (with `contextSize` and `tokenCount`) and deprecated `LanguageModelSession.GenerationError`, but a `pippin do` prompt over the window came back as `GenerationError.exceededContextWindowSize`, which carries no size. `mapError` handles both and fills the limit from `contextSize`.
- **Triage splits on overflow.** `TriageEngine.triageBatch` catches `contextExceeded` and halves the batch until each request fits, merging the halves. The split is unit-tested with a fake provider; the real 12-message run was not instrumented to show whether it fired. Nothing else chunks.
- **Requalification on real mail (2026-11-10, 12 inbox messages, `--no-rules`).** Valid JSON and 12 of 12 messages covered on every run, about 28 s wall clock against about 27 s for the OpenAI-compatible baseline. Category agreement with the baseline was 5 of 12 (42%) on two runs, below the 75% bar, so `apple` stays experimental. The baseline agreed with itself on only 7 of 12 across two runs; `apple` agreed with itself on 12 of 12. `reminders smart-create --dry-run` produced a valid spec but resolved "by Friday" to the wrong date where the baseline got it right. `mail show --summarize` worked.
- **Weak linking.** The package targets macOS 15; SpeechAnalyzer symbols carry macOS 26 availability, so the Speech load command is weak automatically. FoundationModels does not exist on macOS 15, so both the provider and its test file use `@_weakLinked import FoundationModels` and gate calls with `#available(macOS 26, *)`. `otool -L .build/debug/pippin` shows both Speech and FoundationModels as `weak`.
- **No TCC prompt for SpeechAnalyzer.** It ran from an unsigned scratch binary with `SFSpeechRecognizer.authorizationStatus()` still `notDetermined`. `AssetInventory.status` reported `supported` while `SpeechTranscriber.installedLocales` already listed `en_US`; `assetInstallationRequest(supporting:)` returning nil is the reliable "ready" signal.
- **`waitForAsync` needs free pool threads.** Sync `Transcriber`s call async Apple APIs through `waitForAsync` in pippin/AsyncBridge.swift. It blocks its caller while the async body runs on the cooperative pool. A task executor preference does not help, because after `Task.sleep` or a framework continuation the task resumes on the global pool. The `--all` task groups in `memos transcribe`, `memos export`, and `summarize` therefore hop to Dispatch with `detachBlocking` first. `AsyncBridgeTests` reproduces the deadlock, which completed 0 of 36 calls without the hop, and again when `detachBlocking` was still a `Task.detached` (pippin-vb4a).
- **Embedding vectors are model-specific.** `EmbeddingProvider.storeKey` goes in the index row's `model` column. Ollama keeps the bare model name so pre-edjh indexes stay current; other backends use `<provider>:<model>`. `SemanticSearch` filters by key before ranking, and nothing should rank across keys.
- **Doctor checks read config through a parameter.** `runAllChecks(config:)` and `backendChecks(config:probe:)` take the config and a `BackendProbe`, so tests stay independent of `~/.config/pippin/config.json` and need no network. `DoctorTests.cachedChecks` passes `config: nil`.
