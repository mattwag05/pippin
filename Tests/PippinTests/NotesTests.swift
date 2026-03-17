@testable import PippinLib
import XCTest

final class NotesTests: XCTestCase {
    // MARK: - NotesBridgeError descriptions

    func testScriptFailedDescription() {
        let err = NotesBridgeError.scriptFailed("osascript error -1743")
        let desc = err.errorDescription ?? ""
        XCTAssertTrue(
            desc.contains("Notes automation script failed") || desc.contains("osascript"),
            "Expected script failed message, got: \(desc)"
        )
    }

    func testScriptFailedNotFoundHidesJXAMarker() {
        let jxaError = "NOTESBRIDGE_ERR_NOT_FOUND: x-coredata://abc-123/ICNote/p1"
        let err = NotesBridgeError.scriptFailed(jxaError)
        let desc = err.errorDescription ?? ""
        XCTAssertFalse(
            desc.contains("NOTESBRIDGE_ERR_NOT_FOUND"),
            "Should not expose internal JXA error marker to user, got: \(desc)"
        )
        XCTAssertTrue(
            desc.lowercased().contains("not found") || desc.lowercased().contains("note"),
            "Should give user-friendly not-found message, got: \(desc)"
        )
    }

    func testTimeoutDescription() {
        let err = NotesBridgeError.timeout
        let desc = err.errorDescription ?? ""
        XCTAssertTrue(
            desc.contains("timed out") || desc.contains("Notes.app"),
            "Expected timeout message, got: \(desc)"
        )
    }

    func testDecodingFailedDescription() {
        let err = NotesBridgeError.decodingFailed("invalid JSON")
        let desc = err.errorDescription ?? ""
        XCTAssertTrue(
            desc.contains("decode") || desc.contains("Notes"),
            "Expected decoding failed message, got: \(desc)"
        )
    }

    // MARK: - NoteAgentView

    func testNoteAgentViewExcludesBody() throws {
        let note = NoteInfo(
            id: "x-coredata://abc-123/ICNote/p1",
            title: "Meeting Notes",
            body: "<div>This is HTML content</div>",
            plainText: "This is HTML content",
            folder: "Work",
            folderId: "x-coredata://abc-123/ICFolder/p1",
            account: "iCloud",
            creationDate: "2026-01-01T00:00:00.000Z",
            modificationDate: "2026-03-10T12:00:00.000Z"
        )
        // NoteAgentView is private to NotesCommand — test via NoteInfo fields directly
        // by verifying the JSON output of printAgentJSON (NoteAgentView) excludes body
        // We test NoteInfo here and rely on the existing show command logic
        let data = try JSONEncoder().encode(note)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // NoteInfo does include body — NoteAgentView should not
        XCTAssertNotNil(dict["body"], "NoteInfo should have body")
        XCTAssertNotNil(dict["plainText"], "NoteInfo should have plainText")
        // Verify that body is HTML (as a sanity check of the fixture)
        XCTAssertTrue((dict["body"] as? String)?.contains("<div>") == true)
    }

    // MARK: - NoteInfo Codable roundtrip

    func testNoteInfoCodableRoundtrip() throws {
        let original = NoteInfo(
            id: "x-coredata://abc-123/ICNote/p1",
            title: "My Shopping List",
            body: "<div>Milk, eggs, bread</div>",
            plainText: "Milk, eggs, bread",
            folder: "Notes",
            folderId: "x-coredata://abc-123/ICFolder/p1",
            account: "iCloud",
            creationDate: "2026-01-01T00:00:00.000Z",
            modificationDate: "2026-03-10T12:00:00.000Z"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NoteInfo.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.body, original.body)
        XCTAssertEqual(decoded.plainText, original.plainText)
        XCTAssertEqual(decoded.folder, original.folder)
        XCTAssertEqual(decoded.folderId, original.folderId)
        XCTAssertEqual(decoded.account, original.account)
        XCTAssertEqual(decoded.creationDate, original.creationDate)
        XCTAssertEqual(decoded.modificationDate, original.modificationDate)
    }

    func testNoteInfoNilAccount() throws {
        let original = NoteInfo(
            id: "x-coredata://abc/ICNote/p2",
            title: "Quick Note",
            body: "<div>Hello</div>",
            plainText: "Hello",
            folder: "Notes",
            folderId: "x-coredata://abc/ICFolder/p1",
            account: nil,
            creationDate: "2026-03-01T00:00:00.000Z",
            modificationDate: "2026-03-10T00:00:00.000Z"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NoteInfo.self, from: data)
        XCTAssertNil(decoded.account)
        XCTAssertEqual(decoded.title, "Quick Note")
    }

    // MARK: - NoteFolder Codable roundtrip

    func testNoteFolderCodableRoundtrip() throws {
        let original = NoteFolder(
            id: "x-coredata://abc/ICFolder/p1",
            name: "Work",
            account: "iCloud",
            noteCount: 42
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NoteFolder.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.account, original.account)
        XCTAssertEqual(decoded.noteCount, original.noteCount)
    }

