import JavaScriptCore
@testable import PippinLib
import XCTest

/// Executes the generated Notes JXA in JavaScriptCore against a fake Notes, so
/// these tests pin what the scripts do (which reads and writes reach Notes)
/// rather than how their source text reads.
final class NotesScriptBehaviorTests: XCTestCase {
    /// Fake Notes. `__events` counts every Apple Event equivalent by name and
    /// `__writes` records every mutation, in order.
    static let fakeNotes = """
    var __clock = 1000000;
    Date.now = function() { return __clock; };
    var __events = {};
    var __writes = [];
    function __ev(name) { __events[name] = (__events[name] || 0) + 1; }
    function __total() { var n = 0; for (var k in __events) n += __events[k]; return n; }
    function __folderOf(row) {
        for (var i = 0; i < __folders.length; i++) { if (__folders[i].name === row.folder) return __folders[i]; }
        return null;
    }
    function __note(row) {
        var note = {
            id: function() { __ev('note.id'); return row.id; },
            plaintext: function() { __ev('note.plaintext'); return row.plain; },
            creationDate: function() { __ev('note.creationDate'); return new Date(row.created); },
            modificationDate: function() { __ev('note.modificationDate'); return new Date(row.mod); },
            container: function() {
                __ev('note.container');
                var f = __folderOf(row);
                if (!f) throw new Error('no container');
                return __folder(f);
            }
        };
        // JXA reads a property by calling it and writes it by assignment.
        Object.defineProperty(note, 'name', {
            get: function() { return function() { __ev('note.name'); return row.name; }; },
            set: function(v) { __writes.push({op: 'name', id: row.id, value: v}); row.name = v; }
        });
        Object.defineProperty(note, 'body', {
            get: function() {
                return function() {
                    __ev('note.body');
                    if (row.bodyThrows) throw new Error('Notes got an error: AppleEvent timed out.');
                    return row.body;
                };
            },
            set: function(v) { __writes.push({op: 'body', id: row.id, value: v}); row.body = v; }
        });
        return note;
    }
    function __notesSpec(rowsOf) {
        var spec = function() { __ev('notes()'); return rowsOf().map(__note); };
        function column(event, pick) {
            return function() {
                __ev(event);
                if (__bulkThrows[event]) throw new Error('bulk getter failed');
                var rows = rowsOf();
                if (rows.length === 0) throw new Error("Can't get object. (-1728)");
                if (__onBulk) __onBulk(event);
                return rowsOf().map(pick);
            };
        }
        spec.id = column('notes.id', function(r) { return r.id; });
        spec.name = column('notes.name', function(r) { return r.name; });
        spec.plaintext = column('notes.plaintext', function(r) { return r.plain; });
        spec.modificationDate = column('notes.modificationDate', function(r) { return new Date(r.mod); });
        spec.creationDate = column('notes.creationDate', function(r) { return new Date(r.created); });
        spec.byId = function(id) {
            var hit = rowsOf().filter(function(r) { return r.id === id; })[0];
            if (!hit) throw new Error("Can't get object. (-1728)");
            return __note(hit);
        };
        spec.whose = function(cond) {
            return function() {
                __ev('notes.whose');
                return rowsOf().filter(function(r) { return r.id === cond.id; }).map(__note);
            };
        };
        Object.defineProperty(spec, 'length', {get: function() { __ev('notes.length'); return rowsOf().length; }});
        return spec;
    }
    function __folder(f) {
        return {
            id: function() { __ev('folder.id'); return f.id; },
            name: function() { __ev('folder.name'); return f.name; },
            notes: __notesSpec(function() { return __rows.filter(function(r) { return r.folder === f.name; }); })
        };
    }
    function __foldersSpec() {
        var spec = function() { __ev('folders()'); return __folders.map(__folder); };
        spec.id = function() { __ev('folders.id'); return __folders.map(function(f) { return f.id; }); };
        spec.name = function() { __ev('folders.name'); return __folders.map(function(f) { return f.name; }); };
        spec.whose = function(cond) {
            return function() {
                __ev('folders.whose');
                return __folders.filter(function(f) { return f.name === cond.name; }).map(__folder);
            };
        };
        // Chained plural specifier: one Apple Event for every folder's note ids.
        spec.notes = {
            id: function() {
                __ev('folders.notes.id');
                return __folders.map(function(f) {
                    return __rows.filter(function(r) { return r.folder === f.name; }).map(function(r) { return r.id; });
                });
            }
        };
        Object.defineProperty(spec, 'length', {get: function() { __ev('folders.length'); return __folders.length; }});
        return spec;
    }
    function Application() {
        return {
            notes: __notesSpec(function() { return __rows; }),
            folders: __foldersSpec(),
            make: function(args) {
                __writes.push({op: 'make', name: args.withProperties.name, at: args.at ? args.at.name() : null});
                return {id: function() { return 'x-coredata://new/ICNote/p999'; }};
            },
            delete: function(note) { __writes.push({op: 'delete', id: note.id()}); }
        };
    }
    var __bulkThrows = {};
    var __onBulk = null;
    var __folders = [
        {id: 'f-notes', name: 'Notes'}, {id: 'f-work', name: 'Work'}, {id: 'f-trash', name: 'Recently Deleted'}
    ];
    function __mk(n, folder, extra) {
        var row = {
            id: 'x-coredata://abc/ICNote/p' + n, name: 'Title ' + n, plain: 'Title ' + n + ' body text ' + n,
            body: '<div>Title ' + n + '</div><div>body text ' + n + '</div>',
            mod: Date.UTC(2026, 0, n), created: Date.UTC(2025, 0, n), folder: folder
        };
        for (var k in (extra || {})) row[k] = extra[k];
        return row;
    }
    var __rows = [__mk(1, 'Notes'), __mk(2, 'Work'), __mk(3, 'Notes'), __mk(4, 'Recently Deleted'), __mk(5, 'Work')];
    """

