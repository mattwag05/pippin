# MCP Server Patterns

Load when editing `pippin/MCP/`, `McpServerCommand.swift`, or `ToolRegistry.swift`. For usage and wiring, see [mcp-server.md](../mcp-server.md).

## Never `print()` inside the mcp-server command

stdout is reserved for JSON-RPC framing — any stray print corrupts the transport. Diagnostics go to stderr via `MCPStdioWriter.log()`.

## Tool argv must always include `--format agent`

The child `pippin` process produces compact agent JSON that the server wraps verbatim as `content[0].text`. A lint test (`testAllArgvEndWithFormatAgent`) enforces this across the registry.

## Exit-code-to-error mapping

When the child exits non-zero, stdout contains an `AgentError` JSON (`{"error":{"code":"snake_case","message":"..."}}`) from `printAgentError`. The server passes this through as the tool result text with `isError: true`. Do NOT convert it to a JSON-RPC-level `-326xx` error — those are reserved for protocol-level failures (unknown method, malformed request, launch failure).

## ArgumentParser error messages in agent mode (pippin-kzi)

ArgumentParser wraps thrown `ValidationError`s in non-public `CommandError`/`ValidationError` whose `localizedDescription` is the opaque "(ArgumentParser.CommandError error 1.)" — so `--format agent` (and every MCP tool call) lost the actionable text humans see. `AgentError.from` recovers it via `AgentError.argumentParserMessage`, an injected `{ Pippin.message(for: $0) }` hook set in `Pippin.main()` (same injection pattern as `ShellCommand.parser`), gated on `String(reflecting: type(of: error)).hasPrefix("ArgumentParser.")`. Don't replace the hook with `error.localizedDescription` — it regresses to the opaque form.

## Binary path resolution

`MCPServerRuntime.resolvePippinPath()` uses `CommandLine.arguments[0]` + `realpath` so the child is the exact same binary as the parent, not whatever `pippin` resolves to on `$PATH`. This matters when pippin is run via a symlink (Homebrew shim).

## Hard timeout in `runChild` (60s default)

`MCPServerRuntime.runChild` enforces a hard timeout (`defaultChildTimeoutSeconds = 60`) using SIGTERM → SIGKILL+2s, mirroring `ScriptRunner.run`. Without it, a wedged child (e.g. `osascript` stuck on an unresponsive Mail.app) blocks the JSON-RPC loop forever. On expiry the runtime throws `MCPServerRuntimeError.childTimedOut(seconds:)`, and the dispatcher surfaces it as an `isError: true` MCPToolCallResult (tool-level failure, not protocol-level).

**Bridge tools must self-bound well below 60s.** Search uses a 22s JXA-loop soft cap (`softTimeoutMs`) and a 30s ScriptRunner cap; on soft-timeout it returns partial results plus `meta.timedOut=true` and an envelope-level `warnings: [...]` advisory. The MCP hard timeout exists only as a last-resort failsafe.

## Optional `warnings` in agent envelope

`AgentOkEnvelope` carries an optional top-level `warnings: [String]?` (omitted when nil/empty). Use `output.printAgent(payload, warnings: [...])` to surface non-fatal advisories alongside the data. Existing consumers reading only `.data` are unaffected.

## ToolRegistry argv must be ArgumentParser-safe

Bind option values as `--flag=value` (`ArgHelpers.option`), and append free-form positionals (search queries, titles) LAST behind a `--` separator (`ArgHelpers.appendPositionalLast`). A value starting with `-` (search body `-19%`, markdown-bullet title `- item`) otherwise trips ArgumentParser and fails the whole tool call. `JSONValue.intValue` clamps out-of-range doubles to nil so a huge `{"limit": 1e19}` can't crash the child.

## Slow / AI-scan tools must be BatchBudget-aware

The MCP layer SIGKILLs any child exceeding ~60s. A tool whose command runs per-item AI calls (e.g. `actions extract`) must bound its work with `BatchBudget.forCurrentContext()` (50s under MCP) and return partial results + a `timedOut` warning, or it dies mid-scan. See `ActionExtractor.extract(budget:)` + `runConcurrentlyWithBudget`. Docs also steer such commands to `job_run`.

## Adding a tool: bump the count refs, but NOT the encoding fixture

A new `MCPTool` entry changes the live count (`MCPToolRegistry.tools.count`), asserted dynamically by `JSONRPCTests`/`CLIIntegrationTests` (no edit needed). Update the human-facing counts: `docs/mcp-server.md` (the "N tools" line + the tool table) and the pippin `CLAUDE.md` ToolRegistry row. Do NOT touch `AgentInfoCommandTests.testEnvelopeEncodesSnakeCaseKeys` — its `toolCount: 44` is a hardcoded snake_case *encoding fixture*, not the real count.
