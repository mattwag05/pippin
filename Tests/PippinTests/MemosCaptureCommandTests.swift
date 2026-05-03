@testable import PippinLib
import XCTest

final class MemosCaptureCommandTests: XCTestCase {
    // MARK: - Configuration

    func testCaptureCommandName() {
        XCTAssertEqual(MemosCaptureCommand.configuration.commandName, "capture")
    }

    func testMemosRegistersCaptureSubcommand() {
        let names = MemosCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("capture"), "MemosCommand should register 'capture' subcommand")
    }

    // MARK: - Flag parsing

    func testRequiresToRemindersFlag() {
        XCTAssertThrowsError(try MemosCaptureCommand.parse([])) { error in
            let msg = String(describing: error)
            XCTAssertTrue(msg.contains("--to-reminders"), "Expected error to mention --to-reminders, got: \(msg)")
        }
    }

    func testToRemindersAlonePasses() {
        XCTAssertNoThrow(try MemosCaptureCommand.parse(["--to-reminders"]))
    }

    func testParsesMemoFlag() throws {
        let cmd = try MemosCaptureCommand.parse(["--to-reminders", "--memo", "abc123"])
        XCTAssertEqual(cmd.memo, "abc123")
    }

    func testParsesListFlag() throws {
        let cmd = try MemosCaptureCommand.parse(["--to-reminders", "--list", "Work"])
        XCTAssertEqual(cmd.list, "Work")
    }

    func testDryRunDefaultsFalse() throws {
        let cmd = try MemosCaptureCommand.parse(["--to-reminders"])
        XCTAssertFalse(cmd.dryRun)
    }

    func testParsesDryRunFlag() throws {
        let cmd = try MemosCaptureCommand.parse(["--to-reminders", "--dry-run"])
        XCTAssertTrue(cmd.dryRun)
    }

    func testParsesProviderAndModel() throws {
        let cmd = try MemosCaptureCommand.parse([
            "--to-reminders", "--provider", "claude", "--model", "claude-sonnet-4-6",
        ])
        XCTAssertEqual(cmd.provider, "claude")
        XCTAssertEqual(cmd.model, "claude-sonnet-4-6")
    }

    func testParsesApiKey() throws {
        let cmd = try MemosCaptureCommand.parse(["--to-reminders", "--api-key", "sk-ant-xxx"])
        XCTAssertEqual(cmd.apiKey, "sk-ant-xxx")
    }

    func testJsonFormatPasses() {
        XCTAssertNoThrow(try MemosCaptureCommand.parse(["--to-reminders", "--format", "json"]))
    }

    func testAgentFormatPasses() {
        XCTAssertNoThrow(try MemosCaptureCommand.parse(["--to-reminders", "--format", "agent"]))
    }

    // MARK: - Template

    func testCaptureTemplateRegistered() {
        let names = BuiltInTemplates.all.map(\.name)
        XCTAssertTrue(names.contains("capture-action-items"))
    }

    func testCaptureTemplateHasDateSubstitutions() {
        let content = BuiltInTemplates.captureActionItems.content
        XCTAssertTrue(content.contains("{{CURRENT_DATE}}"))
        XCTAssertTrue(content.contains("{{CURRENT_TIME}}"))
    }

    // MARK: - LLM response parsing

    func testParsesCannedLLMResponse() throws {
        let raw = """
        {"items":[
          {"title":"Email Alex re: Q3 numbers","due_hint":"2026-04-26","notes":"I'll send the Q3 numbers to Alex by Friday."},
          {"title":"Book flight to SFO","due_hint":null,"notes":null}
        ]}
        """
        let data = Data(raw.utf8)
        let parsed = try JSONDecoder().decode(LLMActionItemsResponse.self, from: data)
        XCTAssertEqual(parsed.items.count, 2)
        XCTAssertEqual(parsed.items[0].title, "Email Alex re: Q3 numbers")
        XCTAssertEqual(parsed.items[0].dueHint, "2026-04-26")
        XCTAssertEqual(parsed.items[0].notes, "I'll send the Q3 numbers to Alex by Friday.")
        XCTAssertNil(parsed.items[1].dueHint)
        XCTAssertNil(parsed.items[1].notes)
    }

    func testParsesEmptyItemsArray() throws {
        let raw = "{\"items\":[]}"
        let parsed = try JSONDecoder().decode(LLMActionItemsResponse.self, from: Data(raw.utf8))
        XCTAssertEqual(parsed.items.count, 0)
    }

    func testParsesResponseWrappedInJunk() throws {
        let noisy = """
        Sure, here's the JSON:
        {"items":[{"title":"Ship the release","due_hint":null,"notes":null}]}
        Let me know if you need anything else.
        """
        // extractJSON is the helper used by MemosCaptureCommand.parseItems
        guard let data = extractJSON(from: noisy) else {
            return XCTFail("extractJSON returned nil for noisy LLM response")
        }
        let parsed = try JSONDecoder().decode(LLMActionItemsResponse.self, from: data)
        XCTAssertEqual(parsed.items.first?.title, "Ship the release")
    }

    // MARK: - Envelope v1 payload shape

    func testCapturedItemCodingKeysAreSnakeCase() throws {
        let item = CapturedItem(title: "T", dueHint: "2026-04-26", notes: "n", reminderId: "abc")
        let data = try JSONEncoder().encode(item)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("Expected JSON object")
        }
        XCTAssertNotNil(obj["title"])
        XCTAssertNotNil(obj["due_hint"])
        XCTAssertNotNil(obj["notes"])
        XCTAssertNotNil(obj["reminder_id"])
        XCTAssertNil(obj["dueHint"])
        XCTAssertNil(obj["reminderId"])
    }

    func testCapturedMemoCodingKeysAreSnakeCase() throws {
        let memo = CapturedMemo(id: "x", title: "Memo", durationSeconds: 12.5)
        let data = try JSONEncoder().encode(memo)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("Expected JSON object")
        }
        XCTAssertNotNil(obj["duration_seconds"])
        XCTAssertNil(obj["durationSeconds"])
    }

    func testMemosCaptureResultCodingKeysAreSnakeCase() throws {
        let payload = MemosCaptureResult(
            memo: CapturedMemo(id: "x", title: "M", durationSeconds: 1.0),
            transcriptionChars: 42,
            items: [],
            createdCount: 0,
            list: "Inbox",
            dryRun: true
        )
        let data = try JSONEncoder().encode(payload)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("Expected JSON object")
        }
        XCTAssertNotNil(obj["transcription_chars"])
        XCTAssertNotNil(obj["created_count"])
        XCTAssertNotNil(obj["dry_run"])
        XCTAssertNil(obj["transcriptionChars"])
        XCTAssertNil(obj["createdCount"])
        XCTAssertNil(obj["dryRun"])
    }
}
