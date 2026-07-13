import ArgumentParser
import Foundation

/// `pippin mcp-server` — run pippin as an MCP (Model Context Protocol) server over stdio.
///
/// Reads newline-delimited JSON-RPC 2.0 messages from stdin and writes responses to stdout.
/// Safe read-only tools (EventKit/Contacts — see `MCPInProcessTools`) run in-process;
/// every other `tools/call` spawns `pippin <subcommand> --format agent` as a child process.
/// Both paths return the same envelope-v1 JSON to the client.
public struct McpServerCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mcp-server",
        abstract: "Run pippin as an MCP server over stdio.",
        discussion: """
        Starts a JSON-RPC loop on stdin/stdout implementing the Model Context Protocol.
        Attach from any MCP-compatible client (Claude Code, Claude Desktop, Cursor) with:

            {"mcpServers":{"pippin":{"type":"stdio","command":"pippin","args":["mcp-server"]}}}

        Do not use this command interactively — it expects newline-delimited JSON input.
        """
    )

    @Flag(name: .long, help: "Print the tool registry as JSON and exit. Useful for debugging.")
    public var listTools: Bool = false

    public init() {}

    public func run() async throws {
        if listTools {
            try printToolListing()
            return
        }

        // In-process tool handlers run in THIS process, so the MCP budget clamps
        // keyed off `isMCPContext()` (PIPPIN_MCP=1) must be visible here — not
        // just in spawned children, whose env `runChild` still populates. Set it
        // before the first request so every environment read sees it.
        setenv("PIPPIN_MCP", "1", 1)

        let pippinPath = MCPServerRuntime.resolvePippinPath()
        MCPStdioWriter.log("pippin mcp-server ready (\(MCPToolRegistry.tools.count) tools, binary: \(pippinPath))")

        // readLine blocks on stdin between messages — exactly the semantics an MCP stdio
        // server wants (requests are handled serially, as before this command went
        // async). Loop exits when the client closes stdin.
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            guard let data = trimmed.data(using: .utf8) else {
                sendParseError(id: .null, message: "Invalid UTF-8 on stdin")
                continue
            }

            let request: JSONRPCRequest
            do {
                request = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
            } catch {
                sendParseError(id: .null, message: "Invalid JSON-RPC request: \(error.localizedDescription)")
                continue
            }

            if let response = await MCPDispatcher.handle(request, pippinPath: pippinPath) {
                do {
                    try MCPStdioWriter.send(response)
                } catch {
                    MCPStdioWriter.log("Failed to write response: \(error.localizedDescription)")
                }
            }
        }

        MCPStdioWriter.log("pippin mcp-server: stdin closed, exiting")
    }

    private func sendParseError(id: JSONRPCID, message: String) {
        let response = JSONRPCResponse(
            id: id,
            error: JSONRPCError(code: JSONRPCError.parseError, message: message)
        )
        try? MCPStdioWriter.send(response)
    }

    private func printToolListing() throws {
        let descriptors = MCPToolRegistry.tools.map { $0.descriptor }
        let result = MCPToolsListResult(tools: descriptors)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        print(String(decoding: data, as: UTF8.self))
    }
}
