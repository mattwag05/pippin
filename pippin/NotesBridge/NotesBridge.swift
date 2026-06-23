import Foundation

enum NotesBridge {
    // MARK: - Public API

    /// Outcome of a JXA query that walks an unbounded collection (notes,
    /// folders). The `timedOut` flag is set when the script's internal
    /// soft-timeout fires, so callers can surface a "partial results" advisory.
    /// Shared with `ContactsBridge.Outcome` via `BridgeOutcome<T>` (the
    /// `Decodable` conformance, used here to parse the JXA JSON, is conditional
    /// on `T: Decodable`). `MailBridge.ScanOutcome` stays separate by design.
    typealias Outcome<T: Decodable> = BridgeOutcome<T>

    /// Hard ceiling on the `limit` (page-window size) of a single `listNotes`
    /// fetch. Apple Notes JXA enumeration is slow, so the number of notes whose
    /// body/plaintext is fetched per call is capped to bound execution time.
    /// Pagination pushes `offset` down natively (the script skips the first
    /// `offset` sorted notes and returns only `pageSize + 1`), so deep pages are
    /// NOT bound by this ceiling — the all-notes sort enumeration is instead
    /// bounded by the soft timeout, surfaced as `timedOut`.
    static let maxListLimit = 500

    static func listNotes(folder: String? = nil, limit: Int = 50, offset: Int = 0, softTimeoutMs: Int = 22000) throws -> Outcome<[NoteInfo]> {
        let clampedLimit = max(1, min(limit, maxListLimit))
        let script = buildListScript(folder: folder, limit: clampedLimit, offset: max(0, offset), softTimeoutMs: softTimeoutMs)
        let json = try runScript(script)
        return try decode(Outcome<[NoteInfo]>.self, from: json)
    }

    static func showNote(id: String) throws -> NoteInfo {
        let script = buildShowScript(id: id)
        let json = try runScript(script)
        return try decode(NoteInfo.self, from: json)
    }

    static func searchNotes(query: String, folder: String? = nil, limit: Int = 50, softTimeoutMs: Int = 22000) throws -> Outcome<[NoteInfo]> {
        let clampedLimit = max(1, min(limit, 500))
        let script = buildSearchScript(query: query, folder: folder, limit: clampedLimit, softTimeoutMs: softTimeoutMs)
        let json = try runScript(script)
        return try decode(Outcome<[NoteInfo]>.self, from: json)
    }

    static func listFolders(softTimeoutMs: Int = 22000) throws -> Outcome<[NoteFolder]> {
        let script = buildListFoldersScript(softTimeoutMs: softTimeoutMs)
        let json = try runScript(script)
        return try decode(Outcome<[NoteFolder]>.self, from: json)
    }

    /// Count notes without fetching bodies. `pippin status` and similar
    /// dashboards just want `noteCount`; the full `listNotes` path iterates
    /// every note's `.body()` + `.plaintext()` over JXA, which busts the
    /// ScriptRunner cap on vaults of a few hundred notes. `app.notes().length`
    /// is a single Apple Event — typically <500ms.
    static func countNotes(folder: String? = nil) throws -> Int {
        let script = buildCountScript(folder: folder)
        let json = try runScript(script, timeoutSeconds: 10)
        return try decode(NoteCount.self, from: json).count
    }

    private struct NoteCount: Decodable { let count: Int }

    static func createNote(title: String, body: String? = nil, folder: String? = nil) throws -> BridgeActionResult {
        let script = buildCreateScript(title: title, body: body, folder: folder)
        let json = try runScript(script, timeoutSeconds: 20)
        return try decode(BridgeActionResult.self, from: json)
    }

    static func editNote(id: String, title: String? = nil, body: String? = nil, append: Bool = false) throws -> BridgeActionResult {
        let script = buildEditScript(id: id, title: title, body: body, append: append)
        let json = try runScript(script, timeoutSeconds: 20)
        return try decode(BridgeActionResult.self, from: json)
    }

    static func deleteNote(id: String) throws -> BridgeActionResult {
        let script = buildDeleteScript(id: id)
        let json = try runScript(script, timeoutSeconds: 20)
        return try decode(BridgeActionResult.self, from: json)
    }

    // MARK: - JXA Helpers