    static func noteId(_ n: Int) -> String {
        "x-coredata://abc/ICNote/p\(n)"
    }

    struct ScriptError: Error, CustomStringConvertible {
        let description: String
    }

    func makeContext(setup: String = "") throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(Self.fakeNotes + "\n" + setup)
        if let exception = context.exception {
            throw ScriptError(description: "fake setup failed: \(exception)")
        }
        return context
    }

    /// Run a generated script; a thrown JS error becomes a Swift error carrying
    /// its message, as osascript's stderr would.
    func run(_ script: String, in context: JSContext) throws -> String {
        let value = context.evaluateScript(script)
        if let exception = context.exception {
            context.exception = nil
            throw ScriptError(description: exception.toString())
        }
        return try XCTUnwrap(value?.toString())
    }

    func writes(_ context: JSContext) throws -> [[String: String]] {
        let json = try XCTUnwrap(context.evaluateScript("JSON.stringify(__writes)")?.toString())
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        return raw.map { $0.compactMapValues { $0 as? String } }
    }

    func events(_ context: JSContext) throws -> [String: Int] {
        let json = try XCTUnwrap(context.evaluateScript("JSON.stringify(__events)")?.toString())
        return try JSONDecoder().decode([String: Int].self, from: Data(json.utf8))
    }

    // MARK: - notes edit (RC-04)

    func testAppendAbortsWithoutWritingWhenTheBodyReadFails() throws {
        let context = try makeContext(setup: "__rows[0].bodyThrows = true;")
        let script = NotesBridge.buildEditScript(id: Self.noteId(1), title: nil, body: "more", append: true)
        XCTAssertThrowsError(try run(script, in: context), "a failed read must fail the edit")
        // The regression: the read error was swallowed and the note body was
        // then REPLACED by the appended fragment alone.
        XCTAssertEqual(try writes(context), [], "nothing may be written after a failed read")
    }

    private func edit(
        _ n: Int, title: String? = nil, body: String? = nil, append: Bool = false, dryRun: Bool = false,
        in context: JSContext
    ) throws -> NoteEditResult {
        let script = NotesBridge.buildEditScript(
            id: Self.noteId(n), title: title, body: body, append: append, dryRun: dryRun
        )
        return try NotesBridge.decode(NoteEditResult.self, from: run(script, in: context))
    }

    func testAppendWritesTheExistingBodyPlusTheFragment() throws {
        let context = try makeContext()
        let before = "<div>Title 1</div><div>body text 1</div>"
        let result = try edit(1, body: "more", append: true, in: context)
        XCTAssertEqual(try writes(context), [["op": "body", "id": Self.noteId(1), "value": before + "<div>more</div>"]])
        XCTAssertEqual(result.previousBodyLength, before.count)
        XCTAssertEqual(result.newBodyLength, before.count + "<div>more</div>".count)
        XCTAssertFalse(result.dryRun)
        XCTAssertEqual(result.details["id"], Self.noteId(1), "existing details.id stays")
    }

    func testReplaceReportsHowMuchBodyItReplaced() throws {
        let context = try makeContext()
        let result = try edit(1, body: "x", in: context)
        XCTAssertEqual(try writes(context), [["op": "body", "id": Self.noteId(1), "value": "<div>x</div>"]])
        XCTAssertEqual(result.previousBodyLength, "<div>Title 1</div><div>body text 1</div>".count)
        XCTAssertEqual(result.newBodyLength, "<div>x</div>".count)
    }

    func testDryRunReportsLengthsAndWritesNothing() throws {
        let context = try makeContext()
        let result = try edit(1, title: "Renamed", body: "x", dryRun: true, in: context)
        XCTAssertEqual(try writes(context), [], "dry run must not write the title or the body")
        XCTAssertTrue(result.dryRun)
        XCTAssertEqual(result.title, "Renamed")
        XCTAssertEqual(result.previousBodyLength, "<div>Title 1</div><div>body text 1</div>".count)
        XCTAssertEqual(result.newBodyLength, "<div>x</div>".count)
        XCTAssertEqual(result.details["id"], Self.noteId(1))
    }

    func testTitleOnlyEditLeavesTheBodyAlone() throws {
        let context = try makeContext()
        let result = try edit(1, title: "Renamed", in: context)
        XCTAssertEqual(try writes(context), [["op": "name", "id": Self.noteId(1), "value": "Renamed"]])
        XCTAssertEqual(result.previousBodyLength, result.newBodyLength)
    }

    func testFailedBodyReadAlsoStopsTheTitleWrite() throws {
        // The title is written before the body, so the read has to come first.
        let context = try makeContext(setup: "__rows[0].bodyThrows = true;")
        XCTAssertThrowsError(try edit(1, title: "Renamed", body: "x", append: true, in: context))
        XCTAssertEqual(try writes(context), [])
    }

    func testEditDryRunFlagReachesTheCommandAndMCP() throws {
        XCTAssertTrue(try NotesCommand.Edit.parse([Self.noteId(1), "--body", "x", "--dry-run"]).dryRun)
        XCTAssertFalse(try NotesCommand.Edit.parse([Self.noteId(1), "--body", "x"]).dryRun)
        let tool = try XCTUnwrap(MCPToolRegistry.tool(named: "notes_edit"))
        let argv = try tool.buildArgs(.object(["id": .string(Self.noteId(1)), "body": .string("x"), "dryRun": .bool(true)]))
        XCTAssertTrue(argv.contains("--dry-run"), "\(argv)")
        let plain = try tool.buildArgs(.object(["id": .string(Self.noteId(1)), "body": .string("x")]))
        XCTAssertFalse(plain.contains("--dry-run"))
    }

    // MARK: - Notes already in Recently Deleted (RT-32, RT-33)

    func testDeleteRefusesANoteAlreadyInRecentlyDeleted() throws {
        // Note 4 sits in Recently Deleted. Deleting it again is how Notes
        // purges a note for good, so the second delete must not reach Notes.
        let context = try makeContext()
        XCTAssertThrowsError(try run(NotesBridge.buildDeleteScript(id: Self.noteId(4)), in: context)) { error in
            guard case let NotesBridgeError.noteInTrash(id) = NotesBridge.mapScriptFailure("\(error)") else {
                return XCTFail("Expected noteInTrash, got \(error)")
            }
            XCTAssertEqual(id, Self.noteId(4))
        }
        XCTAssertEqual(try writes(context), [], "the purge must not happen")
    }

    func testDeleteFailsClosedWhenTheFolderCannotBeRead() throws {
        // Unknown folder means "might be in the trash": refuse, do not purge.
        let context = try makeContext(setup: "__rows[0].folder = 'gone';")
        XCTAssertThrowsError(try run(NotesBridge.buildDeleteScript(id: Self.noteId(1)), in: context))
        XCTAssertEqual(try writes(context), [])
    }

    func testDeleteOfALiveNoteStillDeletes() throws {
        let context = try makeContext()
        _ = try run(NotesBridge.buildDeleteScript(id: Self.noteId(1)), in: context)
        XCTAssertEqual(try writes(context), [["op": "delete", "id": Self.noteId(1)]])
    }

    func testEditRefusesANoteAlreadyInRecentlyDeleted() throws {
        let context = try makeContext()
        let script = NotesBridge.buildEditScript(id: Self.noteId(4), title: "x", body: "y", append: false)
        XCTAssertThrowsError(try run(script, in: context)) { error in
            guard case NotesBridgeError.noteInTrash = NotesBridge.mapScriptFailure("\(error)") else {
                return XCTFail("Expected noteInTrash, got \(error)")
            }
        }
        XCTAssertEqual(try writes(context), [])
    }

    func testNoteInTrashIsATypedNonRetryableError() {
        let error = NotesBridge.mapScriptFailure(
            "execution error: Error: NOTESBRIDGE_ERR_IN_TRASH: x-coredata://abc/ICNote/p4 (-2700)"
        )
        XCTAssertEqual(agentErrorCode(for: error), "note_in_trash")
        XCTAssertFalse(error.nextStep.retryable)
        XCTAssertTrue(error.errorDescription?.contains("x-coredata://abc/ICNote/p4") == true)
        XCTAssertFalse(error.errorDescription?.contains("NOTESBRIDGE") == true, "the JXA marker stays internal")
    }
}
