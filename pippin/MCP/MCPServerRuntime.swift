import Foundation

/// Protocol version we advertise in `initialize`. Bump when the MCP spec revision changes.
let mcpProtocolVersion = "2024-11-05"

// MARK: - Child process runner

/// Spawns `pippin <argv>` as a child process and returns its stdout bytes.
/// Throws `MCPServerRuntimeError.processLaunchFailed` if the binary can't be started.
/// Non-zero exit codes are NOT thrown — the exit code and stdout are both returned so the
/// caller can distinguish a tool-level error (agent JSON error) from a protocol error.
enum MCPServerRuntime {
    struct ChildResult {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data
    }

    /// Resolve the path to the currently running pippin binary so the child process is
    /// the exact same version, not whatever `pippin` resolves to on PATH.
    static func resolvePippinPath() -> String {
        let argv0 = CommandLine.arguments.first ?? "pippin"
        if argv0.hasPrefix("/") {
            return realpathOrSelf(argv0)
        }
        if let found = searchPath(for: argv0) {
            return realpathOrSelf(found)
        }
        return argv0
    }

    private static func realpathOrSelf(_ path: String) -> String {
        guard let buffer = Foundation.realpath(path, nil) else { return path }
        defer { free(buffer) }
        return String(cString: buffer)
    }

    private static func searchPath(for name: String) -> String? {
        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in pathEnv.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Default hard timeout for any tool invocation. Bridge tools must self-bound
    /// well below this — the MCP runtime will SIGTERM/SIGKILL the child if it
    /// blows past, returning a structured `.childTimedOut` error rather than
    /// hanging the JSON-RPC loop forever.
    static let defaultChildTimeoutSeconds = 60

    static func runChild(
        argv: [String],
        pippinPath: String,
        timeoutSeconds: Int = defaultChildTimeoutSeconds
    ) throws -> ChildResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pippinPath)
        process.arguments = argv

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // The child must not read anything from us — stdin would contend with our JSON-RPC loop.
        process.standardInput = FileHandle.nullDevice

        // Drain pipes concurrently so a large stdout doesn't deadlock on a full buffer.
        nonisolated(unsafe) var outBytes = Data()
        nonisolated(unsafe) var errBytes = Data()
        let drainGroup = DispatchGroup()

        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outBytes = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errBytes = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }

        do {
            try process.run()
        } catch {
            throw MCPServerRuntimeError.processLaunchFailed(pippinPath, underlying: error)
        }

        // Hard timeout: SIGTERM, then SIGKILL after a 2s grace, mirroring
        // ScriptRunner's pattern. Without this the JSON-RPC loop blocks forever
        // if the child wedges (e.g. osascript stuck on an unresponsive Mail.app).
        nonisolated(unsafe) var timedOut = false
        let timeoutItem = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut = true
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: timeoutItem)

        process.waitUntilExit()
        timeoutItem.cancel()
        drainGroup.wait()

        if timedOut {
            throw MCPServerRuntimeError.childTimedOut(seconds: timeoutSeconds)
        }

        return ChildResult(
            exitCode: process.terminationStatus,
            stdout: outBytes,
            stderr: errBytes
        )
    }
}

// MARK: - Errors

enum MCPServerRuntimeError: LocalizedError {
    case processLaunchFailed(String, underlying: Error)
    case childCrashed(signal: Int32)
    case childTimedOut(seconds: Int)

    var errorDescription: String? {
        switch self {
        case let .processLaunchFailed(path, error):
            return "Failed to launch child pippin at \(path): \(error.localizedDescription)"
        case let .childCrashed(signal):
            return "pippin child exited with signal \(signal)"
        case let .childTimedOut(seconds):
            return "pippin child exceeded \(seconds)s and was terminated. Narrow the request (--account, --mailbox, --limit) or rerun with a more specific query."
        }
    }
}

// MARK: - JSON-RPC framing helpers

enum MCPStdioWriter {
    /// Write a JSON-RPC response as a single newline-terminated line. Must NOT use `print()` —
    /// stdout is reserved for JSON-RPC framing and `print` adds its own buffering.
    static func send(_ response: JSONRPCResponse) throws {
        let encoder = JSONEncoder()
        let bytes = try encoder.encode(response)
        let output = FileHandle.standardOutput
        output.write(bytes)
        output.write(Data([0x0A]))
    }

