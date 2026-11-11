import JavaScriptCore
@testable import PippinLib
import XCTest

/// pippin-nrrx: Recently Deleted was matched by its English name only, so on a
/// non-English system trashed notes showed up in every read.
final class NotesTrashFolderNameTests: XCTestCase {
    func testLocalizedNameComesFromTheNotesStringsTable() throws {
        let table = try XCTUnwrap(NotesBridge.notesStringsTable(), "NotesShared strings table must be readable on macOS")
        XCTAssertEqual(NotesBridge.trashFolderName(in: table, preferences: ["de-DE"]), "Zuletzt gelöscht")
        XCTAssertEqual(NotesBridge.trashFolderName(in: table, preferences: ["en-US"]), "Recently Deleted")
        XCTAssertNil(NotesBridge.trashFolderName(in: [:], preferences: ["de"]))
    }

    func testEnglishNameIsAlwaysMatchedAndDuplicatesDropped() {
        XCTAssertEqual(NotesBridge.trashFolderNames(localized: "Zuletzt gelöscht"), ["Recently Deleted", "Zuletzt gelöscht"])
        XCTAssertEqual(NotesBridge.trashFolderNames(localized: "Recently Deleted"), ["Recently Deleted"])
        XCTAssertEqual(NotesBridge.trashFolderNames(localized: nil), ["Recently Deleted"])
    }

    func testPredicateMatchesEveryNameAndEscapesThem() throws {
        let ctx = try XCTUnwrap(JSContext())
        let predicate = NotesBridge.jsIsTrash("x", names: ["Recently Deleted", "Zuletzt gelöscht", "it's"])
        for (name, expected) in [("Zuletzt gelöscht", true), ("Recently Deleted", true), ("it's", true), ("Notes", false)] {
            ctx.setObject(name, forKeyedSubscript: "x" as NSString)
            XCTAssertEqual(ctx.evaluateScript(predicate)?.toBool(), expected, name)
        }
    }
}
