@testable import PippinLib
import XCTest

final class TemplateTests: XCTestCase {
    // MARK: - Built-in templates

    func testBuiltInTemplatesCount() {
        XCTAssertEqual(BuiltInTemplates.all.count, 8)
    }

    func testBuiltInTemplateNames() {
        let names = BuiltInTemplates.all.map(\.name)
        XCTAssertTrue(names.contains("meeting-notes"))
        XCTAssertTrue(names.contains("action-items"))
        XCTAssertTrue(names.contains("summary"))
        XCTAssertTrue(names.contains("key-decisions"))
        XCTAssertTrue(names.contains("brainstorm"))
    }

    func testBuiltInTemplatesHaveContent() {
        for template in BuiltInTemplates.all {
            XCTAssertFalse(template.content.isEmpty, "\(template.name) has empty content")
            XCTAssertFalse(template.description.isEmpty, "\(template.name) has empty description")
        }
    }

    // MARK: - TemplateManager — built-in resolution

    func testResolveBuiltInTemplate() throws {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        let manager = TemplateManager(templatesDir: dir)
        let template = try manager.resolve(name: "summary")
        XCTAssertEqual(template.name, "summary")
        XCTAssertTrue(template.isBuiltIn)
    }

    func testResolveUnknownTemplateThrows() {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        let manager = TemplateManager(templatesDir: dir)
        XCTAssertThrowsError(try manager.resolve(name: "nonexistent")) { error in
            XCTAssertTrue(error is TemplateError)
        }
    }

    func testAllTemplatesReturnsBuiltIns() {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        let manager = TemplateManager(templatesDir: dir)
        let all = manager.allTemplates()
        XCTAssertEqual(all.count, 8)
        XCTAssertTrue(all.allSatisfy(\.isBuiltIn))
    }

    // MARK: - TemplateManager — user templates

    func testUserTemplatePlainContent() throws {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let content = "You are a plain summarizer.\nBe concise."
        let path = (dir as NSString).appendingPathComponent("plain.md")
        try content.write(toFile: path, atomically: true, encoding: .utf8)

        let manager = TemplateManager(templatesDir: dir)
        let all = manager.allTemplates()
        XCTAssertEqual(all.count, 9) // 8 built-in + 1 user
        let user = try XCTUnwrap(all.last)
        XCTAssertEqual(user.name, "plain")
        XCTAssertFalse(user.isBuiltIn)
        XCTAssertEqual(user.content, content)
    }

    func testUserTemplateWithFrontmatter() throws {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let fileContent = """
        ---
        name: my-template
        description: My custom template
        ---
        Extract all names from the transcript.
        """
        let path = (dir as NSString).appendingPathComponent("my-template.md")
        try fileContent.write(toFile: path, atomically: true, encoding: .utf8)

        let manager = TemplateManager(templatesDir: dir)
        let template = try manager.resolve(name: "my-template")
        XCTAssertEqual(template.name, "my-template")
        XCTAssertEqual(template.description, "My custom template")
        XCTAssertEqual(template.content, "Extract all names from the transcript.")
        XCTAssertFalse(template.isBuiltIn)
    }

    func testAddTemplate() throws {
        let sourceDir = NSTemporaryDirectory() + UUID().uuidString
        let destDir = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: sourceDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: sourceDir)
            try? FileManager.default.removeItem(atPath: destDir)
        }

        let sourcePath = (sourceDir as NSString).appendingPathComponent("custom.md")
        try "Custom template content".write(toFile: sourcePath, atomically: true, encoding: .utf8)

        let manager = TemplateManager(templatesDir: destDir)
        let destPath = try manager.addTemplate(fromPath: sourcePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destPath))
        XCTAssertTrue(destPath.hasSuffix("custom.md"))
    }

    // MARK: - TemplateError descriptions

    func testTemplateErrorDescriptions() {
        XCTAssertNotNil(TemplateError.notFound("foo").errorDescription)
        XCTAssertNotNil(TemplateError.invalidFrontmatter("bad").errorDescription)
    }
}