    /// JXA fragment shared by `buildListScript` / `buildSearchScript` that
    /// resolves the collection specifier `_notesRef`, materializes the element
    /// array `notes`, and bulk-fetches every note's `modificationDate` in a
    /// SINGLE Apple Event (`_notesRef.modificationDate()` → `_mods`). A prior
    /// loop read `notes[j].modificationDate()` once per note — O(n) Apple Events
    /// — which on large vaults spent the entire soft-timeout before the sort,
    /// leaving `pairs` empty and returning ZERO results (pippin-mo7). Bulk
    /// property access off the plural specifier is one round-trip regardless of
    /// vault size. Falls back to an empty `_mods` (notes keep `mod: 0`, native
    /// order) if the bulk getter throws, so results stay non-empty either way.
    /// Expects `folderFilter`, `app`, `_start`, `softTimeoutMs`, and `_meta` to
    /// already be declared in the script.
    static let jsResolveNotesAndBulkMods = """
    var _notesRef = null;
    if (folderFilter !== null) {
        var folders = app.folders.whose({name: folderFilter})();
        if (folders.length > 0) { _notesRef = folders[0].notes; }
    } else {
        _notesRef = app.notes;
    }
    var notes = _notesRef ? _notesRef() : [];
    var _mods = [];
    if (_notesRef) { try { _mods = _notesRef.modificationDate(); } catch (e) { _mods = []; } }
    """

    /// JXA fragment shared by `buildListScript` / `buildSearchScript`. Builds a
    /// plain JS array `pairs = [{note, mod, iso}]` from the already-materialized
    /// `notes` + bulk `_mods` arrays (see `jsResolveNotesAndBulkMods`), then
    /// sorts it newest-first on the in-memory `mod` key. The loop fires ZERO
    /// Apple Events (pure array indexing), so it completes near-instantly even
    /// on huge vaults — the soft-timeout check remains only as a backstop. A
    /// comparator that read the date off live note objects would fire an Apple
    /// Event per comparison (O(n log n) round-trips). `iso` caches the ISO-8601
    /// string so the results loop doesn't re-fetch the date. Expects `notes`,
    /// `_mods`, `_start`, `softTimeoutMs`, and `_meta` to already be declared.
    static let jsSortNotesByModDate = """
    var pairs = [];
    for (var j = 0; j < notes.length; j++) {
        if (Date.now() - _start > softTimeoutMs) { _meta.timedOut = true; break; }
        var _d = _mods[j] || null;
        pairs.push({ note: notes[j], mod: _d ? _d.getTime() : 0, iso: _d ? _d.toISOString() : '' });
    }
    pairs.sort(function(a, b) { return b.mod - a.mod; });
    """

    // MARK: - JXA Script Builders

    static func buildListScript(folder: String?, limit: Int, offset: Int = 0, softTimeoutMs: Int = 22000) -> String {
        let folderFilter = jsEscapeOptional(folder)
        let clampedTimeout = SoftTimeout.clamp(softTimeoutMs)
        return """
        var app = Application('Notes');
        app.includeStandardAdditions = true;
        var folderFilter = \(folderFilter);
        var limit = \(limit);
        var offset = \(max(0, offset));
        var softTimeoutMs = \(clampedTimeout);
        var _start = Date.now();
        var _meta = { timedOut: false };
        // Resolve specifier + bulk-fetch modificationDate (see jsResolveNotesAndBulkMods).
        \(jsResolveNotesAndBulkMods)
        // Sort by modificationDate, newest first (see jsSortNotesByModDate).
        \(jsSortNotesByModDate)
        // Native offset: skip the first `offset` sorted notes and emit only the
        // `limit` window. Body/plaintext (the expensive per-note Apple Events)
        // are fetched only for the returned window, so deep offsets don't
        // multiply body-fetch cost — they still iterate all notes for the sort,
        // which the soft cap above bounds (partial results set _meta.timedOut).
        var results = [];
        for (var i = offset; i < pairs.length && results.length < limit; i++) {
            if (Date.now() - _start > softTimeoutMs) { _meta.timedOut = true; break; }
            var note = pairs[i].note;
            var folderId = '';
            var folderName = '';
            try { folderId = note.container().id(); } catch(e) {}
            try { folderName = note.container().name(); } catch(e) {}
            results.push({
                id: note.id(),
                title: note.name(),
                body: note.body(),
                plainText: note.plaintext(),
                folder: folderName,
                folderId: folderId,
                account: null,
                creationDate: note.creationDate().toISOString(),
                modificationDate: pairs[i].iso
            });
        }
        JSON.stringify({results: results, meta: _meta});
        """
    }

