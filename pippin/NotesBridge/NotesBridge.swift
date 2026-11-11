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

    /// `fields` names the row fields the caller will keep (nil = all). The
    /// script skips the reads behind fields nobody asked for; a skipped field
    /// comes back as an empty string.
    static func listNotes(
        folder: String? = nil, limit: Int = 50, offset: Int = 0, seekingAfter anchor: Cursor.Anchor? = nil,
        fields: Set<String>? = nil, softTimeoutMs: Int = 22000
    ) throws -> Outcome<[NoteInfo]> {
        let clampedLimit = max(1, min(limit, maxListLimit))
        let script = buildListScript(
            folder: folder, limit: clampedLimit, offset: max(0, offset), seekingAfter: anchor,
            fields: fields, softTimeoutMs: softTimeoutMs
        )
        let json = try runScript(script, idempotent: true)
        return try decode(Outcome<[NoteInfo]>.self, from: json)
    }

    /// Keyset position of a listed note (newest modification first, then id ascending).
    static func pageAnchor(_ note: NoteInfo) -> Cursor.Anchor {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ms = parser.date(from: note.modificationDate).map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? 0
        return Cursor.Anchor(epoch: ms, id: note.id)
    }

    static func showNote(id: String) throws -> NoteInfo {
        let script = buildShowScript(id: id)
        let json = try runScript(script, idempotent: true)
        return try decode(NoteInfo.self, from: json)
    }

    static func searchNotes(
        query: String, folder: String? = nil, limit: Int = 50, fields: Set<String>? = nil, softTimeoutMs: Int = 22000
    ) throws -> Outcome<[NoteInfo]> {
        let clampedLimit = max(1, min(limit, 500))
        let script = buildSearchScript(
            query: query, folder: folder, limit: clampedLimit, fields: fields, softTimeoutMs: softTimeoutMs
        )
        let json = try runScript(script, idempotent: true)
        return try decode(Outcome<[NoteInfo]>.self, from: json)
    }

    static func listFolders(softTimeoutMs: Int = 22000) throws -> Outcome<[NoteFolder]> {
        let script = buildListFoldersScript(softTimeoutMs: softTimeoutMs)
        let json = try runScript(script, idempotent: true)
        return try decode(Outcome<[NoteFolder]>.self, from: json)
    }

    /// Count notes without fetching anything else. `pippin status` and similar
    /// dashboards just want `noteCount`. `app.notes.length` is one count Apple
    /// Event; `app.notes().length` materialized every note specifier first.
    static func countNotes(folder: String? = nil) throws -> Int {
        let script = buildCountScript(folder: folder)
        let json = try runScript(script, timeoutSeconds: 10, idempotent: true)
        return try decode(NoteCount.self, from: json).count
    }

    private struct NoteCount: Decodable { let count: Int }

    static func createNote(title: String, body: String? = nil, folder: String? = nil, html: Bool = false) throws -> BridgeActionResult {
        let script = buildCreateScript(title: title, body: body, folder: folder, html: html)
        let json = try withWriteLock { try runScript(script, timeoutSeconds: 20) }
        return try decode(BridgeActionResult.self, from: json)
    }

    static func editNote(
        id: String, title: String? = nil, body: String? = nil, append: Bool = false, html: Bool = false,
        dryRun: Bool = false
    ) throws -> NoteEditResult {
        let script = buildEditScript(id: id, title: title, body: body, append: append, html: html, dryRun: dryRun)
        let json = try withWriteLock { try runScript(script, timeoutSeconds: 20) }
        return try decode(NoteEditResult.self, from: json)
    }

    static func deleteNote(id: String) throws -> BridgeActionResult {
        let script = buildDeleteScript(id: id)
        let json = try withWriteLock { try runScript(script, timeoutSeconds: 20) }
        return try decode(BridgeActionResult.self, from: json)
    }

    // MARK: - Write lock

    static let writeLockPath = NSHomeDirectory() + "/.config/pippin/notes-write.lock"

    /// Run a Notes write while holding an exclusive advisory lock, so
    /// concurrent pippin processes take turns. An append is a read-modify-write
    /// across two Apple Events; five parallel appends all reported success and
    /// one survived (RT-30). The lock only orders pippin's own writes: an edit
    /// made in the Notes app, or a sync, can still land between the read and
    /// the write. The wait is unbounded here; each holder is bounded by its
    /// script timeout and the kernel drops the lock when a holder exits.
    static func withWriteLock<T>(path: String = writeLockPath, _ body: () throws -> T) throws -> T {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            throw NotesBridgeError.scriptFailed("Could not open the Notes write lock at \(path); nothing was written.")
        }
        defer { close(fd) } // closing the descriptor releases the lock
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw NotesBridgeError.scriptFailed("Could not take the Notes write lock at \(path); nothing was written.")
            }
        }
        return try body()
    }

    // MARK: - JXA Helpers

    /// JXA shared by list, search and folders: whole-column reads on the plural
    /// specifier. One Apple Event returns a property for EVERY note, where a
    /// per-note loop costs one event per note per property; that loop made
    /// `notes list` about 217 ms a row, and `notes search` hit the soft cap
    /// before it had read the vault (pippin-mo7, PERF-1/2/6).
    ///
    /// `_bulkRead` brackets the columns with two reads of the id column. A sync
    /// that adds or removes a note mid-read shifts every later index, and
    /// zipping the columns anyway would give each note its neighbour's fields,
    /// so a mismatch is retried once and then fails (DAT-09). `optional`
    /// columns that Notes refuses come back null for the caller to handle.
    ///
    /// An empty collection, or a folder that does not exist, answers the first
    /// read with -1728, so no separate length read is spent on it.
    ///
    /// `_folderIndex` reads every folder's id and name in two events and, when
    /// asked, every folder's note ids in a third through the chained specifier.
    /// Plural getters throw -1728 on an empty collection, hence the length
    /// guards. Expects `app` to be declared.
    static let jsBulkNotes = """
    function _bulkRead(spec, columns, optional) {
        var all = columns.concat(optional);
        var none = {id: []};
        all.forEach(function(c) { none[c] = []; });
        if (!spec) { return none; }
        for (var attempt = 0; attempt < 2; attempt++) {
            var ids;
            try { ids = spec.id(); } catch (e) {
                if (e.errorNumber === -1728 || /\\(-1728\\)/.test(String(e))) { return none; }
                throw e;
            }
            var out = {id: ids};
            var aligned = true;
            all.forEach(function(c) {
                try { out[c] = spec[c](); } catch (e) {
                    if (optional.indexOf(c) === -1) { throw e; }
                    out[c] = null;
                }
                if (out[c] !== null && out[c].length !== out.id.length) { aligned = false; }
            });
            var after = spec.id();
            if (aligned && after.length === out.id.length && after.join('\\n') === out.id.join('\\n')) { return out; }
        }
        throw new Error('Notes changed while it was being read. Retry.');
    }
    function _folderIndex(withNotes) {
        var spec = app.folders;
        var ids;
        try { ids = spec.id(); } catch (e) {
            if (e.errorNumber === -1728 || /\\(-1728\\)/.test(String(e))) { return {id: [], name: [], notes: []}; }
            throw e;
        }
        var out = {id: ids, name: spec.name(), notes: null};
        if (!withNotes) {
            if (out.name.length !== out.id.length) { throw new Error('Notes folders changed while they were being read. Retry.'); }
            return out;
        }
        try { out.notes = spec.notes.id(); } catch (e) { out.notes = null; }
        if (out.notes === null) {
            // Chained read refused: one read per folder. An empty folder throws.
            var each = spec();
            out.notes = [];
            for (var f = 0; f < each.length; f++) {
                try { out.notes.push(each[f].notes.id()); } catch (e) { out.notes.push([]); }
            }
        }
        if (out.name.length !== out.id.length || out.notes.length !== out.id.length) {
            throw new Error('Notes folders changed while they were being read. Retry.');
        }
        return out;
    }
    """

    /// JXA shared by list and search: resolve the note collection `_notesRef`
    /// and the two ways to learn a note's folder.
    ///
    /// `_folderAt` uses the bulk `container` column: one Apple Event returns a
    /// by-id folder specifier per note, and a specifier's display string
    /// carries the folder id without asking Notes again. A folder's own `notes`
    /// list is NOT a substitute: on a real vault one folder listed notes whose
    /// container was a different folder. `_folderOfNote` asks the note itself
    /// (three events), for the rows the bulk read could not place.
    /// The folder filter is a `byName` specifier, which costs no event (it
    /// matches case-insensitively, as `whose` did): a missing folder answers
    /// the first column read with -1728, which `_bulkRead` returns as no
    /// notes. The folder index is read only once a row needs it, so an empty
    /// result costs one event. A chained `notes.container.name` read would
    /// save the index, but Notes answers it with nulls (pippin-ai5s).
    /// Expects `folderFilter` and `jsBulkNotes`.
    static let jsResolveNotes = """
    var _notesRef = folderFilter !== null ? app.folders.byName(folderFilter).notes : app.notes;
    var _folderName = null;
    function _folderAt(cols, j) {
        var spec = cols.container ? cols.container[j] : null;
        if (!spec) { return null; }
        if (_folderName === null) {
            _folderName = {};
            var _fi = _folderIndex(false);
            for (var _f = 0; _f < _fi.id.length; _f++) { _folderName[_fi.id[_f]] = _fi.name[_f]; }
        }
        var m = /byId\\("([^"]+)"\\)$/.exec(Automation.getDisplayString(spec));
        if (!m || _folderName[m[1]] === undefined) { return null; }
        return {id: m[1], name: _folderName[m[1]]};
    }
    function _folderOfNote(noteId) {
        try {
            var c = _notesRef.byId(noteId).container();
            return {id: c.id(), name: c.name()};
        } catch (e) { return {id: '', name: ''}; }
    }
    """

    /// JS flags for the optional row fields. `plainText` and `createdAt` cost
    /// reads the default output drops, so they are fetched only on request.
    static func jsNeeds(_ fields: Set<String>?) -> String {
        let plain = fields?.contains("plainText") ?? true
        let created = fields?.contains("createdAt") ?? true
        return "var needPlain = \(plain); var needCreated = \(created);"
    }

    /// Apple Notes `delete` is a soft-delete into this folder (no scriptable
    /// hard-delete / empty-trash exists — pippin-cxd). list/show/search/folders
    /// exclude it so a "deleted" note stops appearing; it still auto-purges from
    /// the trash after 30 days, exactly like the Notes UI.
    /// Notes names the folder in the user's language and the scripting
    /// dictionary has no "is deleted" flag, so every name it may carry is
    /// matched: English, plus the name Notes itself shows (pippin-nrrx).
    static let recentlyDeletedFolderNames = trashFolderNames(
        localized: notesStringsTable().flatMap { trashFolderName(in: $0, preferences: Locale.preferredLanguages) }
    )

    /// Notes' own name for the folder, per language (`[language: name]`).
    static func notesStringsTable() -> [String: [String: String]]? {
        let path = "/System/Library/PrivateFrameworks/NotesShared.framework/Resources/Localizable.loctable"
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        // Values mix strings and plural-rule dictionaries: keep only the one key.
        return (plist as? [String: Any])?.compactMapValues { language in
            ((language as? [String: Any])?["Recently Deleted"] as? String).map { ["Recently Deleted": $0] }
        }
    }

    /// The folder name in the best match for `preferences` that the table has.
    static func trashFolderName(in table: [String: [String: String]], preferences: [String]) -> String? {
        let languages = table.filter { $0.value["Recently Deleted"] != nil }.map(\.key)
        guard let best = Bundle.preferredLocalizations(from: languages, forPreferences: preferences).first else { return nil }
        return table[best]?["Recently Deleted"]
    }

    static func trashFolderNames(localized: String?) -> [String] {
        guard let localized, localized != "Recently Deleted" else { return ["Recently Deleted"] }
        return ["Recently Deleted", localized]
    }

    /// JXA boolean: `expr` (a folder name) is one of `names`.
    static func jsIsTrash(_ expr: String, names: [String] = recentlyDeletedFolderNames) -> String {
        "(" + names.map { "\(expr) === '\(jsEscape($0))'" }.joined(separator: " || ") + ")"
    }

    /// JXA fragment for the mutating scripts: refuse a `note` that already sits
    /// in Recently Deleted. A second `delete` there is how Notes purges a note
    /// permanently (RT-32), so the delete script passes `failClosed` and treats
    /// an unreadable folder as "might be trashed". Edit tolerates an unreadable
    /// folder, since Notes itself rejects writes to a trashed note.
    /// Matches every name in `recentlyDeletedFolderNames`, like the read paths.
    static func jsRefuseTrashedNote(_ safeId: String, failClosed: Bool) -> String {
        let read = jsIsTrash("note.container().name()")
        return """
        var _trashed = false;
        \(failClosed ? "_trashed = \(read);" : "try { _trashed = \(read); } catch(e) {}")
        if (_trashed) { throw new Error('NOTESBRIDGE_ERR_IN_TRASH: \(safeId)'); }
        """
    }

    // MARK: - JXA Script Builders

    static func buildListScript(
        folder: String?, limit: Int, offset: Int = 0, seekingAfter anchor: Cursor.Anchor? = nil,
        fields: Set<String>? = nil, softTimeoutMs: Int = 22000
    ) -> String {
        let folderFilter = jsEscapeOptional(folder)
        let clampedTimeout = SoftTimeout.clamp(softTimeoutMs)
        return """
        var app = Application('Notes');
        app.includeStandardAdditions = true;
        var folderFilter = \(folderFilter);
        var limit = \(limit);
        var offset = \(max(0, offset));
        var anchorId = \(jsEscapeOptional(anchor?.id));
        var anchorMod = \(anchor?.epoch ?? 0);
        var softTimeoutMs = \(clampedTimeout);
        var _start = Date.now();
        var _meta = { timedOut: false };
        \(jsNeeds(fields))
        \(jsBulkNotes)
        \(jsResolveNotes)
        var cols = _bulkRead(
            _notesRef, ['name', 'modificationDate'].concat(needCreated ? ['creationDate'] : []),
            ['container'].concat(needPlain ? ['plaintext'] : [])
        );
        // Pure JS from here to the sort: no Apple Events. Soft-deleted notes
        // (pippin-cxd) are dropped BEFORE paging, so a page is not short.
        var rows = [];
        for (var j = 0; j < cols.id.length; j++) {
            var _in = _folderAt(cols, j);
            if (_in && \(jsIsTrash("_in.name"))) { continue; }
            var _d = cols.modificationDate[j] || null;
            rows.push({j: j, folder: _in, mod: _d ? _d.getTime() : 0, iso: _d ? _d.toISOString() : ''});
        }
        // Newest first; ties by id so the order is total and a keyset cursor can resume in it.
        rows.sort(function(a, b) {
            if (a.mod !== b.mod) { return b.mod - a.mod; }
            var x = cols.id[a.j], y = cols.id[b.j];
            return x < y ? -1 : (x > y ? 1 : 0);
        });
        // A keyset cursor resumes after the anchor note, or at the first row sorting
        // after it when that note is gone; without one the offset applies.
        var start = offset;
        if (anchorId !== null) {
            start = rows.length;
            for (var k = 0; k < rows.length; k++) {
                if (cols.id[rows[k].j] === anchorId) { start = k + 1; break; }
            }
            if (start === rows.length) {
                for (var m = 0; m < rows.length; m++) {
                    var _id = cols.id[rows[m].j];
                    if (rows[m].mod < anchorMod || (rows[m].mod === anchorMod && _id > anchorId)) { start = m; break; }
                }
            }
        }
        // Emit only the `limit` window. The HTML body is never
        // fetched here (`notes show` does that).
        var results = [];
        for (var i = start; i < rows.length && results.length < limit; i++) {
            // Only the per-note reads below can be slow, so the soft cap is
            // checked here.
            if (Date.now() - _start > softTimeoutMs) { _meta.timedOut = true; break; }
            var row = rows[i];
            var noteId = cols.id[row.j];
            if (!row.folder) {
                row.folder = _folderOfNote(noteId);
                if (\(jsIsTrash("row.folder.name"))) { continue; }
            }
            // plainText is read only when asked for: from the bulk column, or
            // per note if Notes refused the bulk read.
            var plain = '';
            if (needPlain && cols.plaintext) {
                plain = cols.plaintext[row.j] || '';
            } else if (needPlain) {
                try { plain = _notesRef.byId(noteId).plaintext() || ''; } catch (e) {}
            }
            var _created = needCreated ? cols.creationDate[row.j] : null;
            results.push({
                id: noteId,
                title: cols.name[row.j],
                plainText: plain,
                folder: row.folder.name,
                folderId: row.folder.id,
                account: null,
                createdAt: _created ? _created.toISOString() : '',
                modifiedAt: row.iso
            });
        }
        JSON.stringify({results: results, meta: _meta});
        """
    }

    /// Returns `{count: N}` for the named folder (or whole vault when nil).
    /// No iteration, no body fetch: one count Apple Event.
    static func buildCountScript(folder: String?) -> String {
        let folderFilter = jsEscapeOptional(folder)
        return """
        var app = Application('Notes');
        app.includeStandardAdditions = true;
        var folderFilter = \(folderFilter);
        var n = 0;
        if (folderFilter !== null) {
            var folders = app.folders.whose({name: folderFilter})();
            if (folders.length > 0) { n = folders[0].notes.length; }
        } else {
            n = app.notes.length;
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
        try {
            var _c = note.container();
            folderId = _c.id();
            folderName = _c.name();
        } catch(e) {}
        // A soft-deleted note still resolves by id — treat it as gone (pippin-cxd).
        if (\(jsIsTrash("folderName"))) { throw new Error('NOTESBRIDGE_ERR_NOT_FOUND: \(safeId)'); }
        var result = {
            id: note.id(),
            title: note.name(),
            body: note.body(),
            plainText: note.plaintext(),
            folder: folderName,
            folderId: folderId,
            account: null,
            createdAt: note.creationDate().toISOString(),
            modifiedAt: note.modificationDate().toISOString()
        };
        JSON.stringify(result);
        """
    }

    static func buildSearchScript(
        query: String, folder: String?, limit: Int, fields: Set<String>? = nil, softTimeoutMs: Int = 22000
    ) -> String {
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
        \(jsNeeds(fields))
        \(jsBulkNotes)
        \(jsResolveNotes)
        // Titles and plaintext for the WHOLE collection in one Apple Event
        // each, so a query that matches nothing is still a complete answer.
        var cols = _bulkRead(
            _notesRef, ['name', 'modificationDate'].concat(needCreated ? ['creationDate'] : []),
            ['plaintext', 'container']
        );
        var plains = cols.plaintext;
        if (plains === null) {
            // Bulk plaintext refused: read it per note under the soft cap.
            // Notes not reached match on title only and the result is partial.
            plains = [];
            for (var p = 0; p < cols.id.length; p++) {
                if (Date.now() - _start > softTimeoutMs) { _meta.timedOut = true; break; }
                try { plains.push(_notesRef.byId(cols.id[p]).plaintext() || ''); } catch (e) { plains.push(''); }
            }
        }
        var rows = [];
        for (var j = 0; j < cols.id.length; j++) {
            var title = cols.name[j] || '';
            var plain = plains[j] || '';
            if (title.toLowerCase().indexOf(query) === -1 && plain.toLowerCase().indexOf(query) === -1) { continue; }
            var _in = _folderAt(cols, j);
            // Skip soft-deleted notes (pippin-cxd).
            if (_in && \(jsIsTrash("_in.name"))) { continue; }
            var _d = cols.modificationDate[j] || null;
            rows.push({j: j, title: title, plain: plain, folder: _in, mod: _d ? _d.getTime() : 0, iso: _d ? _d.toISOString() : ''});
        }
        // Most recently modified matches first.
        rows.sort(function(a, b) { return b.mod - a.mod; });
        var results = [];
        for (var i = 0; i < rows.length && results.length < limit; i++) {
            if (Date.now() - _start > softTimeoutMs) { _meta.timedOut = true; break; }
            var row = rows[i];
            if (!row.folder) {
                row.folder = _folderOfNote(cols.id[row.j]);
                if (\(jsIsTrash("row.folder.name"))) { continue; }
            }
            var _created = needCreated ? cols.creationDate[row.j] : null;
            results.push({
                id: cols.id[row.j],
                title: row.title,
                plainText: needPlain ? row.plain : '',
                folder: row.folder.name,
                folderId: row.folder.id,
                account: null,
                createdAt: _created ? _created.toISOString() : '',
                modifiedAt: row.iso
            });
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
        \(jsBulkNotes)
        // Three Apple Events for every folder; the count is the length of each
        // folder's id column, not a materialized note list (PERF-6).
        var _fi = _folderIndex(true);
        var results = [];
        for (var i = 0; i < _fi.id.length; i++) {
            // Hide the soft-delete trash folder from the live folder list (pippin-cxd).
            if (\(jsIsTrash("_fi.name[i]"))) { continue; }
            results.push({
                id: _fi.id[i],
                name: _fi.name[i],
                account: null,
                noteCount: _fi.notes[i].length
            });
        }
        JSON.stringify({results: results, meta: _meta});
        """
    }

    /// Convert plain text to the HTML shape Notes.app itself produces: each
    /// line becomes `<div>line</div>`, a blank line becomes `<div><br></div>`
    /// (paragraph separation falls out of that). `&`, `<`, `>` are entity-
    /// escaped first so literal text survives. A single trailing newline is
    /// dropped so it doesn't produce a stray empty div. Needed because
    /// `note.body` is an HTML property — assigning plain text collapses all
    /// newlines (issue #26).
    static func textToNotesHTML(_ text: String) -> String {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        if normalized.hasSuffix("\n") { normalized.removeLast() }
        guard !normalized.isEmpty else { return "" }
        return normalized
            .components(separatedBy: "\n")
            .map { line in
                guard !line.isEmpty else { return "<div><br></div>" }
                let escaped = line
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                return "<div>\(escaped)</div>"
            }
            .joined()
    }

    static func buildCreateScript(title: String, body: String?, folder: String?, html: Bool = false) -> String {
        let safeTitle = jsEscape(title)
        let safeBody = jsEscape(html ? (body ?? "") : textToNotesHTML(body ?? ""))
        let folderFilter = jsEscapeOptional(folder)
        return """
        var app = Application('Notes');
        app.includeStandardAdditions = true;
        var folderFilter = \(folderFilter);
        var targetFolder = null;
        if (folderFilter !== null) {
            var folders = app.folders.whose({name: folderFilter})();
            // A missing folder is an error: falling back to the default folder
            // reported success for a note filed somewhere unasked (RT-5).
            if (folders.length === 0) { throw new Error('NOTESBRIDGE_ERR_FOLDER_NOT_FOUND: ' + folderFilter); }
            targetFolder = folders[0];
        }
        var props ={name: '\(safeTitle)', body: '\(safeBody)'};
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

    static func buildEditScript(
        id: String, title: String?, body: String?, append: Bool, html: Bool = false, dryRun: Bool = false
    ) -> String {
        let safeId = jsEscape(id)
        let safeTitle = jsEscapeOptional(title)
        // Append concatenates two HTML fragments, which is fine — the appended
        // fragment gets the same plain-text→HTML conversion as a replacement.
        let safeBody = jsEscapeOptional(html ? body : body.map(textToNotesHTML))
        return """
        var app = Application('Notes');
        app.includeStandardAdditions = true;
        var matches = app.notes.whose({id: '\(safeId)'})();
        if (matches.length === 0) { throw new Error('NOTESBRIDGE_ERR_NOT_FOUND: \(safeId)'); }
        var note = matches[0];
        \(jsRefuseTrashedNote(safeId, failClosed: false))
        var newTitle = \(safeTitle);
        var newBody = \(safeBody);
        var isAppend = \(append ? "true" : "false");
        var dryRun = \(dryRun ? "true" : "false");
        // Read the current body BEFORE any write and let a failed read throw.
        // Swallowing it turned an append into a replace: the note's whole body
        // became the appended fragment (RC-04).
        var existing = note.body();
        if (typeof existing !== 'string') { throw new Error('Could not read the current note body; nothing was written.'); }
        var finalBody = newBody === null ? existing : (isAppend ? existing + newBody : newBody);
        var finalTitle = newTitle !== null ? newTitle : note.name();
        if (!dryRun) {
            if (newTitle !== null) { note.name = newTitle; }
            if (newBody !== null) { note.body = finalBody; }
        }
        JSON.stringify({
            success: true,
            action: 'edit',
            details: {
                id: '\(safeId)'
            },
            title: finalTitle,
            previousBodyLength: existing.length,
            newBodyLength: finalBody.length,
            dryRun: dryRun
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
        var note = matches[0];
        \(jsRefuseTrashedNote(safeId, failClosed: true))
        app.delete(note);
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

    private static func runScript(_ script: String, timeoutSeconds: Int = 35, idempotent: Bool = false) throws -> String {
        do {
            return try ScriptRunner.run(
                script,
                timeoutSeconds: timeoutSeconds,
                appName: "Notes",
                idempotent: idempotent,
                automationBundleID: "com.apple.Notes"
            )
        } catch ScriptRunnerError.automationDenied {
            throw NotesBridgeError.accessDenied
        } catch ScriptRunnerError.timeout {
            guard idempotent else { throw ScriptRunnerError.outcomeUnknown(app: "Notes") }
            throw NotesBridgeError.timeout
        } catch let ScriptRunnerError.nonZeroExit(msg) {
            throw mapScriptFailure(msg)
        } catch let ScriptRunnerError.stderrOnSuccess(msg) {
            throw mapScriptFailure(msg)
        } catch let ScriptRunnerError.launchFailed(msg) {
            throw NotesBridgeError.scriptFailed("osascript launch failed: \(msg)")
        }
    }

    /// Map a raw osascript failure to a typed error. JXA errors always arrive
    /// as opaque stderr text, so the show/edit/delete scripts throw the
    /// sentinel `NOTESBRIDGE_ERR_NOT_FOUND: <id>` and this seam detects it,
    /// producing `.noteNotFound` (agent code `note_not_found` → exit 3) instead
    /// of `.scriptFailed` (exit 5). The osascript wrapper text looks like
    /// `execution error: Error: NOTESBRIDGE_ERR_NOT_FOUND: <id> (-2700)`, so
    /// the id is the first whitespace-delimited token after the marker.
    static func mapScriptFailure(_ msg: String) -> NotesBridgeError {
        if let id = sentinelDetail("NOTESBRIDGE_ERR_NOT_FOUND", in: msg) { return .noteNotFound(id) }
        if let id = sentinelDetail("NOTESBRIDGE_ERR_IN_TRASH", in: msg) { return .noteInTrash(id) }
        // A folder name may contain spaces: take everything up to osascript's
        // trailing " (-2700)" error number.
        if let range = msg.range(of: "NOTESBRIDGE_ERR_FOLDER_NOT_FOUND: ") {
            let name = msg[range.upperBound...].replacing(/\s*\(-\d+\)\s*$/, with: "")
            return .folderNotFound(String(name))
        }
        return .scriptFailed(msg)
    }

    /// The first whitespace-delimited token after `marker`, or nil when the
    /// message does not carry it.
    private static func sentinelDetail(_ marker: String, in msg: String) -> String? {
        guard let range = msg.range(of: marker) else { return nil }
        let tail = msg[range.upperBound...].drop { $0 == ":" || $0 == " " }
        return tail.components(separatedBy: .whitespacesAndNewlines).first ?? ""
    }

    // MARK: - Decoder

    static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try decodeScriptJSON(type, from: json, makeError: NotesBridgeError.decodingFailed)
    }
}
