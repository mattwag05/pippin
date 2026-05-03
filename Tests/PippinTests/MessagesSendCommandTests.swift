@testable import PippinLib
import XCTest

final class MessagesSendCommandTests: XCTestCase {
    func testAutonomousWithoutEnvThrows() async throws {
        let saved = ProcessInfo.processInfo.environment["PIPPIN_AUTONOMOUS_MESSAGES"]
        unsetenv("PIPPIN_AUTONOMOUS_MESSAGES")
        defer {
            if let saved { setenv("PIPPIN_AUTONOMOUS_MESSAGES", saved, 1) }
        }

        var cmd = try MessagesCommand.Send.parse([
            "--to", "+15551234567",
            "--body", "hi",
            "--autonomous",
            "--format", "agent",
        ])

        do {
            try await cmd.run()
            XCTFail("expected autonomousNotAuthorized")
        } catch MessagesSendError.autonomousNotAuthorized {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testPHIFilteredBodyBlocksDraftAndRecordsAudit() async throws {
        let tmpAudit = NSTemporaryDirectory() + "messages-audit-\(UUID().uuidString).jsonl"
        setenv("PIPPIN_MESSAGES_AUDIT_PATH", tmpAudit, 1)
        defer {
            unsetenv("PIPPIN_MESSAGES_AUDIT_PATH")
            try? FileManager.default.removeItem(atPath: tmpAudit)
        }

        var cmd = try MessagesCommand.Send.parse([
            "--to", "+15551234567",
            "--body", "password: hunter2",
            "--draft",
            "--format", "agent",
        ])

        do {
            try await cmd.run()
            XCTFail("expected phiFiltered")
        } catch let MessagesSendError.phiFiltered(cats) {
            XCTAssertTrue(cats.contains("password_mention"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        // Audit log must be written with the password_mention override category.
        let log = try String(contentsOfFile: tmpAudit, encoding: .utf8)
        XCTAssertTrue(log.contains("password_mention"), "audit entry missing category; got: \(log)")
        XCTAssertTrue(log.contains("\"sent\":false"), "audit entry should record sent=false")
    }
}