    /// Returns `{count: N}` for the named folder (or whole vault when nil).
    /// No iteration, no body fetch — single Apple Event.
    static func buildCountScript(folder: String?) -> String {
        let folderFilter = jsEscapeOptional(folder)
        return """
        var app = Application('Notes');
        app.includeStandardAdditions = true;
        var folderFilter = \(folderFilter);
        var n = 0;
        if (folderFilter !== null) {
            var folders = app.folders.whose({name: folderFilter})();
            if (folders.length > 0) { n = folders[0].notes().length; }
        } else {
            n = app.notes().length;
        }
        JSON.stringify({count: n});
        """
    }

    static func buildShowScript(id: String) -> String {
        let safeId = jsEscape(id)
        return """
        var app = Application('Notes');
        app.includeStandardAdditions = true;
        var matches = app.notes.whose({id: '\(safeId)'})();
        if (matches.length === 0) { throw new Error('NOTESBRIDGE_ERR_NOT_FOUND: \(safeId)'); }
        var note = matches[0];
        var folderId = '';
        var folderName = '';
        try { folderId = note.container().id(); } catch(e) {}
        try { folderName = note.container().name(); } catch(e) {}
        var result = {
            id: note.id(),
            title: note.name(),
            body: note.body(),
            plainText: note.plaintext(),
            folder: folderName,
            folderId: folderId,
            account: null,
            creationDate: note.creationDate().toISOString(),
            modificationDate: note.modificationDate().toISOString()
        };
        JSON.stringify(result);
        """
    }

    static func buildSearchScript(query: String, folder: String?, limit: Int, softTimeoutMs: Int = 22000) -> String {
        let safeQuery = jsEscape(query)
        let folderFilter = jsEscapeOptional(folder)
        let clampedTimeout = SoftTimeout.clamp(softTimeoutMs)
        return """
        var app = Application('Notes');
        app.includeStandardAdditions = true;
        var query = '\(safeQuery)'.toLowerCase();
        var folderFilter = \(folderFilter);
        var limit = \(limit);
        var softTimeoutMs = \(clampedTimeout);
        var _start = Date.now();
        var _meta = { timedOut: false };
        // Resolve specifier + bulk-fetch modificationDate (see jsResolveNotesAndBulkMods).
        \(jsResolveNotesAndBulkMods)
        // Sort by modificationDate before filtering — preserves "most recently
        // modified matches first" while keeping the pre-filter work bounded
        // (see jsSortNotesByModDate).
        \(jsSortNotesByModDate)
        var results = [];
        for (var i = 0; i < pairs.length && results.length < limit; i++) {
            if (Date.now() - _start > softTimeoutMs) { _meta.timedOut = true; break; }
            var note = pairs[i].note;
            var title = '';
            var plain = '';
            try { title = note.name() || ''; } catch(e) {}
            try { plain = note.plaintext() || ''; } catch(e) {}
            var matched = title.toLowerCase().indexOf(query) !== -1
                       || plain.toLowerCase().indexOf(query) !== -1;
            if (matched) {
                var folderId = '';
                var folderName = '';
                try { folderId = note.container().id(); } catch(e) {}
                try { folderName = note.container().name(); } catch(e) {}
                results.push({
                    id: note.id(),
                    title: note.name(),
                    body: note.body(),
                    plainText: note.plaintext(),
                    folder: folderName,
                    folderId: folderId,
                    account: null,
                    creationDate: note.creationDate().toISOString(),
                    modificationDate: pairs[i].iso
                });
            }
        }
        JSON.stringify({results: results, meta: _meta});
        """
    }

    static func buildListFoldersScript(softTimeoutMs: Int = 22000) -> String {
        let clampedTimeout = SoftTimeout.clamp(softTimeoutMs)
        return """
        var app = Application('Notes');
        app.includeStandardAdditions = true;
        var softTimeoutMs = \(clampedTimeout);
        var _start = Date.now();
        var _meta = { timedOut: false };
        var folders = app.folders();
        var results = [];
        for (var i = 0; i < folders.length; i++) {
            if (Date.now() - _start > softTimeoutMs) { _meta.timedOut = true; break; }
            var f = folders[i];
            var count = 0;
            try { count = f.notes().length; } catch(e) {}
            results.push({
                id: f.id(),
                name: f.name(),
                account: null,
                noteCount: count
            });
        }
        JSON.stringify({results: results, meta: _meta});
        """
    }

