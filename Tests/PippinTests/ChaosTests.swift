import Foundation
import GRDB
@testable import PippinLib
import XCTest

/// Chaos tests: children that die, stall or write half an answer, and store
/// files that vanish, shrink or lock under a reader. Every case must end in a
/// typed error, never a hang and never a success.
///
/// No Apple app is involved. Children are `/bin/sh` one-liners, or JXA that
/// only touches its own process; stores are temp SQLite files.
final class ChaosTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pippin-chaos-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Helpers

    /// True once `pid` is gone AND reaped: a zombie still answers signal 0.
    private func isReaped(_ pid: pid_t) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }

    private func recordedPid(_ file: URL, line: UInt = #line) throws -> pid_t {
        let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(pid_t(text), "child did not record its pid", line: line)
    }

    private func runShell(_ script: String, timeoutSeconds: Int = 10) throws -> MCPServerRuntime.ChildResult {
        try MCPServerRuntime.runChild(argv: ["-c", script], pippinPath: "/bin/sh", timeoutSeconds: timeoutSeconds, ownProcessGroup: true)
    }

    /// One `tools/call` through the real dispatcher's child path, with
    /// `/bin/sh -c script` standing in for the pippin child.
    private func callShellTool(_ script: String) async throws -> (text: String, isError: Bool) {
        let tool = MCPTool(
            name: "chaos_shell_\(UUID().uuidString)", description: "test double", inputSchema: Schema.empty,
            buildArgs: { _ in ["-c", script] }
        )
        let json = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(tool.name)"}}"#
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(json.utf8))
        let handled = await MCPDispatcher.handle(request, pippinPath: "/bin/sh", tools: [tool])
        let data = try JSONEncoder().encode(XCTUnwrap(handled))
        let reply = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(reply["result"] as? [String: Any], "tool failures must be tool results")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return try (XCTUnwrap(content.first?["text"] as? String), result["isError"] as? Bool ?? false)
    }

    private func errorCode(_ envelope: String) throws -> String {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "error")
        return try XCTUnwrap((object["error"] as? [String: Any])?["code"] as? String)
    }

    private static let partialEnvelope = #"{"v":1,"status":"ok","duration_ms":3,"da"#

    // MARK: - Child killed mid-operation

    func testChildKilledBySigkillIsACrashNotATimeoutOrSuccess() {
        XCTAssertThrowsError(try runShell("sleep 0.1; kill -9 $$")) { error in
            guard case let MCPServerRuntimeError.childCrashed(signal) = error else {
                return XCTFail("expected .childCrashed, got \(error)")
            }
            XCTAssertEqual(signal, SIGKILL)
        }
    }

    func testChildKilledAfterPartialJSONIsReportedAsAToolError() async throws {
        let (text, isError) = try await callShellTool("printf '%s' '\(Self.partialEnvelope)'; kill -9 $$")
        XCTAssertTrue(isError)
        XCTAssertEqual(try errorCode(text), "child_crashed")
        XCTAssertFalse(text.contains(#""status":"ok""#), "the dead child's half envelope must not reach the caller")
    }

    func testChildExitingNonZeroAfterPartialJSONIsReportedAsAToolError() async throws {
        let (text, isError) = try await callShellTool("printf '%s' '\(Self.partialEnvelope)'; exit 3")
        XCTAssertTrue(isError, "got: \(text)")
    }

    func testChildExitingNonZeroWithNoOutputIsTyped() async throws {
        let (text, isError) = try await callShellTool("exit 7")
        XCTAssertTrue(isError)
        XCTAssertEqual(try errorCode(text), "child_no_output")
    }

    func testDoTreatsPartialChildJSONAsInvalid() {
        let value = DoCommand.decodeChildStdout(Data(Self.partialEnvelope.utf8))
        XCTAssertEqual(value["status"]?.stringValue, "error")
        XCTAssertEqual(value["error"]?["code"]?.stringValue, "invalid_json")
    }

    func testScriptOutputDecoderRejectsPartialJSON() {
        struct Payload: Decodable { let status: String }
        for output in [Self.partialEnvelope, "", "{", "[1,", "\u{0}"] {
            XCTAssertThrowsError(
                try decodeScriptJSON(Payload.self, from: output) { NotesBridgeError.decodingFailed($0) }
            ) { error in
                guard case NotesBridgeError.decodingFailed = error else {
                    return XCTFail("expected the bridge's typed decoding error, got \(error)")
                }
            }
        }
    }

    // MARK: - Child past its deadline

    func testChildPastDeadlineIsKilledAndReaped() throws {
        let pidFile = scratch.appendingPathComponent("pid")
        let started = Date()
        XCTAssertThrowsError(try runShell("echo $$ > '\(pidFile.path)'; exec sleep 30", timeoutSeconds: 1)) { error in
            guard case MCPServerRuntimeError.childTimedOut(seconds: 1) = error else {
                return XCTFail("expected .childTimedOut, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertTrue(try isReaped(recordedPid(pidFile)), "timed-out child left running or as a zombie")
    }

    func testChildIgnoringSigtermIsSigkilledAndReaped() throws {
        let pidFile = scratch.appendingPathComponent("pid")
        let started = Date()
        // A busy loop, not `sleep`: the shell itself must be the stubborn process.
        let script = "trap '' TERM; echo $$ > '\(pidFile.path)'; while :; do :; done"
        XCTAssertThrowsError(try runShell(script, timeoutSeconds: 1)) { error in
            guard case MCPServerRuntimeError.childTimedOut = error else {
                return XCTFail("expected .childTimedOut, got \(error)")
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(elapsed, 2.5, "SIGTERM was ignored, so only the SIGKILL after the grace period can have ended it")
        XCTAssertLessThan(elapsed, 8)
        XCTAssertTrue(try isReaped(recordedPid(pidFile)), "SIGKILLed child left as a zombie")
    }

    func testDeadlineHoldsWhenAGrandchildKeepsThePipeOpen() throws {
        let pidFile = scratch.appendingPathComponent("pid")
        let started = Date()
        // The shell dies at the deadline; its background `sleep` inherited stdout.
        XCTAssertThrowsError(try runShell("sleep 30 & echo $! > '\(pidFile.path)'; wait", timeoutSeconds: 1))
        let elapsed = Date().timeIntervalSince(started)
        let grandchild = try recordedPid(pidFile)
        defer { kill(grandchild, SIGKILL) }
        XCTAssertLessThan(elapsed, 4, "returned \(elapsed)s after a 1s deadline")
        XCTAssertTrue(isReaped(grandchild), "grandchild outlived the deadline")
    }

    func testDeadlineHoldsWhenASigtermDeafGrandchildKeepsThePipeOpen() throws {
        let pidFile = scratch.appendingPathComponent("pid")
        let started = Date()
        // Ignored signals are inherited, so neither process dies on SIGTERM.
        XCTAssertThrowsError(
            try runShell("trap '' TERM; sleep 5 & echo $! > '\(pidFile.path)'; wait", timeoutSeconds: 1)
        )
        let elapsed = Date().timeIntervalSince(started)
        try kill(recordedPid(pidFile), SIGKILL)
        XCTExpectFailure(
            "runChild escalates to SIGKILL for the child only, then waits for pipe EOF: a grandchild that ignores SIGTERM and inherited stdout or stderr survives and holds the call open until it exits by itself. Fix: SIGKILL the process group, or stop draining at the deadline.",
            options: Self.nonStrict
        )
        XCTAssertLessThan(elapsed, 4.5, "returned \(elapsed)s after a 1s deadline and 2s grace")
    }

    // MARK: - ScriptRunner (real osascript, JXA that touches no app)

    private static let jxaPrelude = "ObjC.import('Foundation'); ObjC.import('stdlib'); ObjC.import('signal'); ObjC.import('unistd');"
    private static let jxaWritePartial = "$.NSFileHandle.fileHandleWithStandardOutput.writeData($('{\"ok\":tr').dataUsingEncoding(4));"

    func testScriptKilledBySigkillThrowsTypedError() {
        let script = "\(Self.jxaPrelude) \(Self.jxaWritePartial) $.kill($.getpid(), 9); 'never'"
        XCTAssertThrowsError(try ScriptRunner.run(script, timeoutSeconds: 10)) { error in
            XCTAssertTrue(error is ScriptRunnerError, "expected a ScriptRunnerError, got \(error)")
            if case ScriptRunnerError.timeout = error {
                XCTFail("a script killed by an outside SIGKILL was reported as a timeout")
            }
        }
    }

    func testScriptExitingNonZeroAfterPartialJSONThrowsTypedError() {
        let script = "\(Self.jxaPrelude) \(Self.jxaWritePartial) $.exit(3)"
        XCTAssertThrowsError(try ScriptRunner.run(script, timeoutSeconds: 10)) { error in
            guard case ScriptRunnerError.nonZeroExit = error else {
                return XCTFail("expected .nonZeroExit, got \(error)")
            }
        }
    }

    func testScriptPastDeadlineIsKilledAndReaped() throws {
        let pidFile = scratch.appendingPathComponent("pid")
        let script = """
        \(Self.jxaPrelude)
        $(String($.getpid())).writeToFileAtomicallyEncodingError('\(pidFile.path)', true, 4, null);
        delay(30); 'never'
        """
        let started = Date()
        XCTAssertThrowsError(try ScriptRunner.run(script, timeoutSeconds: 2)) { error in
            guard case ScriptRunnerError.timeout = error else {
                return XCTFail("expected .timeout, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        XCTAssertTrue(try isReaped(recordedPid(pidFile)), "timed-out osascript left running or as a zombie")
    }

    // MARK: - Store file deleted, truncated or locked

    private func makeChatDB() throws -> String {
        let path = scratch.appendingPathComponent("chat.db").path
        // Scoped so the writer connection closes before a reader opens the file.
        _ = try MessagesFixture.standard(path: path)
        return path
    }

    /// Runs every read path. Returns the conversation count, or the typed
    /// error; anything else thrown fails the test.
    private func readEverything(_ path: String, line: UInt = #line) -> Result<Int, MessagesError> {
        do {
            let database = try MessagesDatabase(dbPath: path)
            let listed = try database.listConversations()
            _ = try database.searchMessages(query: "a")
            _ = try database.showConversation(conversationId: "iMessage;-;+15551234567")
            return .success(listed.conversations.count)
        } catch let error as MessagesError {
            return .failure(error)
        } catch {
            XCTFail("untyped error from the Messages store: \(error)", line: line)
            return .failure(.databaseError("untyped"))
        }
    }

    private func assertDatabaseError(_ result: Result<Int, MessagesError>, _ what: String, line: UInt = #line) {
        guard case .failure(.databaseError) = result else {
            return XCTFail("\(what): expected MessagesError.databaseError, got \(result)", line: line)
        }
    }

    func testIntactStoreReadsCleanly() throws {
        // Proves the instrument: the same reads succeed before any fault.
        guard case let .success(count) = try readEverything(makeChatDB()) else {
            return XCTFail("fixture store did not read")
        }
        XCTAssertEqual(count, 2)
    }

    func testDeletedStoreIsNotFound() throws {
        let path = try makeChatDB()
        try FileManager.default.removeItem(atPath: path)
        guard case .failure(.databaseNotFound) = readEverything(path) else {
            return XCTFail("expected .databaseNotFound")
        }
    }

    func testStoreDeletedMidReadNeverCrashes() throws {
        let path = try makeChatDB()
        let database = try MessagesDatabase(dbPath: path)
        XCTAssertEqual(try database.listConversations().conversations.count, 2)
        try FileManager.default.removeItem(atPath: path)
        // Full data (the open descriptor can still read the unlinked file) or
        // a typed error are both acceptable; a partial answer is not.
        switch Result(catching: { try database.listConversations().conversations.count }) {
        case let .success(count): XCTAssertEqual(count, 2)
        case let .failure(error): XCTAssertTrue(error is MessagesError, "untyped error: \(error)")
        }
    }

    func testTruncatedStoreIsATypedError() throws {
        let path = try makeChatDB()
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)
        for keep in [size / 2, 4096, 1000, 100, 16] {
            let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
            try handle.truncate(atOffset: UInt64(keep))
            try handle.close()
            assertDatabaseError(readEverything(path), "truncated to \(keep) bytes")
        }
    }

    func testStoreTruncatedMidReadIsATypedError() throws {
        let path = try makeChatDB()
        let database = try MessagesDatabase(dbPath: path)
        XCTAssertEqual(try database.listConversations().conversations.count, 2)
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        try handle.truncate(atOffset: 1000)
        try handle.close()
        XCTAssertThrowsError(try database.searchMessages(query: "a")) { error in
            XCTAssertTrue(error is MessagesError, "untyped error: \(error)")
        }
    }

    func testGarbageStoreIsATypedError() throws {
        let path = scratch.appendingPathComponent("chat.db").path
        var rng = FuzzRNG(seed: 0xC4A0_5001)
        for size in [1, 100, 4096, 20000] {
            try Data((0 ..< size).map { _ in UInt8(truncatingIfNeeded: rng.next()) }).write(to: URL(fileURLWithPath: path))
            assertDatabaseError(readEverything(path), "\(size) random bytes")
        }
        // A valid SQLite header over garbage pages.
        try (Data("SQLite format 3\u{0}".utf8) + Data(repeating: 0xAB, count: 8000)).write(to: URL(fileURLWithPath: path))
        assertDatabaseError(readEverything(path), "valid header, garbage pages")
    }

    func testEmptyStoreFileIsATypedError() {
        let path = scratch.appendingPathComponent("chat.db").path
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data()))
        assertDatabaseError(readEverything(path), "zero-byte file")
    }

    func testExclusivelyLockedStoreIsATypedError() throws {
        let path = try makeChatDB()
        let locker = try DatabaseQueue(path: path)
        try locker.writeWithoutTransaction { db in
            try db.execute(sql: "BEGIN EXCLUSIVE")
            defer { try? db.execute(sql: "ROLLBACK") }
            let started = Date()
            self.assertDatabaseError(self.readEverything(path), "exclusive lock held by another connection")
            XCTAssertLessThan(Date().timeIntervalSince(started), 5, "a locked store must fail fast, not wait")
        }
        // Proves the lock was the cause: the same reads succeed once released.
        guard case .success(2) = readEverything(path) else {
            return XCTFail("store did not recover after the lock was released")
        }
    }

    func testVoiceMemosStoreFaultsAreTyped() throws {
        let path = scratch.appendingPathComponent("CloudRecordings.db").path
        XCTAssertThrowsError(try VoiceMemosDB(dbPath: path)) { error in
            guard case VoiceMemosError.databaseNotFound = error else {
                return XCTFail("expected .databaseNotFound, got \(error)")
            }
        }
        try Data(repeating: 0xAB, count: 5000).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try VoiceMemosDB(dbPath: path)) { error in
            XCTAssertTrue(error is VoiceMemosError, "garbage file: untyped error \(error)")
        }
        try Data().write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try VoiceMemosDB(dbPath: path)) { error in
            XCTAssertTrue(error is VoiceMemosError, "zero-byte file: untyped error \(error)")
        }
    }

    func testMailEnvelopeIndexStoreFaultsAreTyped() throws {
        let path = scratch.appendingPathComponent("Envelope Index").path
        XCTAssertThrowsError(try MailEnvelopeIndex(dbPath: path, accounts: [])) { error in
            guard case MailEnvelopeIndexError.databaseNotFound = error else {
                return XCTFail("expected .databaseNotFound, got \(error)")
            }
        }
        try Data(repeating: 0xAB, count: 5000).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try MailEnvelopeIndex(dbPath: path, accounts: [])) { error in
            XCTAssertTrue(error is MailEnvelopeIndexError, "garbage file: untyped error \(error)")
        }
        try Data().write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try MailEnvelopeIndex(dbPath: path, accounts: [])) { error in
            XCTAssertTrue(error is MailEnvelopeIndexError, "zero-byte file: untyped error \(error)")
        }
    }

    private static var nonStrict: XCTExpectedFailure.Options {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        return options
    }
}
