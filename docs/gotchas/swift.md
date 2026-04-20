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

**Nested subcommand struct placement:** When inserting a new `ParsableCommand` subcommand into an existing parent, the Edit `old_string` must start *before* the parent's closing `}` — replacing text that begins after the `}` puts the struct at file scope (compiles but is not a subcommand of the parent).

## Agent output format

`OutputOptions` has `.agent` case and `isAgent` property. `printAgentJSON<T>()` uses `JSONEncoder()` with no formatting options (compact). Notes `show` in agent mode uses `NoteAgentView` (excludes HTML body field).

**Agent error interception — `ExitCode` passthrough:** Both `CleanExit` (--help/--version) AND `ExitCode` (e.g. `throw ExitCode(1)` from `DoctorCommand`) must pass through to `Pippin.exit(withError:)`, not be treated as agent errors. Check `error is CleanExit || error is ExitCode` before the agent branch.

## `TextFormatter.actionResult` dict overload

Use `TextFormatter.actionResult(success:action:details:[String:String])` — never hand-roll `.map { "\($0.key)=\($0.value)" }.sorted().joined()` inline.

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