    static func buildCreateScript(title: String, body: String?, folder: String?) -> String {
        let safeTitle = jsEscape(title)
        let safeBody = jsEscape(body ?? "")
        let folderFilter = jsEscapeOptional(folder)
        return """
        var app = Application('Notes');
        app.includeStandardAdditions = true;
        var folderFilter = \(folderFilter);
        var targetFolder = null;
        if (folderFilter !== null) {
            var folders = app.folders.whose({name: folderFilter})();
            if (folders.length > 0) { targetFolder = folders[0]; }
        }
        var props = {name: '\(safeTitle)', body: '\(safeBody)'};
        var note;
        if (targetFolder !== null) {
            note = app.make({new: 'note', withProperties: props, at: targetFolder});
        } else {
            note = app.make({new: 'note', withProperties: props});
        }
        JSON.stringify({
            success: true,
            action: 'create',
            details: {
                id: note.id(),
                title: '\(safeTitle)'
            }
        });
        """
    }

    static func buildEditScript(id: String, title: String?, body: String?, append: Bool) -> String {
        let safeId = jsEscape(id)
        let safeTitle = jsEscapeOptional(title)
        let safeBody = jsEscapeOptional(body)
        return """
        var app = Application('Notes');
        app.includeStandardAdditions = true;
        var matches = app.notes.whose({id: '\(safeId)'})();
        if (matches.length === 0) { throw new Error('NOTESBRIDGE_ERR_NOT_FOUND: \(safeId)'); }
        var note = matches[0];
        var newTitle = \(safeTitle);
        var newBody = \(safeBody);
        var isAppend = \(append ? "true" : "false");
        if (newTitle !== null) { note.name = newTitle; }
        if (newBody !== null) {
            if (isAppend) {
                var existing = '';
                try { existing = note.body(); } catch(e) {}
                note.body = existing + newBody;
            } else {
                note.body = newBody;
            }
        }
        JSON.stringify({
            success: true,
            action: 'edit',
            details: {
                id: '\(safeId)'
            }
        });
        """
    }

    static func buildDeleteScript(id: String) -> String {
        let safeId = jsEscape(id)
        return """
        var app = Application('Notes');
        app.includeStandardAdditions = true;
        var matches = app.notes.whose({id: '\(safeId)'})();
        if (matches.length === 0) { throw new Error('NOTESBRIDGE_ERR_NOT_FOUND: \(safeId)'); }
        app.delete(matches[0]);
        JSON.stringify({
            success: true,
            action: 'delete',
            details: {
                id: '\(safeId)'
            }
        });
        """
    }

    // MARK: - Process Runner

    private static func runScript(_ script: String, timeoutSeconds: Int = 35) throws -> String {
        do {
            return try ScriptRunner.run(
                script,
                timeoutSeconds: timeoutSeconds,
                appName: "Notes",
                automationBundleID: "com.apple.Notes"
            )
        } catch ScriptRunnerError.automationDenied {
            throw NotesBridgeError.accessDenied
        } catch ScriptRunnerError.timeout {
            throw NotesBridgeError.timeout
        } catch let ScriptRunnerError.nonZeroExit(msg) {
            throw NotesBridgeError.scriptFailed(msg)
        } catch let ScriptRunnerError.stderrOnSuccess(msg) {
            throw NotesBridgeError.scriptFailed(msg)
        } catch let ScriptRunnerError.launchFailed(msg) {
            throw NotesBridgeError.scriptFailed("osascript launch failed: \(msg)")
        }
    }

    // MARK: - Decoder

    static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        guard !json.isEmpty else {
            throw NotesBridgeError.decodingFailed("osascript returned empty output — possible TCC denial")
        }
        guard let data = json.data(using: .utf8) else {
            throw NotesBridgeError.decodingFailed("Non-UTF8 output")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw NotesBridgeError.decodingFailed(error.localizedDescription)
        }
    }
}
