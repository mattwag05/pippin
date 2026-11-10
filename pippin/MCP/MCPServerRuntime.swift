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

    /// `ownProcessGroup` puts the child in a process group of its own and aims
    /// the timeout at the whole group, so grandchildren (the `osascript` a
    /// bridge spawned) die with it instead of finishing a send after the caller
    /// was told the call timed out. Off for terminal use, where the child must
    /// stay in the foreground group to receive Ctrl-C.
    static func runChild(
        argv: [String],
        pippinPath: String,
        timeoutSeconds: Int = defaultChildTimeoutSeconds,
        ownProcessGroup: Bool = false
    ) throws -> ChildResult {
        // An argv string ends at its first NUL, so one inside an argument would
        // silently run a different command (and aborted Foundation.Process).
        guard !argv.contains(where: { $0.contains("\0") }) else {
            throw MCPServerRuntimeError.nulInArgument
        }
        // Mark the child so AI providers and other MCP-sensitive code paths
        // can shorten budgets / run preflight pings to stay under the
        // `defaultChildTimeoutSeconds` hard cap.
        var env = ProcessInfo.processInfo.environment
        env["PIPPIN_MCP"] = "1"

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        // posix_spawn, not Foundation.Process: Process cannot set a process group.
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        // The child must not read anything from us: stdin would contend with our JSON-RPC loop.
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Every descriptor but the three above closes in the child.
        var flags = POSIX_SPAWN_CLOEXEC_DEFAULT
        if ownProcessGroup {
            flags |= POSIX_SPAWN_SETPGROUP
            posix_spawnattr_setpgroup(&attributes, 0)
        }
        posix_spawnattr_setflags(&attributes, Int16(flags))

        let cArgv: [UnsafeMutablePointer<CChar>?] = ([pippinPath] + argv).map { strdup($0) } + [nil]
        let cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (cArgv + cEnv).forEach { free($0) } }

        var spawned: pid_t = 0
        let spawnError = posix_spawn(&spawned, pippinPath, &fileActions, &attributes, cArgv, cEnv)
        let pid = spawned
        // Our copies of the write ends, so the readers below see EOF when the child's close.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        guard spawnError == 0 else {
            throw MCPServerRuntimeError.processLaunchFailed(
                pippinPath, underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(spawnError))
            )
        }

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

        // Hard timeout: SIGTERM, then SIGKILL after a 2s grace. Without this
        // the JSON-RPC loop blocks forever if the child wedges (e.g. osascript
        // stuck on an unresponsive Mail.app).
        let signalChild: @Sendable (Int32) -> Void = { signal in
            _ = ownProcessGroup ? killpg(pid, signal) : kill(pid, signal)
        }
        let killedByTimeout = ConcurrentSlot<Bool>()
        let killItem = DispatchWorkItem { signalChild(SIGKILL) }
        let timeoutItem = DispatchWorkItem {
            killedByTimeout.set(true)
            signalChild(SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2), execute: killItem)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: timeoutItem)

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        timeoutItem.cancel()
        killItem.cancel()
        // The leader is gone; anything it left in the group still holds our
        // pipes and may still be doing the work we just reported as timed out.
        if ownProcessGroup, killedByTimeout.get() == true { killpg(pid, SIGKILL) }
        drainGroup.wait()

        // A signal death is a timeout only if our own timer sent it. Anything
        // else is a crash, which must not read as a retryable timeout.
        let signal = status & 0x7F
        if signal != 0, signal != 0x7F {
            if killedByTimeout.get() == true {
                throw MCPServerRuntimeError.childTimedOut(seconds: timeoutSeconds)
            }
            throw MCPServerRuntimeError.childCrashed(signal: signal)
        }

        return ChildResult(
            exitCode: (status >> 8) & 0xFF,
            stdout: outBytes,
            stderr: errBytes
        )
    }

    /// A timeout on a tool that can change something says nothing about
    /// whether the change happened, so it must not read as "retry".
    static func outcomeUnknownIfMutating(_ error: Error, tool: MCPTool, tools: [MCPTool]) -> Error {
        guard case let MCPServerRuntimeError.childTimedOut(seconds) = error, tool.effect != .readOnly else {
            return error
        }
        var verify = NextStep.none
        if case let .mutating(name?) = tool.effect,
           let argv = try? tools.first(where: { $0.name == name })?.buildArgs(nil) {
            verify = .call(tool: name, argv: Array(argv.dropLast(2))) // minus `--format agent`
        }
        return MCPServerRuntimeError.outcomeUnknown(tool: tool.name, seconds: seconds, verify: verify)
    }
}

