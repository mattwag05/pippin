@testable import PippinLib
import XCTest

final class BatchCommandTests: XCTestCase {
    // MARK: - Configuration

    func testBatchCommandName() {
        XCTAssertEqual(BatchCommand.configuration.commandName, "batch")
    }

    // MARK: - Flag parsing

    func testBatchParsesNoArgs() {
        XCTAssertNoThrow(try BatchCommand.parse([]))
    }

    func testBatchDefaultConcurrency() throws {
        let cmd = try BatchCommand.parse([])
        XCTAssertEqual(cmd.concurrency, 4)
    }

    func testBatchParsesConcurrency() throws {
        let cmd = try BatchCommand.parse(["--concurrency", "8"])
        XCTAssertEqual(cmd.concurrency, 8)
    }

    func testBatchRejectsZeroConcurrency() {
        XCTAssertThrowsError(try BatchCommand.parse(["--concurrency", "0"]))
    }

    func testBatchParsesEntriesFlag() throws {
        let cmd = try BatchCommand.parse(["--entries", "[]"])
        XCTAssertEqual(cmd.entries, "[]")
    }

    func testBatchParsesInputFile() throws {
        let cmd = try BatchCommand.parse(["--input", "/tmp/x.json"])
        XCTAssertEqual(cmd.input, "/tmp/x.json")
    }

    // MARK: - BatchEntry decoding

    func testBatchEntryDecodesCmdOnly() throws {
        let json = #"[{"cmd":"calendar"}]"#
        let entries = try BatchCommand.readEntries(entries: json, input: nil)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].cmd, "calendar")
        XCTAssertNil(entries[0].args)
    }

    func testBatchEntryDecodesCmdWithArgs() throws {
        let json = #"[{"cmd":"mail","args":["list","--account","icloud"]}]"#
        let entries = try BatchCommand.readEntries(entries: json, input: nil)
        XCTAssertEqual(entries[0].cmd, "mail")
        XCTAssertEqual(entries[0].args, ["list", "--account", "icloud"])
    }

    func testBatchEntryDecodesMultiple() throws {
        let json = #"[{"cmd":"a"},{"cmd":"b","args":["x"]},{"cmd":"c"}]"#
        let entries = try BatchCommand.readEntries(entries: json, input: nil)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.cmd), ["a", "b", "c"])
    }

    func testBatchEntryRejectsNonArray() {
        XCTAssertThrowsError(try BatchCommand.readEntries(entries: #"{"cmd":"x"}"#, input: nil))
    }

    func testBatchEntryRejectsEmptyInput() {
        XCTAssertThrowsError(try BatchCommand.readEntries(entries: "", input: nil)) { error in
            guard case BatchError.emptyInput = error else {
                return XCTFail("expected emptyInput, got \(error)")
            }
        }
    }

    func testBatchEntryRejectsMalformedJSON() {
        XCTAssertThrowsError(try BatchCommand.readEntries(entries: "not json", input: nil)) { error in
            guard case BatchError.invalidEntriesJSON = error else {
                return XCTFail("expected invalidEntriesJSON, got \(error)")
            }
        }
    }

    func testBatchReadsFromFile() throws {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        try Data(#"[{"cmd":"calendar","args":["today"]}]"#.utf8).write(to: tmpURL)
        let entries = try BatchCommand.readEntries(entries: nil, input: tmpURL.path)
        XCTAssertEqual(entries.first?.cmd, "calendar")
    }

    // MARK: - resolvedArgv (--format agent injection)

    func testResolvedArgvAppendsFormatAgent() {
        let entry = BatchEntry(cmd: "calendar", args: ["today"])
        XCTAssertEqual(entry.resolvedArgv, ["calendar", "today", "--format", "agent"])
    }

    func testResolvedArgvNoArgs() {
        let entry = BatchEntry(cmd: "doctor", args: nil)
        XCTAssertEqual(entry.resolvedArgv, ["doctor", "--format", "agent"])
    }

    func testResolvedArgvDoesNotDoubleAddFormat() {
        let entry = BatchEntry(cmd: "mail", args: ["list", "--format", "json"])
        XCTAssertEqual(entry.resolvedArgv, ["mail", "list", "--format", "json"])
    }

    // MARK: - dispatch (empty input)

    func testDispatchEmptyEntriesYieldsEmpty() async {
        let results = await BatchCommand.dispatch(entries: [], concurrency: 4, pippinPath: "/nonexistent")
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - entryEnvelopeError shape

    func testEntryEnvelopeErrorHasExpectedShape() throws {
        let envelope = BatchCommand.entryEnvelopeError(code: "test_code", message: "msg")
        let data = try JSONEncoder().encode(envelope)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(dict["status"] as? String, "error")
        XCTAssertEqual(dict["v"] as? Int, AGENT_SCHEMA_VERSION)
        let err = try XCTUnwrap(dict["error"] as? [String: Any])
        XCTAssertEqual(err["code"] as? String, "test_code")
        XCTAssertEqual(err["message"] as? String, "msg")
    }

    // MARK: - Bad-child runOne path (synthetic envelope on launch failure)

    func testRunOneSyntheticErrorOnUnreachableBinary() {
        let entry = BatchEntry(cmd: "calendar", args: ["today"])
        let result = BatchCommand.runOne(entry: entry, pippinPath: "/nonexistent/pippin-binary-\(UUID().uuidString)")
        XCTAssertEqual(BatchCommand.statusString(result), "error")
        // Cause = launch failure, not malformed JSON.
        if case let .object(dict) = result, case let .object(err) = dict["error"] ?? .null {
            XCTAssertEqual(err["code"]?.stringValue, "child_launch_failed")
        } else {
            XCTFail("expected nested error object")
        }
    }
}
