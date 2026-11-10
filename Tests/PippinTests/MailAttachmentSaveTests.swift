@testable import PippinLib
import XCTest

/// Where saved attachments land and what they are called (RC-07).
final class MailAttachmentSaveTests: XCTestCase {
    private var root: URL!
    private var saveDir: URL!
    private var staging: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pippin-attach-\(UUID().uuidString)").resolvingSymlinksInPath()
        saveDir = root.appendingPathComponent("out")
        staging = saveDir.appendingPathComponent(".staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A row as the script returns it after saving `contents` under its index.
    private func staged(_ name: String, index: Int, contents: String = "data") throws -> Attachment {
        let path = staging.appendingPathComponent(String(index)).path
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return Attachment(name: name, mimeType: "text/plain", size: contents.utf8.count, savedPath: path)
    }

    private func read(_ path: String?) throws -> String {
        try String(contentsOfFile: XCTUnwrap(path), encoding: .utf8)
    }

    // MARK: - Names

    func testSafeNameKeepsOnlyTheLastPathComponent() {
        XCTAssertEqual(MailBridge.safeAttachmentName("../../Library/LaunchAgents/evil.plist", index: 0), "evil.plist")
        XCTAssertEqual(MailBridge.safeAttachmentName("C:\\Users\\x\\report.pdf", index: 0), "report.pdf")
        XCTAssertEqual(MailBridge.safeAttachmentName("/etc/passwd", index: 0), "passwd")
        XCTAssertEqual(MailBridge.safeAttachmentName("plain name.txt", index: 0), "plain name.txt")
    }

    func testSafeNameStripsLeadingDotsAndHiddenCharacters() {
        XCTAssertEqual(MailBridge.safeAttachmentName(".zshrc", index: 0), "zshrc")
        XCTAssertEqual(MailBridge.safeAttachmentName("...hidden", index: 0), "hidden")
        XCTAssertEqual(MailBridge.safeAttachmentName("a\u{0}b\nc\u{7}.txt", index: 0), "abc.txt")
        XCTAssertEqual(MailBridge.safeAttachmentName("invoice\u{202E}fdp.exe", index: 0), "invoicefdp.exe")
    }

    func testSafeNameFallsBackWhenNothingIsLeft() {
        for empty in ["", "..", ".", "/", "../", " . ", "\u{0}"] {
            XCTAssertEqual(MailBridge.safeAttachmentName(empty, index: 2), "attachment-3", "\(empty.debugDescription)")
        }
    }

    // MARK: - Finalizing

    func testTraversalNameLandsInsideTheSaveDirectory() throws {
        let outside = root.appendingPathComponent("evil.plist")
        let result = try MailBridge.finalizeSavedAttachments(
            [staged("../evil.plist", index: 0)], saveDir: saveDir.path
        )
        XCTAssertEqual(result[0].savedPath, saveDir.appendingPathComponent("evil.plist").path)
        XCTAssertNil(result[0].saveError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertEqual(result[0].name, "../evil.plist", "the reported name stays what the sender sent")
    }

    func testExistingFileIsNeverOverwritten() throws {
        let existing = saveDir.appendingPathComponent("report.pdf")
        try "mine".write(to: existing, atomically: true, encoding: .utf8)
        let result = try MailBridge.finalizeSavedAttachments(
            [staged("report.pdf", index: 0, contents: "theirs")], saveDir: saveDir.path
        )
        XCTAssertEqual(try read(existing.path), "mine")
        XCTAssertEqual(result[0].savedPath, saveDir.appendingPathComponent("report (1).pdf").path)
        XCTAssertEqual(try read(result[0].savedPath), "theirs")
    }

    func testSameNamedAttachmentsDoNotOverwriteEachOther() throws {
        let result = try MailBridge.finalizeSavedAttachments(
            [
                staged("image.png", index: 0, contents: "one"),
                staged("image.png", index: 1, contents: "two"),
                staged("README", index: 2, contents: "three"),
                staged("README", index: 3, contents: "four"),
            ],
            saveDir: saveDir.path
        )
        XCTAssertEqual(
            result.map { $0.savedPath.map { URL(fileURLWithPath: $0).lastPathComponent } },
            ["image.png", "image (1).png", "README", "README (1)"]
        )
        XCTAssertEqual(try result.map { try read($0.savedPath) }, ["one", "two", "three", "four"])
    }

    func testDanglingSymlinkAtTheTargetIsNotFollowed() throws {
        let outside = root.appendingPathComponent("target.txt")
        try FileManager.default.createSymbolicLink(
            atPath: saveDir.appendingPathComponent("a.txt").path, withDestinationPath: outside.path
        )
        let result = try MailBridge.finalizeSavedAttachments([staged("a.txt", index: 0)], saveDir: saveDir.path)
        XCTAssertEqual(result[0].savedPath, saveDir.appendingPathComponent("a (1).txt").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    func testFailedSaveIsReportedPerAttachment() throws {
        let failed = Attachment(name: "a.txt", mimeType: "text/plain", size: 4, savedPath: nil, saveError: "boom")
        let missing = Attachment(
            name: "gone.txt", mimeType: "text/plain", size: 4, savedPath: staging.appendingPathComponent("9").path
        )
        let result = try MailBridge.finalizeSavedAttachments(
            [failed, staged("b.txt", index: 1), missing], saveDir: saveDir.path
        )
        XCTAssertEqual(result.map(\.saveError), ["boom", nil, "Mail did not write the file"])
        XCTAssertEqual(result.map { $0.savedPath != nil }, [false, true, false])
        let encoded = try String(decoding: JSONEncoder().encode(result[1]), as: UTF8.self)
        XCTAssertFalse(encoded.contains("saveError"), "omitted when the save worked")
    }
}
