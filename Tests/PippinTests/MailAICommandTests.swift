import ArgumentParser
@testable import PippinLib
import XCTest

final class MailAICommandTests: XCTestCase {
    func testIndexSubcommandRegistered() {
        let subcommands = MailCommand.configuration.subcommands
        let names = subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("index"), "Expected 'index' in subcommands, got: \(names)")
    }

    func testIndexDefaultLimit() throws {
        let cmd = try MailCommand.Index.parse([])
        XCTAssertEqual(cmd.limit, 500)
    }

    func testIndexCustomLimit() throws {
        let cmd = try MailCommand.Index.parse(["--limit", "50"])
        XCTAssertEqual(cmd.limit, 50)
    }

    func testIndexDefaultProvider() throws {
        let cmd = try MailCommand.Index.parse([])
        XCTAssertEqual(cmd.provider, "ollama")
    }

    func testIndexDefaultMailbox() throws {
        let cmd = try MailCommand.Index.parse([])
        XCTAssertEqual(cmd.mailbox, "INBOX")
    }

    func testIndexAcceptsFormat() throws {
        XCTAssertNoThrow(try MailCommand.Index.parse(["--format", "json"]))
    }

    func testIndexAcceptsAccount() throws {
        XCTAssertNoThrow(try MailCommand.Index.parse(["--account", "me@example.com"]))
    }

    // MARK: - Phase 2 tests

    func testSanitizeSubcommandRegistered() {
        let subcommands = MailCommand.configuration.subcommands
        let names = subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("sanitize"), "Expected 'sanitize' in subcommands, got: \(names)")
    }

    func testSanitizeParsesWithMessageId() throws {
        let cmd = try MailCommand.Sanitize.parse(["msg123"])
        XCTAssertEqual(cmd.messageId, "msg123")
    }

    func testSanitizeAiAssistedFlagDefault() throws {
        let cmd = try MailCommand.Sanitize.parse(["msg123"])
        XCTAssertFalse(cmd.aiAssisted, "ai-assisted should default to false")
    }

    func testSanitizeAcceptsFormat() throws {
        XCTAssertNoThrow(try MailCommand.Sanitize.parse(["msg123", "--format", "json"]))
    }

    func testShowSanitizeFlagDefault() throws {
        let cmd = try MailCommand.Show.parse(["msg123"])
        XCTAssertFalse(cmd.sanitize, "sanitize should default to false")
    }

    // MARK: - Phase 3: Extract

    func testExtractSubcommandRegistered() {
        let subcommands = MailCommand.configuration.subcommands
        let names = subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("extract"), "Expected 'extract' in subcommands, got: \(names)")
    }

    func testExtractParsesWithMessageId() throws {
        XCTAssertNoThrow(try MailCommand.Extract.parse(["some-id"]))
    }

    func testExtractAcceptsProvider() throws {
        XCTAssertNoThrow(try MailCommand.Extract.parse(["id", "--provider", "claude"]))
    }

    func testExtractAcceptsFormat() throws {
        XCTAssertNoThrow(try MailCommand.Extract.parse(["id", "--format", "json"]))
    }

    // MARK: - Phase 4: Triage

    func testTriageSubcommandRegistered() {
        let subcommands = MailCommand.configuration.subcommands
        let names = subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("triage"), "Expected 'triage' in subcommands, got: \(names)")
    }

    func testTriageParsesDefaults() throws {
        let cmd = try MailCommand.Triage.parse([])
        XCTAssertEqual(cmd.limit, 20)
        XCTAssertEqual(cmd.mailbox, "INBOX")
        XCTAssertNil(cmd.account)
        XCTAssertNil(cmd.provider)
    }

    func testTriageCustomLimit() throws {
        let cmd = try MailCommand.Triage.parse(["--limit", "5"])
        XCTAssertEqual(cmd.limit, 5)
    }

    func testTriageLimitRejectsZero() throws {
        XCTAssertThrowsError(try MailCommand.Triage.parse(["--limit", "0"]))
    }

    func testShowSummarizeFlagDefault() throws {
        let cmd = try MailCommand.Show.parse(["msg123"])
        XCTAssertFalse(cmd.summarize, "--summarize should default to false")
    }

    func testListSummarizeFlagDefault() throws {
        let cmd = try MailCommand.List.parse([])
        XCTAssertFalse(cmd.summarize, "--summarize on list should default to false")
    }

    // MARK: - Phase 5: Semantic Search

    func testSearchSemanticFlagDefault() throws {
        let cmd = try MailCommand.Search.parse(["somequery"])
        XCTAssertFalse(cmd.semantic, "--semantic should default to false")
    }

    func testSearchSemanticFlagParsed() throws {
        let cmd = try MailCommand.Search.parse(["somequery", "--semantic"])
        XCTAssertTrue(cmd.semantic, "--semantic flag should parse to true")
    }

    func testSearchEmbeddingModelOption() throws {
        let cmd = try MailCommand.Search.parse(["somequery", "--semantic", "--embedding-model", "nomic-embed-text"])
        XCTAssertEqual(cmd.embeddingModel, "nomic-embed-text")
    }

    func testSearchOllamaUrlOption() throws {
        let cmd = try MailCommand.Search.parse(["query", "--semantic", "--ollama-url", "http://localhost:11435"])
        XCTAssertEqual(cmd.ollamaUrl, "http://localhost:11435")
    }

    func testSearchProviderOption() throws {
        let cmd = try MailCommand.Search.parse(["query", "--semantic", "--provider", "ollama"])
        XCTAssertEqual(cmd.provider, "ollama")
    }

    func testSearchProviderDefaultsToOllama() throws {
        let cmd = try MailCommand.Search.parse(["somequery"])
        XCTAssertEqual(cmd.provider, "ollama")
    }
}
