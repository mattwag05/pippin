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

    // MARK: - Sentinel → typed noteNotFound mapping

    func testMapScriptFailureDetectsNotFoundSentinel() {
        // osascript wraps the JXA throw in its own prefix/suffix noise.
        let raw = "execution error: Error: NOTESBRIDGE_ERR_NOT_FOUND: x-coredata://abc-123/ICNote/p1 (-2700)"
        guard case let .noteNotFound(id) = NotesBridge.mapScriptFailure(raw) else {
            return XCTFail("Sentinel must map to .noteNotFound")
        }
        XCTAssertEqual(id, "x-coredata://abc-123/ICNote/p1")
    }

    func testMapScriptFailurePassesThroughOtherErrors() {
        guard case let .scriptFailed(msg) = NotesBridge.mapScriptFailure("osascript error -1743") else {
            return XCTFail("Non-sentinel failures must stay .scriptFailed")
        }
        XCTAssertEqual(msg, "osascript error -1743")
    }

    func testNoteNotFoundHidesJXAMarkerAndNamesId() {
        let err = NotesBridge.mapScriptFailure("NOTESBRIDGE_ERR_NOT_FOUND: x-coredata://abc-123/ICNote/p1")
        let desc = err.errorDescription ?? ""
        XCTAssertFalse(
            desc.contains("NOTESBRIDGE_ERR_NOT_FOUND"),
            "Should not expose internal JXA error marker to user, got: \(desc)"
        )
        XCTAssertTrue(desc.contains("Note not found"), "Expected not-found message, got: \(desc)")
        XCTAssertTrue(desc.contains("x-coredata://abc-123/ICNote/p1"), "Should name the missing id, got: \(desc)")
    }

    func testNoteNotFoundAgentCodeAndExitCode() {
        let err = NotesBridgeError.noteNotFound("x-coredata://abc/ICNote/p1")
        XCTAssertEqual(agentErrorCode(for: err), "note_not_found")
        XCTAssertEqual(PippinExitCode.from(err), 3, "*_not_found codes classify to exit 3")
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

    private static func makeNote(body: String? = "<div>This is HTML content</div>") -> NoteInfo {
        NoteInfo(
            id: "x-coredata://abc-123/ICNote/p1",
            title: "Meeting Notes",
            body: body,
            plainText: "This is HTML content",
            folder: "Work",
            folderId: "x-coredata://abc-123/ICFolder/p1",
            account: "iCloud",
            creationDate: "2026-01-01T00:00:00.000Z",
            modificationDate: "2026-03-10T12:00:00.000Z"
        )
    }

    func testNoteAgentViewExcludesBodyAndUsesModifiedAt() throws {
        let view = NoteAgentView(note: Self.makeNote())
        let data = try JSONEncoder().encode(view)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(dict["body"], "Agent view must not carry the HTML body")
        XCTAssertEqual(dict["plainText"] as? String, "This is HTML content")
        XCTAssertEqual(dict["modifiedAt"] as? String, "2026-03-10T12:00:00.000Z")
        XCTAssertNil(dict["modificationDate"], "Old field name must be gone (envelope v2 rename)")
    }

    // MARK: - NoteInfo serialized field names (envelope v2 rename)

    func testNoteInfoEncodesCreatedAtModifiedAtKeys() throws {
        let data = try JSONEncoder().encode(Self.makeNote())
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(dict["createdAt"] as? String, "2026-01-01T00:00:00.000Z")
        XCTAssertEqual(dict["modifiedAt"] as? String, "2026-03-10T12:00:00.000Z")
        XCTAssertNil(dict["creationDate"], "Old field name must be gone (envelope v2 rename)")
        XCTAssertNil(dict["modificationDate"], "Old field name must be gone (envelope v2 rename)")
        XCTAssertNotNil(dict["body"], "show payloads still carry body when fetched")
    }

    func testNoteInfoOmitsNilBodyFromJSON() throws {
        let data = try JSONEncoder().encode(Self.makeNote(body: nil))
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(dict["body"], "nil body (list/search) must be omitted, not null")
        XCTAssertNotNil(dict["plainText"])
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

    // MARK: - BridgeActionResult Codable roundtrip

    func testBridgeActionResultCodableRoundtrip() throws {
        let original = BridgeActionResult(
            success: true,
            action: "create",
            details: ["id": "x-coredata://abc/ICNote/p99", "title": "New Note"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BridgeActionResult.self, from: data)
        XCTAssertEqual(decoded.success, original.success)
        XCTAssertEqual(decoded.action, original.action)
        XCTAssertEqual(decoded.details["id"], "x-coredata://abc/ICNote/p99")
        XCTAssertEqual(decoded.details["title"], "New Note")
    }

    func testBridgeActionResultFailure() throws {
        let original = BridgeActionResult(success: false, action: "delete", details: ["error": "not found"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BridgeActionResult.self, from: data)
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

    func testBuildListScriptDefaultOffsetIsZero() {
        let script = NotesBridge.buildListScript(folder: nil, limit: 10)
        XCTAssertTrue(script.contains("var offset = 0;"))
    }

    /// pippin-m3y: native offset pushdown — the results loop starts at `offset`
    /// so deep pages fetch a bounded window from any offset without the old
    /// 500-note ceiling.
    func testBuildListScriptInjectsOffsetAndStartsLoopThere() {
        let script = NotesBridge.buildListScript(folder: nil, limit: 25, offset: 50)
        XCTAssertTrue(script.contains("var offset = 50;"))
        XCTAssertTrue(script.contains("for (var i = offset;"))
    }

    func testBuildListScriptClampsNegativeOffsetToZero() {
        let script = NotesBridge.buildListScript(folder: nil, limit: 10, offset: -5)
        XCTAssertTrue(script.contains("var offset = 0;"))
    }

    func testBuildListScriptContainsLimit() {
        let script = NotesBridge.buildListScript(folder: nil, limit: 25)
        XCTAssertTrue(
            script.contains("25"),
            "Expected script to contain limit value 25, got: \(script)"
        )
    }

    // MARK: - Metadata-fast list/search (no HTML body, single container resolve)

    func testBuildListScriptDoesNotFetchHTMLBody() {
        let script = NotesBridge.buildListScript(folder: nil, limit: 10)
        XCTAssertFalse(script.contains("note.body()"), "List must not fetch the HTML body — `notes show` does")
        XCTAssertTrue(script.contains("note.plaintext()"), "List still returns plainText")
    }

    func testBuildSearchScriptDoesNotFetchHTMLBody() {
        let script = NotesBridge.buildSearchScript(query: "x", folder: nil, limit: 10)
        XCTAssertFalse(script.contains("note.body()"), "Search must not fetch the HTML body — `notes show` does")
    }

    func testBuildListScriptResolvesContainerOncePerNote() {
        let script = NotesBridge.buildListScript(folder: nil, limit: 10)
        XCTAssertEqual(
            script.components(separatedBy: "note.container()").count - 1, 1,
            "container() must be resolved once per note, then id()/name() read off the resolved object"
        )
    }

    func testBuildSearchScriptReusesMatchTestReads() {
        // The match test already read name()/plaintext(); matched notes must
        // reuse those JS locals instead of firing two more Apple Events each.
        let script = NotesBridge.buildSearchScript(query: "x", folder: nil, limit: 10)
        XCTAssertTrue(script.contains("title: title,"), "Matched notes must reuse the cached title")
        XCTAssertTrue(script.contains("plainText: plain,"), "Matched notes must reuse the cached plaintext")
        XCTAssertEqual(script.components(separatedBy: "note.plaintext()").count - 1, 1)
        XCTAssertEqual(script.components(separatedBy: "note.container()").count - 1, 1)
    }

    func testListAndSearchScriptsEmitRenamedDateKeys() {
        for script in [
            NotesBridge.buildListScript(folder: nil, limit: 10),
            NotesBridge.buildSearchScript(query: "x", folder: nil, limit: 10),
            NotesBridge.buildShowScript(id: "x-coredata://abc/ICNote/p1"),
        ] {
            XCTAssertTrue(script.contains("createdAt:"), "Script must emit createdAt")
            XCTAssertTrue(script.contains("modifiedAt:"), "Script must emit modifiedAt")
            XCTAssertFalse(script.contains("creationDate:"), "Old creationDate key must be gone")
            XCTAssertFalse(script.contains("modificationDate:"), "Old modificationDate key must be gone")
        }
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

    // MARK: - textToNotesHTML (issue #26 — note.body is HTML, plain newlines collapse)

    func testTextToNotesHTMLEscapesHTMLEntities() {
        XCTAssertEqual(
            NotesBridge.textToNotesHTML("a & b < c > d"),
            "<div>a &amp; b &lt; c &gt; d</div>"
        )
    }

    func testTextToNotesHTMLWrapsEachLineInDiv() {
        XCTAssertEqual(
            NotesBridge.textToNotesHTML("line1\nline2"),
            "<div>line1</div><div>line2</div>"
        )
    }

    func testTextToNotesHTMLBlankLineBecomesDivBr() {
        XCTAssertEqual(
            NotesBridge.textToNotesHTML("para1\n\npara2"),
            "<div>para1</div><div><br></div><div>para2</div>"
        )
    }

    func testTextToNotesHTMLSingleTrailingNewlineNoStrayDiv() {
        XCTAssertEqual(
            NotesBridge.textToNotesHTML("line1\nline2\n"),
            "<div>line1</div><div>line2</div>"
        )
    }

    func testTextToNotesHTMLEmptyStringStaysEmpty() {
        XCTAssertEqual(NotesBridge.textToNotesHTML(""), "")
    }

    // MARK: - Script builders: body HTML conversion (issue #26)

    func testBuildCreateScriptConvertsMultilineBodyToHTML() {
        let script = NotesBridge.buildCreateScript(title: "T", body: "line1\nline2", folder: nil)
        XCTAssertTrue(
            script.contains("<div>line1</div><div>line2</div>"),
            "Expected multi-line body converted to Notes HTML, got: \(script)"
        )
    }

    func testBuildCreateScriptHTMLFlagPassesRawBody() {
        let script = NotesBridge.buildCreateScript(title: "T", body: "<b>bold</b>", folder: nil, html: true)
        XCTAssertTrue(
            script.contains("<b>bold</b>"),
            "Expected raw HTML body untouched, got: \(script)"
        )
        XCTAssertFalse(
            script.contains("&lt;"),
            "Raw HTML must not be entity-escaped, got: \(script)"
        )
    }

    func testBuildEditScriptConvertsMultilineBodyToHTML() {
        let script = NotesBridge.buildEditScript(id: "x-coredata://abc/ICNote/p1", title: nil, body: "line1\n\nline2", append: false)
        XCTAssertTrue(
            script.contains("<div>line1</div><div><br></div><div>line2</div>"),
            "Expected multi-line body converted to Notes HTML, got: \(script)"
        )
    }

    func testBuildEditScriptAppendConvertsFragment() {
        let script = NotesBridge.buildEditScript(id: "x-coredata://abc/ICNote/p1", title: nil, body: "add1\nadd2", append: true)
        XCTAssertTrue(
            script.contains("<div>add1</div><div>add2</div>"),
            "Expected appended fragment converted to Notes HTML, got: \(script)"
        )
    }

    func testBuildEditScriptHTMLFlagPassesRawBody() {
        let script = NotesBridge.buildEditScript(id: "x-coredata://abc/ICNote/p1", title: nil, body: "<h1>raw</h1>", append: false, html: true)
        XCTAssertTrue(
            script.contains("<h1>raw</h1>"),
            "Expected raw HTML body untouched, got: \(script)"
        )
        XCTAssertFalse(
            script.contains("&lt;"),
            "Raw HTML must not be entity-escaped, got: \(script)"
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
        let escaped = jsEscape("it's")
        XCTAssertTrue(
            escaped.contains("\\'"),
            "Expected single quote to be escaped, got: \(escaped)"
        )
    }

    func testJsEscapeNewline() {
        let escaped = jsEscape("line1\nline2")
        XCTAssertTrue(
            escaped.contains("\\n"),
            "Expected newline to be escaped, got: \(escaped)"
        )
    }

    func testJsEscapeBackslash() {
        let escaped = jsEscape("path\\file")
        XCTAssertTrue(
            escaped.contains("\\\\"),
            "Expected backslash to be escaped, got: \(escaped)"
        )
    }

    func testJsEscapeDoubleQuote() {
        let escaped = jsEscape("say \"hello\"")
        XCTAssertTrue(
            escaped.contains("\\\""),
            "Expected double quote to be escaped, got: \(escaped)"
        )
    }

    func testJsEscapeNoChangePlainString() {
        let plain = "Hello world 123"
        let escaped = jsEscape(plain)
        XCTAssertEqual(escaped, plain)
    }
}