// MARK: - Errors

enum MCPServerRuntimeError: LocalizedError, RemediableError {
    case processLaunchFailed(String, underlying: Error)
    case childTimedOut(seconds: Int)
    case outcomeUnknown(tool: String, seconds: Int, verify: NextStep)
    case childCrashed(signal: Int32)
    case nulInArgument
    case childNoOutput(exitCode: Int32)
    case inProcessTimedOut(seconds: Int)
    case notInProcessCapable(String)

    var agentCode: String {
        switch self {
        case .processLaunchFailed: return "child_launch_failed"
        case .childTimedOut: return "child_timed_out"
        case .outcomeUnknown: return "outcome_unknown"
        case .childCrashed: return "child_crashed"
        case .nulInArgument: return "invalid_argument"
        case .childNoOutput: return "child_no_output"
        case .inProcessTimedOut: return "in_process_timed_out"
        case .notInProcessCapable: return "not_in_process_capable"
        }
    }

    var nextStep: NextStep {
        switch self {
        case .processLaunchFailed, .childCrashed, .childNoOutput:
            return .call(tool: "doctor", argv: ["doctor"])
        case .childTimedOut, .inProcessTimedOut:
            return .retry(after: 5)
        case let .outcomeUnknown(_, _, verify):
            return verify
        case .notInProcessCapable, .nulInArgument:
            return .none
        }
    }

