import XCTest

/// Integration tests that run the actual `pippin` binary via Process.
///
/// The binary must be built before these tests run. In CI the build step
/// precedes `swift test`. Locally, run `swift build` first.
///
/// Tests are skipped (not failed) when the binary is absent so that
/// `swift test` still works without a prior build step.
final class CLIIntegrationTests: XCTestCase {
    nonisolated(unsafe) static var binaryURL: URL?

    override class func setUp() {
        super.setUp()
        // Locate binary from `swift build --show-bin-path`
        let result = runProcess("/usr/bin/swift", args: ["build", "--show-bin-path"])
        guard result.exitCode == 0,
              let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else { return }
        let url = URL(fileURLWithPath: path).appendingPathComponent("pippin")
        if FileManager.default.fileExists(atPath: url.path) {
            binaryURL = url
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func run(_ args: [String]) -> (stdout: String, stderr: String, exitCode: Int32) {
        guard let binary = CLIIntegrationTests.binaryURL else {
            return ("", "", 0)
        }
        return Self.runProcess(binary.path, args: args)
    }

    private func requireBinary(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        if CLIIntegrationTests.binaryURL == nil {
            XCTFail("pippin binary not found — run `swift build` before running integration tests", file: file, line: line)
            return false
        }
        return true
    }

    @discardableResult
    static func runProcess(_ executable: String, args: [String]) -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        guard (try? process.run()) != nil else {
            return ("", "failed to launch \(executable)", -1)
        }
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (stdout, stderr, process.terminationStatus)
    }

    // MARK: - Version

    func testVersionFlag() {
        guard requireBinary() else { return }
        let result = run(["--version"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("0.13"), "Expected version string in output, got: \(result.stdout)")
    }

    // MARK: - Help

    func testRootHelp() {
        guard requireBinary() else { return }
        let result = run(["--help"])
        XCTAssertEqual(result.exitCode, 0)
        let combined = result.stdout + result.stderr
        XCTAssertTrue(combined.contains("mail") || combined.contains("USAGE"), "Expected help output, got: \(combined)")
    }

    func testMailHelp() {
        guard requireBinary() else { return }
        let result = run(["mail", "--help"])
        XCTAssertEqual(result.exitCode, 0)
        let combined = result.stdout + result.stderr
        XCTAssertTrue(combined.contains("list") || combined.contains("SUBCOMMANDS"), "Expected mail subcommand list, got: \(combined)")
    }

    func testMemosHelp() {
        guard requireBinary() else { return }
        let result = run(["memos", "--help"])
        XCTAssertEqual(result.exitCode, 0)
        let combined = result.stdout + result.stderr
        XCTAssertTrue(combined.contains("list") || combined.contains("SUBCOMMANDS"), "Expected memos subcommand list, got: \(combined)")
    }

    func testDoctorHelp() {
        guard requireBinary() else { return }
        let result = run(["doctor", "--help"])
        XCTAssertEqual(result.exitCode, 0)
        let combined = result.stdout + result.stderr
        XCTAssertTrue(combined.contains("doctor") || combined.contains("USAGE"), "Expected doctor help output, got: \(combined)")
    }

    func testInitHelp() {
        guard requireBinary() else { return }
        let result = run(["init", "--help"])
        XCTAssertEqual(result.exitCode, 0)
        let combined = result.stdout + result.stderr
        XCTAssertTrue(combined.contains("init") || combined.contains("USAGE"), "Expected init help output, got: \(combined)")
    }

    // MARK: - Subcommand help pages

    func testMailListHelp() {
        guard requireBinary() else { return }
        let result = run(["mail", "list", "--help"])
        XCTAssertEqual(result.exitCode, 0)
        let combined = result.stdout + result.stderr
        XCTAssertTrue(combined.contains("--limit") || combined.contains("limit"), "Expected --limit flag in help, got: \(combined)")
    }

    func testMemosListHelp() {
        guard requireBinary() else { return }
        let result = run(["memos", "list", "--help"])
        XCTAssertEqual(result.exitCode, 0)
        let combined = result.stdout + result.stderr
        XCTAssertTrue(combined.contains("--limit") || combined.contains("limit"), "Expected --limit flag in help, got: \(combined)")
    }

    func testCalendarHelp() {
        guard requireBinary() else { return }
        let result = run(["calendar", "--help"])
        XCTAssertEqual(result.exitCode, 0)
        let combined = result.stdout + result.stderr
        XCTAssertTrue(
            combined.contains("events") || combined.contains("SUBCOMMANDS"),
            "Expected calendar subcommand list, got: \(combined)"
        )
    }

    func testCalendarEventsHelp() {
        guard requireBinary() else { return }
        let result = run(["calendar", "events", "--help"])
        XCTAssertEqual(result.exitCode, 0)
        let combined = result.stdout + result.stderr
        XCTAssertTrue(
            combined.contains("--from") || combined.contains("from"),
            "Expected --from flag in help, got: \(combined)"
        )
    }

    // MARK: - Invalid input

    func testUnknownSubcommandExitsNonZero() {
        guard requireBinary() else { return }
        let result = run(["totally-invalid-subcommand"])
        XCTAssertNotEqual(result.exitCode, 0)
    }

    func testMailListInvalidFormatExitsNonZero() {
        guard requireBinary() else { return }
        let result = run(["mail", "list", "--format", "xml"])
        XCTAssertNotEqual(result.exitCode, 0)
    }

    // MARK: - Doctor agent format

    func testDoctorFormatAgent() throws {
        guard requireBinary() else { return }
        let result = run(["doctor", "--format", "agent"])
        // doctor may exit 0 or 1 depending on system state — both are valid
        let data = try XCTUnwrap(result.stdout.data(using: .utf8))
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            XCTFail("doctor --format agent must output a valid JSON array, got: \(result.stdout)")
            return
        }
        XCTAssertGreaterThan(json.count, 0, "Expected at least one check in output")
        for check in json {
            XCTAssertNotNil(check["name"], "Each check must have a 'name' field")
            XCTAssertNotNil(check["status"], "Each check must have a 'status' field")
            XCTAssertNotNil(check["detail"], "Each check must have a 'detail' field")
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
