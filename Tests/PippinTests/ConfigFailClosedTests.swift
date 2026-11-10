@testable import PippinLib
import XCTest

/// A config.json that exists but does not parse must stop Messages reads and
/// exclude-list edits, and must never be rewritten.
final class ConfigFailClosedTests: XCTestCase {
    private var sandbox: MessagesCommandSandbox!
    /// Truncated mid-object. (A trailing comma is not enough: Foundation's decoder accepts one.)
    private static let broken = #"{"ai":{"provider":"claude"},"messages":{"excludedThreads":["iMessage;-;groupA"]"#

    override func setUpWithError() throws {
        sandbox = try MessagesCommandSandbox()
    }

    override func tearDown() {
        unsetenv("PIPPIN_AUTONOMOUS_MESSAGES")
        sandbox.tearDown()
    }

    private func assertInvalidConfig(
        _ run: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await run()
            XCTFail("expected invalid_config", file: file, line: line)
        } catch {
            XCTAssertEqual(agentErrorCode(for: error), "invalid_config", "\(error)", file: file, line: line)
            let action = (error as? RemediableError)?.nextStep.humanAction ?? ""
            XCTAssertTrue(action.contains(sandbox.configPath), "next_step names the file: \(action)", file: file, line: line)
        }
    }

    // MARK: - Reads fail closed

    func testMessagesReadsRefuseAnUnparseableConfig() async throws {
        try sandbox.writeConfig(Self.broken)
        await assertInvalidConfig {
            var cmd = try MessagesCommand.List.parse(["--since-hours", "1000000", "--no-contacts"])
            _ = try await cmd.execute()
        }
        await assertInvalidConfig {
            var cmd = try MessagesCommand.Search.parse(["lunch", "--since-hours", "1000000", "--no-contacts"])
            _ = try await cmd.execute()
        }
        await assertInvalidConfig {
            var cmd = try MessagesCommand.Show.parse(["iMessage;-;groupA", "--no-contacts"])
            _ = try await cmd.execute()
        }
        await assertInvalidConfig {
            var cmd = try MessagesCommand.ExcludeList.parse([])
            _ = try await cmd.execute()
        }
    }

    func testAutonomousSendGateReportsAnUnparseableConfig() async throws {
        // The broken config can never satisfy the allowlist, so nothing is sent.
        try sandbox.writeConfig(Self.broken)
        setenv("PIPPIN_AUTONOMOUS_MESSAGES", "1", 1)
        await assertInvalidConfig {
            var cmd = try MessagesCommand.Send.parse(["--to", "+15551234567", "--body", "hi", "--autonomous"])
            _ = try await cmd.execute()
        }
    }

    func testAIProviderReportsAnUnparseableConfig() async throws {
        try sandbox.writeConfig(Self.broken)
        await assertInvalidConfig { _ = try AIProviderFactory.make() }
        await assertInvalidConfig { _ = try AIProviderFactory.makeEmbeddingProvider() }
        await assertInvalidConfig { _ = try AIProviderFactory.makeTranscriber() }
    }

    // MARK: - Exclude edits never rewrite a file they could not parse

    func testExcludeAddAndRemoveLeaveAnUnparseableConfigUntouched() async throws {
        try sandbox.writeConfig(Self.broken)
        await assertInvalidConfig {
            var cmd = try MessagesCommand.ExcludeAdd.parse(["iMessage;-;other"])
            _ = try await cmd.execute()
        }
        await assertInvalidConfig {
            var cmd = try MessagesCommand.ExcludeRemove.parse(["iMessage;-;groupA"])
            _ = try await cmd.execute()
        }
        XCTAssertEqual(try String(contentsOfFile: sandbox.configPath, encoding: .utf8), Self.broken)
    }

    // MARK: - Absent and valid configs still work

    func testAbsentConfigMeansDefaults() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.configPath))
        var list = try MessagesCommand.List.parse(["--since-hours", "1000000", "--no-contacts"])
        let listed = try await list.execute()
        let rows = try XCTUnwrap(listed.payload as? [MessageConversation])
        XCTAssertEqual(rows.count, 2)

        var add = try MessagesCommand.ExcludeAdd.parse(["iMessage;-;groupA"])
        _ = try await add.execute()
        XCTAssertEqual(
            AIProviderFactory.loadConfig(path: sandbox.configPath)?.messages?.excludedThreads, ["iMessage;-;groupA"]
        )
    }

    func testExcludeAddKeepsTheRestOfAValidConfig() async throws {
        try sandbox.writeConfig(#"{"ai":{"provider":"claude"},"messages":{"autonomousAllowlist":["+15550000000"]}}"#)
        var add = try MessagesCommand.ExcludeAdd.parse(["iMessage;-;groupA"])
        _ = try await add.execute()
        let config = try XCTUnwrap(AIProviderFactory.loadConfig(path: sandbox.configPath))
        XCTAssertEqual(config.ai?.provider, "claude")
        XCTAssertEqual(config.messages?.autonomousAllowlist, ["+15550000000"])
        XCTAssertEqual(config.messages?.excludedThreads, ["iMessage;-;groupA"])
    }

    // MARK: - Save is private and leaves no debris

    private func mode(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try XCTUnwrap(attributes[.posixPermissions] as? Int)
    }

    func testSaveConfigWritesMode0600AndNoTempFiles() throws {
        try AIProviderFactory.saveConfig(PippinConfig(), path: sandbox.configPath)
        XCTAssertEqual(try mode(sandbox.configPath), 0o600, "new file")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sandbox.configPath)
        try AIProviderFactory.saveConfig(PippinConfig(), path: sandbox.configPath)
        XCTAssertEqual(try mode(sandbox.configPath), 0o600, "replacing a wider file")

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: sandbox.dir)
            .filter { $0.hasPrefix("config.json") && $0 != "config.json" }
        XCTAssertEqual(leftovers, [])
    }

    func testSaveConfigThroughASymlinkKeepsTheLink() throws {
        let real = sandbox.dir + "/real-config.json"
        try "{}".write(toFile: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: sandbox.configPath, withDestinationPath: real)
        var config = PippinConfig()
        config.resolveContacts = false
        try AIProviderFactory.saveConfig(config, path: sandbox.configPath)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: sandbox.configPath), real)
        XCTAssertEqual(AIProviderFactory.loadConfig(path: real)?.resolveContacts, false)
    }
}