    /// Log a diagnostic message to stderr.
    static func log(_ message: String) {
        let line = "\(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

// MARK: - Dispatcher

/// Pure-function dispatch: takes a parsed request, returns the response to send (or nil
/// for notifications). Kept free of any I/O so it's trivially testable.
enum MCPDispatcher {
    static func handle(
        _ request: JSONRPCRequest,
        pippinPath: String,
        tools: [MCPTool] = MCPToolRegistry.tools
    ) -> JSONRPCResponse? {
        // Notifications (no id) never get a response, even on error.
        if request.isNotification {
            return nil
        }

        let id = request.id ?? .null

        switch request.method {
        case "initialize":
            return makeInitializeResponse(id: id)
        case "tools/list":
            return makeToolsListResponse(id: id, tools: tools)
        case "tools/call":
            return makeToolCallResponse(
                id: id,
                params: request.params,
                pippinPath: pippinPath,
                tools: tools
            )
        case "ping":
            return JSONRPCResponse(id: id, result: .object([:]))
        default:
            return JSONRPCResponse(
                id: id,
                error: JSONRPCError(
                    code: JSONRPCError.methodNotFound,
                    message: "Method not found: \(request.method)"
                )
            )
        }
    }

    private static func makeInitializeResponse(id: JSONRPCID) -> JSONRPCResponse {
        let result = MCPInitializeResult(
            protocolVersion: mcpProtocolVersion,
            capabilities: .init(tools: .init(listChanged: false)),
            serverInfo: .init(name: "pippin", version: PippinVersion.version)
        )
        guard let value = encodeToJSONValue(result) else {
            return JSONRPCResponse(
                id: id,
                error: JSONRPCError(code: JSONRPCError.internalError, message: "Failed to encode initialize result")
            )
        }
        return JSONRPCResponse(id: id, result: value)
    }

    private static func makeToolsListResponse(id: JSONRPCID, tools: [MCPTool]) -> JSONRPCResponse {
        let descriptors = tools.map { $0.descriptor }
        guard let value = encodeToJSONValue(MCPToolsListResult(tools: descriptors)) else {
            return JSONRPCResponse(
                id: id,
                error: JSONRPCError(code: JSONRPCError.internalError, message: "Failed to encode tools list")
            )
        }
        return JSONRPCResponse(id: id, result: value)
    }

    private static func makeToolCallResponse(
        id: JSONRPCID,
        params: JSONValue?,
        pippinPath: String,
        tools: [MCPTool]
    ) -> JSONRPCResponse {
        guard let toolName = params?["name"]?.stringValue else {
            return JSONRPCResponse(
                id: id,
                error: JSONRPCError(code: JSONRPCError.invalidParams, message: "tools/call requires params.name")
            )
        }
        let toolArguments = params?["arguments"]

        guard let tool = tools.first(where: { $0.name == toolName }) else {
            return JSONRPCResponse(
                id: id,
                error: JSONRPCError(
                    code: JSONRPCError.methodNotFound,
                    message: "Unknown tool: \(toolName)"
                )
            )
        }

        let argv: [String]
        do {
            argv = try tool.buildArgs(toolArguments)
        } catch {
            return wrapToolResult(
                id: id,
                payload: MCPToolCallResult(
                    text: "Argument error: \(error.localizedDescription)",
                    isError: true
                )
            )
        }

        let childResult: MCPServerRuntime.ChildResult
        do {
            childResult = try MCPServerRuntime.runChild(argv: argv, pippinPath: pippinPath)
        } catch let error as MCPServerRuntimeError {
            // Timeout is a tool-level failure (the user can act on it); other
            // runtime errors are protocol-level (the user can't).
            if case .childTimedOut = error {
                return wrapToolResult(
                    id: id,
                    payload: MCPToolCallResult(
                        text: error.localizedDescription,
                        isError: true
                    )
                )
            }
            return JSONRPCResponse(
                id: id,
                error: JSONRPCError(
                    code: JSONRPCError.internalError,
                    message: error.localizedDescription
                )
            )
        } catch {
            return JSONRPCResponse(
                id: id,
                error: JSONRPCError(
                    code: JSONRPCError.internalError,
                    message: error.localizedDescription
                )
            )
        }

        let stdoutString = String(data: childResult.stdout, encoding: .utf8) ?? ""
        let trimmed = stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)

        if childResult.exitCode == 0 {
            let text = trimmed.isEmpty ? "{}" : trimmed
            return wrapToolResult(id: id, payload: MCPToolCallResult(text: text, isError: false))
        } else {
            // Non-zero exit: child already printed AgentError JSON to stdout via printAgentError.
            // Pass through verbatim so clients can parse it.
            let text = trimmed.isEmpty
                ? "pippin child exited \(childResult.exitCode) with no output"
                : trimmed
            return wrapToolResult(id: id, payload: MCPToolCallResult(text: text, isError: true))
        }
    }

    private static func wrapToolResult(id: JSONRPCID, payload: MCPToolCallResult) -> JSONRPCResponse {
        guard let value = encodeToJSONValue(payload) else {
            return JSONRPCResponse(
                id: id,
                error: JSONRPCError(code: JSONRPCError.internalError, message: "Failed to encode tool result")
            )
        }
        return JSONRPCResponse(id: id, result: value)
    }

    private static func encodeToJSONValue(_ value: some Encodable) -> JSONValue? {
        guard
            let data = try? JSONEncoder().encode(value),
            let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return nil
        }
        return decoded
    }
}
