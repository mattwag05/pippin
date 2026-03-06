@testable import PippinLib
import XCTest

/// Minimal fake AI provider for testing the summarize flow without network calls.
struct FakeAIProvider: AIProvider {
    let response: String
    func complete(prompt _: String, system _: String) throws -> String {
        response
    }
}

struct AlwaysFailAIProvider: AIProvider {
    func complete(prompt _: String, system _: String) throws -> String {
        throw AIProviderError.networkError("simulated failure")
    }
}

final class SummarizeTests: XCTestCase {
    // MARK: - SummarizeResult encoding

    func testSummarizeResultEncoding() throws {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let result = SummarizeResult(
            id: "ABC-123",
            title: "Team standup",
            createdAt: createdAt,
            summary: "The team discussed sprint goals.",
            template: "meeting-notes",
            provider: "ollama"
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(SummarizeResult.self, from: data)
        XCTAssertEqual(decoded.id, result.id)
        XCTAssertEqual(decoded.title, result.title)
        XCTAssertEqual(decoded.createdAt, result.createdAt)
        XCTAssertEqual(decoded.summary, result.summary)
        XCTAssertEqual(decoded.template, result.template)
        XCTAssertEqual(decoded.provider, result.provider)
    }

    func testSummarizeResultNilTemplate() throws {
        let result = SummarizeResult(
            id: "XYZ",
            title: "Free-form",
            createdAt: Date(timeIntervalSince1970: 0),
            summary: "A summary.",
            template: nil,
            provider: "claude"
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(SummarizeResult.self, from: data)
        XCTAssertNil(decoded.template)
    }

    // MARK: - ExportSidecarFormat

    func testSidecarFormatExtensions() {
        XCTAssertEqual(ExportSidecarFormat.txt.fileExtension, "txt")
        XCTAssertEqual(ExportSidecarFormat.srt.fileExtension, "srt")
        XCTAssertEqual(ExportSidecarFormat.markdown.fileExtension, "md")
        XCTAssertEqual(ExportSidecarFormat.rtf.fileExtension, "rtf")
    }

    func testSidecarFormatRawValues() {
        XCTAssertNotNil(ExportSidecarFormat(rawValue: "txt"))
        XCTAssertNotNil(ExportSidecarFormat(rawValue: "srt"))
        XCTAssertNotNil(ExportSidecarFormat(rawValue: "markdown"))
        XCTAssertNotNil(ExportSidecarFormat(rawValue: "rtf"))
        XCTAssertNil(ExportSidecarFormat(rawValue: "pdf"))
    }

    // MARK: - Sidecar writing

    func testWriteSidecarTxt() throws {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let path = (dir as NSString).appendingPathComponent("test.txt")
        let memo = makeMemo()
        try VoiceMemosDB.writeSidecar(text: "Hello world", format: .txt, path: path, memo: memo)
        let written = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(written, "Hello world")
    }

    func testWriteSidecarMarkdown() throws {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let path = (dir as NSString).appendingPathComponent("test.md")
        let memo = makeMemo(title: "My Meeting", durationSeconds: 300)
        try VoiceMemosDB.writeSidecar(text: "Transcript content", format: .markdown, path: path, memo: memo)

        let written = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(written.contains("# My Meeting"), "Missing heading")
        XCTAssertTrue(written.contains("Transcript content"), "Missing transcript body")
        XCTAssertTrue(written.contains("Duration:"), "Missing duration field")
    }

    func testWriteSidecarSRT() throws {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let path = (dir as NSString).appendingPathComponent("test.srt")
        let memo = makeMemo(durationSeconds: 65)
        try VoiceMemosDB.writeSidecar(text: "Some speech", format: .srt, path: path, memo: memo)

        let written = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(written.contains("1"), "Missing sequence number")
        XCTAssertTrue(written.contains("-->"), "Missing SRT time arrow")
        XCTAssertTrue(written.contains("Some speech"), "Missing transcript text")
    }

    func testWriteSidecarRTF() throws {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let path = (dir as NSString).appendingPathComponent("test.rtf")
        let memo = makeMemo()
        try VoiceMemosDB.writeSidecar(text: "RTF content", format: .rtf, path: path, memo: memo)

        let written = try String(contentsOfFile: path, encoding: .ascii)
        XCTAssertTrue(written.contains("{\\rtf"), "Missing RTF header")
        XCTAssertTrue(written.contains("RTF content"), "Missing text")
    }

    // MARK: - Helpers

    private func makeMemo(
        title: String = "Test Memo",
        durationSeconds: Double = 120,
        createdAt: Date = Date(timeIntervalSince1970: 0)
    ) -> VoiceMemo {
        VoiceMemo(
            id: "test-memo-id",
            title: title,
            durationSeconds: durationSeconds,
            createdAt: createdAt,
            filePath: "test.m4a"
        )
    }
}
