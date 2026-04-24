@testable import PippinLib
import XCTest

/// Tests for ArgumentParser `validate()` logic in MemosCommand subcommands.
final class MemosCommandTests: XCTestCase {
    // MARK: - Configuration

    func testMemosCommandName() {
        XCTAssertEqual(MemosCommand.configuration.commandName, "memos")
    }

    func testMemosHasExpectedSubcommands() {
        let names = MemosCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("list"))
        XCTAssertTrue(names.contains("info"))
        XCTAssertTrue(names.contains("export"))
        XCTAssertTrue(names.contains("transcribe"))
        XCTAssertTrue(names.contains("delete"))
        XCTAssertTrue(names.contains("templates"))
        XCTAssertTrue(names.contains("summarize"))
        XCTAssertTrue(names.contains("capture"))
    }

    // MARK: - List

    func testListCommandName() {
        XCTAssertEqual(MemosCommand.List.configuration.commandName, "list")
    }

    func testListNoArgsPasses() {
        XCTAssertNoThrow(try MemosCommand.List.parse([]))
    }

    func testListDefaultLimit() throws {
        let cmd = try MemosCommand.List.parse([])
        XCTAssertEqual(cmd.limit, 20)
    }

    func testListCustomLimit() throws {
        let cmd = try MemosCommand.List.parse(["--limit", "50"])
        XCTAssertEqual(cmd.limit, 50)
    }

    func testListZeroLimitFails() {
        XCTAssertThrowsError(try MemosCommand.List.parse(["--limit", "0"]))
    }

    func testListNegativeLimitFails() {
        XCTAssertThrowsError(try MemosCommand.List.parse(["--limit", "-1"]))
    }

    func testListSinceValidDatePasses() {
        XCTAssertNoThrow(try MemosCommand.List.parse(["--since", "2024-01-15"]))
    }

    func testListSinceInvalidDateFails() {
        XCTAssertThrowsError(try MemosCommand.List.parse(["--since", "not-a-date"]))
    }

    func testListSinceInvalidFormatFails() {
        XCTAssertThrowsError(try MemosCommand.List.parse(["--since", "15-01-2024"]))
    }

    func testListParsesSinceDate() throws {
        let cmd = try MemosCommand.List.parse(["--since", "2024-03-01"])
        XCTAssertEqual(cmd.since, "2024-03-01")
    }

    func testListJsonFormatPasses() {
        XCTAssertNoThrow(try MemosCommand.List.parse(["--format", "json"]))
    }

    func testListAgentFormatPasses() {
        XCTAssertNoThrow(try MemosCommand.List.parse(["--format", "agent"]))
    }

    // MARK: - List pagination flags (pippin-gb3)

    func testListParsesPageSize() throws {
        let cmd = try MemosCommand.List.parse(["--page-size", "10"])
        XCTAssertEqual(cmd.pagination.pageSize, 10)
        XCTAssertTrue(cmd.pagination.isActive)
    }

    func testListParsesCursor() throws {
        let token = try Pagination.encode(Cursor(offset: 5, filterHash: "abc"))
        let cmd = try MemosCommand.List.parse(["--cursor", token])
        XCTAssertEqual(cmd.pagination.cursor, token)
        XCTAssertTrue(cmd.pagination.isActive)
    }

    func testListPaginationInactiveByDefault() throws {
        let cmd = try MemosCommand.List.parse([])
        XCTAssertFalse(cmd.pagination.isActive)
        XCTAssertNil(cmd.pagination.cursor)
        XCTAssertNil(cmd.pagination.pageSize)
    }

    // MARK: - Info

    func testInfoCommandName() {
        XCTAssertEqual(MemosCommand.Info.configuration.commandName, "info")
    }

    func testInfoRequiresId() {
        XCTAssertThrowsError(try MemosCommand.Info.parse([]))
    }

    func testInfoWithIdPasses() {
        XCTAssertNoThrow(try MemosCommand.Info.parse(["abc123"]))
    }

    func testInfoParsesId() throws {
        let cmd = try MemosCommand.Info.parse(["abc123def"])
        XCTAssertEqual(cmd.id, "abc123def")
    }

    func testInfoJsonFormatPasses() {
        XCTAssertNoThrow(try MemosCommand.Info.parse(["some-id", "--format", "json"]))
    }

    func testInfoAgentFormatPasses() {
        XCTAssertNoThrow(try MemosCommand.Info.parse(["some-id", "--format", "agent"]))
    }

    // MARK: - Export

    func testExportCommandName() {
        XCTAssertEqual(MemosCommand.Export.configuration.commandName, "export")
    }

    func testExportWithoutIdOrAllFails() {
        XCTAssertThrowsError(try MemosCommand.Export.parse(["--output", "/tmp"]))
    }

    func testExportWithIdPasses() {
        XCTAssertNoThrow(try MemosCommand.Export.parse(["abc123", "--output", "/tmp"]))
    }

    func testExportWithAllPasses() {
        XCTAssertNoThrow(try MemosCommand.Export.parse(["--all", "--output", "/tmp"]))
    }

    func testExportDefaultSidecarFormat() throws {
        let cmd = try MemosCommand.Export.parse(["abc123", "--output", "/tmp"])
        XCTAssertEqual(cmd.sidecarFormat, "txt")
    }

    func testExportValidSidecarFormats() {
        for fmt in ["txt", "srt", "markdown", "rtf"] {
            XCTAssertNoThrow(
                try MemosCommand.Export.parse(["abc123", "--output", "/tmp", "--sidecar-format", fmt]),
                "Expected '\(fmt)' to be a valid sidecar format"
            )
        }
    }

    func testExportInvalidSidecarFormatFails() {
        XCTAssertThrowsError(try MemosCommand.Export.parse(["abc123", "--output", "/tmp", "--sidecar-format", "pdf"]))
    }

    func testExportAgentFormatPasses() {
        XCTAssertNoThrow(try MemosCommand.Export.parse(["abc123", "--output", "/tmp", "--format", "agent"]))
    }

    func testExportJsonFormatPasses() {
        XCTAssertNoThrow(try MemosCommand.Export.parse(["abc123", "--output", "/tmp", "--format", "json"]))
    }

    func testExportTranscribeFlagPasses() {
        XCTAssertNoThrow(try MemosCommand.Export.parse(["abc123", "--output", "/tmp", "--transcribe"]))
    }

    func testExportForceTranscribePasses() {
        XCTAssertNoThrow(try MemosCommand.Export.parse(["abc123", "--output", "/tmp", "--transcribe", "--force-transcribe"]))
    }

    func testExportDefaultJobs() throws {
        let cmd = try MemosCommand.Export.parse(["abc123", "--output", "/tmp"])
        XCTAssertEqual(cmd.jobs, 2)
    }

    func testExportCustomJobsPasses() throws {
        let cmd = try MemosCommand.Export.parse(["abc123", "--output", "/tmp", "--jobs", "4"])
        XCTAssertEqual(cmd.jobs, 4)
    }

    func testExportZeroJobsFails() {
        XCTAssertThrowsError(try MemosCommand.Export.parse(["abc123", "--output", "/tmp", "--jobs", "0"]))
    }

    // MARK: - Transcribe

    func testTranscribeCommandName() {
        XCTAssertEqual(MemosCommand.Transcribe.configuration.commandName, "transcribe")
    }

    func testTranscribeWithoutIdOrAllFails() {
        XCTAssertThrowsError(try MemosCommand.Transcribe.parse([]))
    }

    func testTranscribeWithIdPasses() {
        XCTAssertNoThrow(try MemosCommand.Transcribe.parse(["abc123"]))
    }

    func testTranscribeWithAllPasses() {
        XCTAssertNoThrow(try MemosCommand.Transcribe.parse(["--all"]))
    }

    func testTranscribeParsesId() throws {
        let cmd = try MemosCommand.Transcribe.parse(["abc123"])
        XCTAssertEqual(cmd.id, "abc123")
    }

    func testTranscribeDefaultJobs() throws {
        let cmd = try MemosCommand.Transcribe.parse(["abc123"])
        XCTAssertEqual(cmd.jobs, 2)
    }

    func testTranscribeCustomJobsPasses() throws {
        let cmd = try MemosCommand.Transcribe.parse(["abc123", "--jobs", "3"])
        XCTAssertEqual(cmd.jobs, 3)
    }

    func testTranscribeZeroJobsFails() {
        XCTAssertThrowsError(try MemosCommand.Transcribe.parse(["abc123", "--jobs", "0"]))
    }

    func testTranscribeForceFlagPasses() throws {
        let cmd = try MemosCommand.Transcribe.parse(["abc123", "--force"])
        XCTAssertTrue(cmd.force)
    }

    func testTranscribeForceDefaultFalse() throws {
        let cmd = try MemosCommand.Transcribe.parse(["abc123"])
        XCTAssertFalse(cmd.force)
    }

    func testTranscribeOutputOptionPasses() throws {
        let cmd = try MemosCommand.Transcribe.parse(["abc123", "--output", "/tmp/transcripts"])
        XCTAssertEqual(cmd.output, "/tmp/transcripts")
    }

    func testTranscribeJsonFormatPasses() {
        XCTAssertNoThrow(try MemosCommand.Transcribe.parse(["abc123", "--format", "json"]))
    }

    func testTranscribeAgentFormatPasses() {
        XCTAssertNoThrow(try MemosCommand.Transcribe.parse(["abc123", "--format", "agent"]))
    }

    // MARK: - Delete

    func testDeleteCommandName() {
        XCTAssertEqual(MemosCommand.Delete.configuration.commandName, "delete")
    }

    func testDeleteWithoutIdFails() {
        XCTAssertThrowsError(try MemosCommand.Delete.parse([]))
    }

    func testDeleteWithoutForceFails() {
        XCTAssertThrowsError(try MemosCommand.Delete.parse(["abc123"]))
    }

    func testDeleteWithForcePasses() {
        XCTAssertNoThrow(try MemosCommand.Delete.parse(["abc123", "--force"]))
    }

    func testDeleteParsesId() throws {
        let cmd = try MemosCommand.Delete.parse(["abc-xyz", "--force"])
        XCTAssertEqual(cmd.id, "abc-xyz")
    }

    func testDeleteForceDefaultFalse() throws {
        // Without --force, validate() should throw
        XCTAssertThrowsError(try MemosCommand.Delete.parse(["abc123"]))
    }

    func testDeleteJsonFormatPasses() {
        XCTAssertNoThrow(try MemosCommand.Delete.parse(["abc123", "--force", "--format", "json"]))
    }

    func testDeleteAgentFormatPasses() {
        XCTAssertNoThrow(try MemosCommand.Delete.parse(["abc123", "--force", "--format", "agent"]))
    }
}