    var errorDescription: String? {
        switch self {
        case let .processLaunchFailed(path, error):
            return "Failed to launch child pippin at \(path): \(error.localizedDescription)"
        case let .childTimedOut(seconds):
            return "pippin child exceeded \(seconds)s and was terminated. Narrow the request (--account, --mailbox, --limit) or rerun with a more specific query."
        case let .outcomeUnknown(tool, seconds, _):
            return "\(tool) was stopped after \(seconds)s and may or may not have taken effect. Check the current state before calling it again; do not repeat it blindly."
        case .nulInArgument:
            return "An argument contains a NUL character (U+0000), which no pippin argument can hold."
        case let .childCrashed(signal):
            return "pippin child crashed with signal \(signal)."
        case let .childNoOutput(exitCode):
            return "pippin child exited \(exitCode) with no output."
        case let .inProcessTimedOut(seconds):
            return "The tool did not answer within \(seconds)s. Retry; it now runs in a separate process for this session."
        case let .notInProcessCapable(command):
            return "Internal error: '\(command)' is registered as in-process but is not an AgentCommand."
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

/// Request dispatch: takes a parsed request, returns the response to send (or nil
/// for notifications). Does no stdio itself so it's trivially testable; tool
/// calls run either in-process (`MCPTool.inProcess`) or via a child `pippin`.
enum MCPDispatcher {
    static func handle(
        _ request: JSONRPCRequest,
        pippinPath: String,
        tools: [MCPTool] = MCPToolRegistry.tools,
        inProcessDeadline: Double = Double(MCPInProcessTools.deadlineSeconds),
        childTimeoutSeconds: Int = MCPServerRuntime.defaultChildTimeoutSeconds,
        safety: SafetyGate = .shared,
        runner: ArgvRunner? = nil
    ) async -> JSONRPCResponse? {
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
            return await makeToolCallResponse(
                id: id,
                params: request.params,
                pippinPath: pippinPath,
                tools: tools,
                inProcessDeadline: inProcessDeadline,
                childTimeoutSeconds: childTimeoutSeconds,
                safety: safety,
                runner: runner
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
            serverInfo: .init(name: "pippin", version: PippinVersion.version),
            instructions: UntrustedContent.serverInstructions
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
        tools: [MCPTool],
        inProcessDeadline: Double,
        childTimeoutSeconds: Int,
        safety: SafetyGate,
        runner: ArgvRunner?
    ) async -> JSONRPCResponse {
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

        let toolStartedAt = Date()
        // `runner` stands in for both ways of running a command (tests).
        let runArgv: ArgvRunner = runner ?? { argv in
            try await runChild(argv: argv, pippinPath: pippinPath, timeoutSeconds: childTimeoutSeconds)
        }

        // The safety chokepoint: anything not declared read-only (an
        // unclassified tool included) runs only through the gate, which applies
        // policy, confirmation, rate limits, the action log and idempotency.
        guard tool.effect == .readOnly else {
            do {
                let result = try await safety.run(tool: tool, arguments: toolArguments, tools: tools, runArgv: runArgv)
                return toolResult(id: id, tool: tool, text: result.text, isError: result.isError)
            } catch {
                return errorResult(id: id, error, startedAt: toolStartedAt)
            }
        }

        do {
            try safety.checkRead(tool, tools: tools)
            // buildArgs reads only the keys it knows, so without this an
            // unknown or mistyped key is silently dropped.
            try SchemaValidator.validate(args: toolArguments, against: tool.inputSchema)
            let argv = try tool.buildArgs(toolArguments)

            // In-process fast path: no child spawn, same command as the child runs.
            // A tool that wedges past the deadline moves to the child path, where
            // a hard kill exists, for the rest of the session.
            if runner == nil, let handler = tool.inProcess, !MCPInProcessTools.isDemoted(tool.name) {
                do {
                    let text = try await MCPInProcessTools.withDeadline(seconds: inProcessDeadline) {
                        try await handler(argv)
                    }
                    return toolResult(id: id, tool: tool, text: text, isError: false)
                } catch {
                    if case MCPServerRuntimeError.inProcessTimedOut = error {
                        MCPInProcessTools.demote(tool.name)
                    }
                    throw error
                }
            }
            let result = try await runArgv(argv)
            return toolResult(id: id, tool: tool, text: result.text, isError: result.isError)
        } catch {
            // Every failure to run the tool is tool-level: the caller can act
            // on it, and the envelope says how.
            return errorResult(id: id, error, startedAt: toolStartedAt)
        }
    }

    /// Run `pippin <argv>` as a child and return its envelope. A non-zero exit
    /// is the child's own error envelope, passed through verbatim so clients
    /// can parse it; only a child that could not be run to an answer throws.
    private static func runChild(
        argv: [String], pippinPath: String, timeoutSeconds: Int
    ) async throws -> (text: String, isError: Bool) {
        // runChild blocks on waitUntilExit: hop off the cooperative pool
        // (mirrors DoCommand's call site).
        let childResult = try await detachBlocking {
            try MCPServerRuntime.runChild(
                argv: argv, pippinPath: pippinPath, timeoutSeconds: timeoutSeconds, ownProcessGroup: true
            )
        }
        let trimmed = (String(data: childResult.stdout, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if childResult.exitCode == 0 {
            return (trimmed.isEmpty ? "{}" : trimmed, false)
        }
        guard !trimmed.isEmpty else { throw MCPServerRuntimeError.childNoOutput(exitCode: childResult.exitCode) }
        return (trimmed, true)
    }

    /// Every tool result leaves through here, so every result that holds text
    /// from outside is marked untrusted.
    private static func toolResult(id: JSONRPCID, tool: MCPTool, text: String, isError: Bool) -> JSONRPCResponse {
        let marked = isError ? text : UntrustedContent.mark(text, tool: tool.name)
        return wrapToolResult(id: id, payload: MCPToolCallResult(text: marked, isError: isError))
    }

    private static func errorResult(id: JSONRPCID, _ error: Error, startedAt: Date) -> JSONRPCResponse {
        wrapToolResult(
            id: id,
            payload: MCPToolCallResult(text: MCPInProcessTools.errorEnvelope(error, startedAt: startedAt), isError: true)
        )
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