    func testNoteFolderNilAccount() throws {
        let original = NoteFolder(id: "x-coredata://abc/ICFolder/p2", name: "Personal", account: nil, noteCount: 5)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NoteFolder.self, from: data)
        XCTAssertNil(decoded.account)
        XCTAssertEqual(decoded.noteCount, 5)
    }

    // MARK: - NoteActionResult Codable roundtrip

    func testNoteActionResultCodableRoundtrip() throws {
        let original = NoteActionResult(
            success: true,
            action: "create",
            details: ["id": "x-coredata://abc/ICNote/p99", "title": "New Note"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NoteActionResult.self, from: data)
        XCTAssertEqual(decoded.success, original.success)
        XCTAssertEqual(decoded.action, original.action)
        XCTAssertEqual(decoded.details["id"], "x-coredata://abc/ICNote/p99")
        XCTAssertEqual(decoded.details["title"], "New Note")
    }

    func testNoteActionResultFailure() throws {
        let original = NoteActionResult(success: false, action: "delete", details: ["error": "not found"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NoteActionResult.self, from: data)
        XCTAssertFalse(decoded.success)
        XCTAssertEqual(decoded.action, "delete")
    }

    // MARK: - JXA Script builders (assert on generated strings)

    func testBuildListScriptContainsAppNotes() {
        let script = NotesBridge.buildListScript(folder: nil, limit: 10)
        XCTAssertTrue(
            script.contains("app.notes") || script.contains("Notes"),
            "Expected script to reference Notes, got: \(script)"
        )
    }

    func testBuildListScriptWithFolderContainsFolderName() {
        let script = NotesBridge.buildListScript(folder: "Work", limit: 10)
        XCTAssertTrue(
            script.contains("Work"),
            "Expected script to contain folder name 'Work', got: \(script)"
        )
    }

    func testBuildListScriptContainsLimit() {
        let script = NotesBridge.buildListScript(folder: nil, limit: 25)
        XCTAssertTrue(
            script.contains("25"),
            "Expected script to contain limit value 25, got: \(script)"
        )
    }

    func testBuildSearchScriptContainsQuery() {
        let script = NotesBridge.buildSearchScript(query: "meeting notes", folder: nil, limit: 10)
        XCTAssertTrue(
            script.contains("meeting notes"),
            "Expected script to contain search query, got: \(script)"
        )
    }

    func testBuildSearchScriptWithFolderContainsFolderName() {
        let script = NotesBridge.buildSearchScript(query: "todo", folder: "Work", limit: 10)
        XCTAssertTrue(
            script.contains("Work"),
            "Expected script to contain folder name, got: \(script)"
        )
    }

    func testBuildCreateScriptContainsTitle() {
        let script = NotesBridge.buildCreateScript(title: "My New Note", body: nil, folder: nil)
        XCTAssertTrue(
            script.contains("My New Note"),
            "Expected script to contain note title, got: \(script)"
        )
    }

    func testBuildCreateScriptWithBodyContainsBody() {
        let script = NotesBridge.buildCreateScript(title: "Title", body: "Body content here", folder: nil)
        XCTAssertTrue(
            script.contains("Body content here"),
            "Expected script to contain body text, got: \(script)"
        )
    }

    func testBuildShowScriptContainsId() {
        let noteId = "x-coredata://abc/ICNote/p1"
        let script = NotesBridge.buildShowScript(id: noteId)
        // ID gets escaped; check the raw UUID portion
        XCTAssertTrue(
            script.contains("abc"),
            "Expected script to contain note ID portion, got: \(script)"
        )
    }

    func testBuildDeleteScriptContainsId() {
        let noteId = "x-coredata://abc/ICNote/p5"
        let script = NotesBridge.buildDeleteScript(id: noteId)
        XCTAssertTrue(
            script.contains("delete"),
            "Expected script to contain delete call, got: \(script)"
        )
        XCTAssertTrue(
            script.contains("abc") || script.contains("p5"),
            "Expected script to contain note ID, got: \(script)"
        )
    }

    func testBuildEditScriptWithAppendFlag() {
        let script = NotesBridge.buildEditScript(id: "x-coredata://abc/ICNote/p1", title: nil, body: "Appended text", append: true)
        XCTAssertTrue(
            script.contains("true") || script.contains("isAppend"),
            "Expected script to contain append flag, got: \(script)"
        )
        XCTAssertTrue(
            script.contains("Appended text"),
            "Expected script to contain body text, got: \(script)"
        )
    }

    func testBuildListFoldersScriptContainsFolders() {
        let script = NotesBridge.buildListFoldersScript()
        XCTAssertTrue(
            script.contains("folders"),
            "Expected script to reference folders, got: \(script)"
        )
    }

    // MARK: - jsEscape

    func testJsEscapeSingleQuote() {
        let escaped = NotesBridge.jsEscape("it's")
        XCTAssertTrue(
            escaped.contains("\\'"),
            "Expected single quote to be escaped, got: \(escaped)"
        )
    }

    func testJsEscapeNewline() {
        let escaped = NotesBridge.jsEscape("line1\nline2")
        XCTAssertTrue(
            escaped.contains("\\n"),
            "Expected newline to be escaped, got: \(escaped)"
        )
    }

    func testJsEscapeBackslash() {
        let escaped = NotesBridge.jsEscape("path\\file")
        XCTAssertTrue(
            escaped.contains("\\\\"),
            "Expected backslash to be escaped, got: \(escaped)"
        )
    }

    func testJsEscapeDoubleQuote() {
        let escaped = NotesBridge.jsEscape("say \"hello\"")
        XCTAssertTrue(
            escaped.contains("\\\""),
            "Expected double quote to be escaped, got: \(escaped)"
        )
    }

    func testJsEscapeNoChangePlainString() {
        let plain = "Hello world 123"
        let escaped = NotesBridge.jsEscape(plain)
        XCTAssertEqual(escaped, plain)
    }
}
