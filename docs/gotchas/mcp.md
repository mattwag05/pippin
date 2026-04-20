# MCP Server Patterns

Load when editing `pippin/MCP/`, `McpServerCommand.swift`, or `ToolRegistry.swift`. For usage and wiring, see [mcp-server.md](../mcp-server.md).

## Never `print()` inside the mcp-server command

stdout is reserved for JSON-RPC framing — any stray print corrupts the transport. Diagnostics go to stderr via `MCPStdioWriter.log()`.

## Tool argv must always include `--format agent`

The child `pippin` process produces compact agent JSON that the server wraps verbatim as `content[0].text`. A lint test (`testAllArgvEndWithFormatAgent`) enforces this across the registry.

## Exit-code-to-error mapping

When the child exits non-zero, stdout contains an `AgentError` JSON (`{"error":{"code":"snake_case","message":"..."}}`) from `printAgentError`. The server passes this through as the tool result text with `isError: true`. Do NOT convert it to a JSON-RPC-level `-326xx` error — those are reserved for protocol-level failures (unknown method, malformed request, launch failure).

## Binary path resolution

`MCPServerRuntime.resolvePippinPath()` uses `CommandLine.arguments[0]` + `realpath` so the child is the exact same binary as the parent, not whatever `pippin` resolves to on `$PATH`. This matters when pippin is run via a symlink (Homebrew shim).
