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
    var __tick = 0;
    var Automation = {getDisplayString: function(spec) { return spec.__display; }};
    function __ev(name) { __events[name] = (__events[name] || 0) + 1; }
    function __total() { var n = 0; for (var k in __events) n += __events[k]; return n; }
    function __folderOf(row) {
        for (var i = 0; i < __folders.length; i++) { if (__folders[i].name === row.folder) return __folders[i]; }
        return null;
    }
    function __note(row) {
        var note = {
            id: function() { __ev('note.id'); return row.id; },
            plaintext: function() { __ev('note.plaintext'); __clock += __tick; return row.plain; },
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
        // A JS function's own `name` is read-only, so it has to be redefined.
        Object.defineProperty(spec, 'name', {value: column('notes.name', function(r) { return r.name; })});
        spec.plaintext = column('notes.plaintext', function(r) { return r.plain; });
        spec.modificationDate = column('notes.modificationDate', function(r) { return new Date(r.mod); });
        spec.creationDate = column('notes.creationDate', function(r) { return new Date(r.created); });
        // Notes answers a bulk `container` read with one by-id folder specifier per note.
        spec.container = column('notes.container', function(r) {
            var f = __folderOf(r);
            return {__display: 'Application("Notes").folders.byId("' + (f ? f.id : 'f-unlisted') + '")'};
        });
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
        Object.defineProperty(spec, 'name', {value: function() {
            __ev('folders.name');
            return __folders.map(function(f) { return f.name; });
        }});
        spec.whose = function(cond) {
            return function() {
                __ev('folders.whose');
                return __folders.filter(function(f) { return f.name === cond.name; }).map(__folder);
            };
        };
        // byName resolves nothing until a property is read; a missing folder's
        // notes answer -1728, as Notes does.
        spec.byName = function(name) {
            var f = __folders.filter(function(x) { return x.name === name; })[0];
            return f ? __folder(f) : {notes: __notesSpec(function() { return []; })};
        };
        // Chained plural specifier: one Apple Event for every folder's note ids.
        spec.notes = {
            id: function() {
                __ev('folders.notes.id');
                if (__bulkThrows['folders.notes.id']) throw new Error('chained getter refused');
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

    // MARK: - notes create --folder (RT-5)

    func testCreateInAMissingFolderFailsInsteadOfUsingTheDefaultFolder() throws {
        let context = try makeContext()
        let script = NotesBridge.buildCreateScript(title: "T", body: "b", folder: "No Such Folder")
        XCTAssertThrowsError(try run(script, in: context)) { error in
            // osascript appends the error number to the message.
            guard case let NotesBridgeError.folderNotFound(name) = NotesBridge.mapScriptFailure("\(error) (-2700)") else {
                return XCTFail("Expected folderNotFound, got \(error)")
            }
            XCTAssertEqual(name, "No Such Folder", "a folder name with spaces survives")
        }
        XCTAssertEqual(try writes(context), [], "the note must not be created somewhere else")
    }

    func testCreateInAnExistingFolderAndWithNoFolderStillWork() throws {
        let context = try makeContext()
        _ = try run(NotesBridge.buildCreateScript(title: "T", body: "b", folder: "Work"), in: context)
        _ = try run(NotesBridge.buildCreateScript(title: "U", body: "b", folder: nil), in: context)
        XCTAssertEqual(try writes(context), [
            ["op": "make", "name": "T", "at": "Work"],
            ["op": "make", "name": "U"],
        ])
    }

    func testFolderNotFoundIsATypedNotFoundError() {
        let error = NotesBridgeError.folderNotFound("Nope")
        XCTAssertEqual(agentErrorCode(for: error), "folder_not_found")
        XCTAssertEqual(PippinExitCode.from(error), 3)
        XCTAssertEqual(error.nextStep.nextCall?.tool, "notes_folders")
    }

    // MARK: - Read cost (PERF-1, PERF-2, PERF-6)

    /// A vault of `count` notes, alternating between two folders.
    static func vault(_ count: Int) -> String {
        "__rows = []; for (var n = 1; n <= \(count); n++) { __rows.push(__mk(n, n % 2 ? 'Notes' : 'Work')); }"
    }

    func testSearchMissReadsTheWholeVaultInAFixedNumberOfAppleEvents() throws {
        // Per-note name() + plaintext() reads made a no-match search cost two
        // Apple Events per note, so it hit the soft cap before finishing.
        let context = try makeContext(setup: Self.vault(300))
        let json = try run(NotesBridge.buildSearchScript(query: "zzz-no-such-text", folder: nil, limit: 50), in: context)
        let outcome = try NotesBridge.decode(NotesBridge.Outcome<[NoteInfo]>.self, from: json)
        XCTAssertEqual(outcome.results.count, 0)
        XCTAssertFalse(outcome.timedOut, "a miss must be a complete answer, not a partial one")
        let seen = try events(context)
        XCTAssertLessThan(seen.values.reduce(0, +), 15, "cost must not scale with the vault: \(seen)")
    }

    func testListCostDoesNotGrowWithTheNumberOfRows() throws {
        let context = try makeContext(setup: Self.vault(300))
        let json = try run(NotesBridge.buildListScript(folder: nil, limit: 50), in: context)
        let outcome = try NotesBridge.decode(NotesBridge.Outcome<[NoteInfo]>.self, from: json)
        XCTAssertEqual(outcome.results.count, 50)
        let seen = try events(context)
        XCTAssertLessThan(seen.values.reduce(0, +), 15, "about 7 Apple Events per row before: \(seen)")
    }

    func testFoldersCountNotesWithoutMaterializingThem() throws {
        let context = try makeContext()
        let json = try run(NotesBridge.buildListFoldersScript(), in: context)
        let outcome = try NotesBridge.decode(NotesBridge.Outcome<[NoteFolder]>.self, from: json)
        XCTAssertEqual(outcome.results.map(\.name), ["Notes", "Work"], "Recently Deleted stays hidden")
        XCTAssertEqual(outcome.results.map(\.noteCount), [2, 2])
        let seen = try events(context)
        XCTAssertNil(seen["notes()"], "counting must not materialize every note: \(seen)")
        XCTAssertLessThan(seen.values.reduce(0, +), 6, "cost must not scale with the folder count: \(seen)")
    }

    // MARK: - List and search behavior

    private func list(
        folder: String? = nil, limit: Int = 50, offset: Int = 0, seekingAfter anchor: Cursor.Anchor? = nil,
        fields: Set<String>? = nil, in context: JSContext
    ) throws -> NotesBridge.Outcome<[NoteInfo]> {
        let script = NotesBridge.buildListScript(
            folder: folder, limit: limit, offset: offset, seekingAfter: anchor, fields: fields
        )
        return try NotesBridge.decode(NotesBridge.Outcome<[NoteInfo]>.self, from: run(script, in: context))
    }

    private func search(
        _ query: String, folder: String? = nil, limit: Int = 50, fields: Set<String>? = nil,
        softTimeoutMs: Int = 22000, in context: JSContext
    ) throws -> NotesBridge.Outcome<[NoteInfo]> {
        let script = NotesBridge.buildSearchScript(
            query: query, folder: folder, limit: limit, fields: fields, softTimeoutMs: softTimeoutMs
        )
        return try NotesBridge.decode(NotesBridge.Outcome<[NoteInfo]>.self, from: run(script, in: context))
    }

    private func ids(_ notes: [NoteInfo]) -> [Int] {
        notes.compactMap { Int($0.id.components(separatedBy: "/p").last ?? "") }
    }

    func testListIsNewestFirstWithTheRightFolderAndNoTrashedNotes() throws {
        let context = try makeContext()
        let notes = try list(in: context).results
        XCTAssertEqual(ids(notes), [5, 3, 2, 1], "note 4 is in Recently Deleted")
        XCTAssertEqual(notes.map(\.folder), ["Work", "Notes", "Work", "Notes"])
        XCTAssertEqual(notes.map(\.folderId), ["f-work", "f-notes", "f-work", "f-notes"])
        XCTAssertEqual(notes.map(\.title), ["Title 5", "Title 3", "Title 2", "Title 1"], "each id keeps its own title")
        XCTAssertEqual(notes[0].modificationDate, "2026-01-05T00:00:00.000Z")
        XCTAssertEqual(notes[0].creationDate, "2025-01-05T00:00:00.000Z")
        XCTAssertEqual(notes[0].plainText, "Title 5 body text 5")
    }

    func testListReadsOnlyTheFieldsTheCallerKeeps() throws {
        let context = try makeContext()
        let notes = try list(fields: ["id", "title", "folder", "modifiedAt"], in: context).results
        XCTAssertEqual(ids(notes), [5, 3, 2, 1])
        XCTAssertEqual(notes.map(\.folder), ["Work", "Notes", "Work", "Notes"])
        let seen = try events(context)
        // The default output drops these, so they must not be fetched at all.
        XCTAssertNil(seen["notes.plaintext"], "\(seen)")
        XCTAssertNil(seen["note.plaintext"], "\(seen)")
        XCTAssertNil(seen["notes.creationDate"], "\(seen)")
        XCTAssertEqual(notes.map(\.plainText), ["", "", "", ""])

        let asked = try makeContext()
        let withText = try list(fields: ["id", "plainText"], in: asked).results
        XCTAssertEqual(withText[0].plainText, "Title 5 body text 5")
        XCTAssertNil(try events(asked)["notes.creationDate"])
    }

    func testListPagesAreFullEvenWhenATrashedNoteSitsInTheWindow() throws {
        // Sorted: 5, 4 (trashed), 3, 2, 1. Trashed notes are dropped before paging.
        let context = try makeContext()
        XCTAssertEqual(try ids(list(limit: 2, in: context).results), [5, 3])
        XCTAssertEqual(try ids(list(limit: 2, offset: 2, in: context).results), [2, 1])
        XCTAssertEqual(try ids(list(limit: 2, offset: 4, in: context).results), [])
    }

    func testListResumesAfterTheAnchorNoteWhenANewerNoteArrives() throws {
        let context = try makeContext()
        let page1 = try list(limit: 2, in: context).results
        XCTAssertEqual(ids(page1), [5, 3])
        let anchor = try NotesBridge.pageAnchor(XCTUnwrap(page1.last))

        context.evaluateScript("__rows.push(__mk(6, 'Notes'));") // newer than everything served
        XCTAssertEqual(try ids(list(limit: 2, offset: 2, in: context).results), [3, 2], "offset paging repeats note 3")
        let page2 = try list(limit: 2, offset: 2, seekingAfter: anchor, in: context).results
        XCTAssertEqual(ids(page2), [2, 1])
    }

    func testListResumesAtTheNextRowWhenTheAnchorNoteWasDeleted() throws {
        let context = try makeContext()
        let anchor = try NotesBridge.pageAnchor(XCTUnwrap(list(limit: 2, in: context).results.last))
        context.evaluateScript("__rows = __rows.filter(function(r) { return r.id !== '\(Self.noteId(3))'; });")
        XCTAssertEqual(try ids(list(limit: 2, offset: 2, seekingAfter: anchor, in: context).results), [2, 1])
    }

    func testListBreaksModificationTimeTiesByIdSoPagesCannotSplitATie() throws {
        let context = try makeContext(setup: "__rows[0].mod = __rows[2].mod; __rows[1].mod = __rows[2].mod;")
        let all = try ids(list(in: context).results)
        XCTAssertEqual(all, [5, 1, 2, 3], "notes 1, 2, 3 tie; ids ascend within the tie")
        let anchor = try NotesBridge.pageAnchor(XCTUnwrap(list(limit: 2, in: context).results.last))
        XCTAssertEqual(try ids(list(limit: 2, offset: 2, seekingAfter: anchor, in: context).results), [2, 3])
    }

    func testListAnchorIdIsEscapedAsAStringLiteral() throws {
        let context = try makeContext()
        let hostile = Cursor.Anchor(epoch: 0, id: "x'); __writes.push('pwned'); ('")
        XCTAssertEqual(try ids(list(seekingAfter: hostile, in: context).results), [])
        XCTAssertEqual(try writes(context), [])
    }

    func testListFolderFilterAndUnknownFolder() throws {
        let context = try makeContext()
        XCTAssertEqual(try ids(list(folder: "Work", in: context).results), [5, 2])
        XCTAssertEqual(try ids(list(folder: "No Such Folder", in: context).results), [])
        XCTAssertEqual(try ids(list(folder: "Recently Deleted", in: context).results), [], "trash stays hidden")
    }

    func testEmptyVaultIsAnEmptyListNotAnError() throws {
        // Plural getters throw -1728 on an empty collection.
        let context = try makeContext(setup: "__rows = [];")
        XCTAssertEqual(try list(in: context).results.count, 0)
        XCTAssertEqual(try search("x", in: context).results.count, 0)
    }

    // MARK: - Column alignment (DAT-09)

    func testAVaultThatChangesMidReadIsRetriedOnceAndStaysAligned() throws {
        // A sync deletes the newest note between the id read and the name
        // read, shifting every later index by one.
        let context = try makeContext(setup: """
        var __shifted = false;
        __onBulk = function(event) {
            if (event === 'notes.name' && !__shifted) { __shifted = true; __rows.shift(); }
        };
        """)
        let notes = try list(in: context).results
        XCTAssertEqual(ids(notes), [5, 3, 2], "second attempt reads the settled vault")
        for note in notes {
            let n = try XCTUnwrap(ids([note]).first)
            XCTAssertEqual(note.title, "Title \(n)", "a note must never get its neighbour's title")
            XCTAssertEqual(note.modificationDate, String(format: "2026-01-%02dT00:00:00.000Z", n))
        }
    }

    func testAVaultThatKeepsChangingFailsInsteadOfZippingMisalignedColumns() throws {
        let context = try makeContext(setup: """
        __rows = []; for (var n = 1; n <= 20; n++) { __rows.push(__mk(n, 'Notes')); }
        __onBulk = function(event) { if (event === 'notes.name') { __rows.shift(); } };
        """)
        XCTAssertThrowsError(try list(in: context)) { error in
            XCTAssertTrue("\(error)".contains("changed while it was being read"), "\(error)")
        }
        let searching = try makeContext(setup: """
        __rows = []; for (var n = 1; n <= 20; n++) { __rows.push(__mk(n, 'Notes')); }
        __onBulk = function(event) { if (event === 'notes.plaintext') { __rows.pop(); } };
        """)
        XCTAssertThrowsError(try search("title", in: searching))
    }

    // MARK: - Fallbacks when Notes refuses a bulk read

    func testListFallsBackToAskingEachNoteForItsFolder() throws {
        let context = try makeContext(setup: "__bulkThrows['notes.container'] = true;")
        let notes = try list(fields: ["id", "folder"], in: context).results
        XCTAssertEqual(ids(notes), [5, 3, 2, 1], "the trashed note is still skipped")
        XCTAssertEqual(notes.map(\.folder), ["Work", "Notes", "Work", "Notes"])
        XCTAssertEqual(try events(context)["note.container"], 5, "only the scanned window is asked")
    }

    /// A default list costs seven Apple Events whatever the vault size: ids,
    /// names, dates and containers, ids again to check nothing moved, and the
    /// folder ids and names. No `whose` lookup and no length reads (pippin-ai5s).
    func testTheDefaultListMakesSevenAppleEvents() throws {
        for folder in [nil, "Work"] {
            let context = try makeContext()
            let notes = try list(folder: folder, fields: Set(NoteInfo.essentialFields), in: context).results
            XCTAssertEqual(ids(notes), folder == nil ? [5, 3, 2, 1] : [5, 2])
            XCTAssertEqual(try events(context), [
                "notes.id": 2, "notes.name": 1, "notes.modificationDate": 1, "notes.container": 1,
                "folders.id": 1, "folders.name": 1,
            ], folder ?? "all notes")
        }
    }

    func testAFolderFilterThatMatchesNothingIsAnEmptyList() throws {
        let context = try makeContext()
        let script = NotesBridge.buildListScript(folder: "No Such Folder", limit: 50, fields: Set(NoteInfo.essentialFields))
        XCTAssertTrue(try run(script, in: context).contains(#""results":[]"#))
    }

    func testListFallsBackToPerNotePlaintext() throws {
        let context = try makeContext(setup: "__bulkThrows['notes.plaintext'] = true;")
        let notes = try list(limit: 2, in: context).results
        XCTAssertEqual(notes.map(\.plainText), ["Title 5 body text 5", "Title 3 body text 3"])
        XCTAssertEqual(try events(context)["note.plaintext"], 2)
    }

    func testANoteInAFolderNotesDoesNotListKeepsAnEmptyFolder() throws {
        let context = try makeContext(setup: "__rows[0].folder = 'Elsewhere';")
        let note = try XCTUnwrap(list(in: context).results.last)
        XCTAssertEqual(ids([note]), [1])
        XCTAssertEqual(note.folder, "")
        XCTAssertEqual(note.folderId, "")
    }

    // MARK: - Search

    func testSearchMatchesTitleOrBodyCaseInsensitivelyNewestFirst() throws {
        let context = try makeContext(setup: """
        __rows[0].plain = 'has the Needle in its body';
        __rows[4].name = 'NEEDLE in the title';
        __rows[3].plain = 'needle in a trashed note';
        """)
        let notes = try search("needle", in: context).results
        XCTAssertEqual(ids(notes), [5, 1], "newest first, trashed note 4 excluded")
        XCTAssertEqual(notes.map(\.title), ["NEEDLE in the title", "Title 1"])
        XCTAssertEqual(notes[1].plainText, "has the Needle in its body")
        XCTAssertEqual(notes.map(\.folder), ["Work", "Notes"])
        XCTAssertEqual(try ids(search("title", limit: 2, in: context).results), [5, 3])
        XCTAssertEqual(try ids(search("title", folder: "Work", in: context).results), [5, 2])
    }

    func testSearchOmitsPlaintextFromRowsThatWillNotCarryIt() throws {
        let context = try makeContext()
        let notes = try search("body text", fields: ["id", "title"], in: context).results
        XCTAssertEqual(notes.count, 4, "the body is still what was searched")
        XCTAssertEqual(Set(notes.map(\.plainText)), [""])
    }

    func testSearchFallsBackToPerNotePlaintextAndReportsAnUnfinishedScan() throws {
        let refused = try makeContext(setup: "__bulkThrows['notes.plaintext'] = true; __rows[0].plain = 'needle';")
        let complete = try search("needle", in: refused)
        XCTAssertEqual(ids(complete.results), [1])
        XCTAssertFalse(complete.timedOut)

        // Each per-note read costs 400 ms against a 1 s soft cap.
        let slow = try makeContext(setup: """
        __bulkThrows['notes.plaintext'] = true; __tick = 400; __rows[4].plain = 'needle';
        """)
        let partial = try search("needle", softTimeoutMs: 1000, in: slow)
        XCTAssertTrue(partial.timedOut, "an unfinished scan must say so")
        XCTAssertEqual(ids(partial.results), [], "note 5 was never reached, and that is reported, not hidden")
    }

    // MARK: - Folders and count

    func testFoldersFallBackWhenTheChainedReadIsRefused() throws {
        let context = try makeContext(setup: "__bulkThrows['folders.notes.id'] = true;")
        let json = try run(NotesBridge.buildListFoldersScript(), in: context)
        let outcome = try NotesBridge.decode(NotesBridge.Outcome<[NoteFolder]>.self, from: json)
        XCTAssertEqual(outcome.results.map(\.noteCount), [2, 2])
        XCTAssertEqual(outcome.results.map(\.id), ["f-notes", "f-work"])
    }

    func testAnEmptyFolderCountsZero() throws {
        let context = try makeContext(setup: "__folders.push({id: 'f-empty', name: 'Empty'});")
        let json = try run(NotesBridge.buildListFoldersScript(), in: context)
        let outcome = try NotesBridge.decode(NotesBridge.Outcome<[NoteFolder]>.self, from: json)
        XCTAssertEqual(outcome.results.last?.name, "Empty")
        XCTAssertEqual(outcome.results.last?.noteCount, 0)
    }

    func testCountIsOneCountEvent() throws {
        let context = try makeContext()
        XCTAssertEqual(try run(NotesBridge.buildCountScript(folder: nil), in: context), #"{"count":5}"#)
        XCTAssertEqual(try events(context), ["notes.length": 1])
        let inFolder = try makeContext()
        XCTAssertEqual(try run(NotesBridge.buildCountScript(folder: "Work"), in: inFolder), #"{"count":2}"#)
        XCTAssertNil(try events(inFolder)["notes()"])
    }

    // MARK: - Fields reach the bridge

    func testEmittedFieldsFollowTheFieldsOption() throws {
        XCTAssertEqual(try NotesCommand.emittedFields(NotesCommand.List.parse([]).output), Set(NoteInfo.essentialFields))
        XCTAssertEqual(
            try NotesCommand.emittedFields(NotesCommand.List.parse(["--fields", "id, plainText"]).output),
            ["id", "plainText"]
        )
        XCTAssertNil(try NotesCommand.emittedFields(NotesCommand.List.parse(["--fields", "all"]).output))
        XCTAssertFalse(NotesBridge.jsNeeds(Set(NoteInfo.essentialFields)).contains("true"))
        XCTAssertFalse(NotesBridge.jsNeeds(nil).contains("false"), "other callers of listNotes get every field")
    }
}
