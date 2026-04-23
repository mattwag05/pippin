import Foundation

enum NotesBridge {
    // MARK: - Public API

    /// Outcome of a JXA query that walks an unbounded collection (notes,
    /// folders). The `timedOut` flag is set when the script's internal
    /// soft-timeout fires, so callers can surface a "partial results"
    /// advisory to the user. See `MailBridge.SearchOutcome` for the parallel
    /// pattern.
    struct Outcome<T: Decodable>: Decodable {
        let results: T
        let timedOut: Bool

        init(results: T, timedOut: Bool) {
            self.results = results
            self.timedOut = timedOut
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            results = try container.decode(T.self, forKey: .results)
            let meta = try container.decodeIfPresent(Meta.self, forKey: .meta)
            timedOut = meta?.timedOut ?? false
        }

        private enum CodingKeys: String, CodingKey {
            case results, meta
        }

        /// Backward-compatible: legacy scripts that don't emit `timedOut`
        /// default to `false` rather than failing decode.
        private struct Meta: Decodable {
            let timedOut: Bool

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                timedOut = try container.decodeIfPresent(Bool.self, forKey: .timedOut) ?? false
            }

            private enum CodingKeys: String, CodingKey {
                case timedOut
            }
        }
    }

    static func listNotes(folder: String? = nil, limit: Int = 50, softTimeoutMs: Int = 22000) throws -> Outcome<[NoteInfo]> {
        let clampedLimit = max(1, min(limit, 500))
        let script = buildListScript(folder: folder, limit: clampedLimit, softTimeoutMs: softTimeoutMs)
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

    static func createNote(title: String, body: String? = nil, folder: String? = nil) throws -> NoteActionResult {
        let script = buildCreateScript(title: title, body: body, folder: folder)
        let json = try runScript(script, timeoutSeconds: 20)
        return try decode(NoteActionResult.self, from: json)
    }

    static func editNote(id: String, title: String? = nil, body: String? = nil, append: Bool = false) throws -> NoteActionResult {
        let script = buildEditScript(id: id, title: title, body: body, append: append)
        let json = try runScript(script, timeoutSeconds: 20)
        return try decode(NoteActionResult.self, from: json)
    }

    static func deleteNote(id: String) throws -> NoteActionResult {
        let script = buildDeleteScript(id: id)
        let json = try runScript(script, timeoutSeconds: 20)
        return try decode(NoteActionResult.self, from: json)
    }

    // MARK: - JXA Helpers

    static func jsEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\0", with: "\\0")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    static func jsEscapeOptional(_ s: String?) -> String {
        s.map { "'\(jsEscape($0))'" } ?? "null"
    }

    /// Clamp soft-timeout to a sane range. Mirrors `MailBridgeScripts`:
    /// 1s floor (anything lower kills useful work) and 5min ceiling (anything
    /// higher exceeds the MCP `runChild` 60s hard cap anyway, but CLI-direct
    /// callers may want longer).
    static func clampSoftTimeoutMs(_ ms: Int) -> Int {
        max(1000, min(ms, 300_000))
    }

    // MARK: - JXA Script Builders

    static func buildListScript(folder: String?, limit: Int, softTimeoutMs: Int = 22000) -> String {
        let folderFilter = jsEscapeOptional(folder)
        let clampedTimeout = clampSoftTimeoutMs(softTimeoutMs)
        return """
        var app = Application('Notes');
        app.includeStandardAdditions = true;
        var folderFilter = \(folderFilter);
        var limit = \(limit);
        var softTimeoutMs = \(clampedTimeout);
        var _start = Date.now();
        var _meta = { timedOut: false };
        var notes = [];
        if (folderFilter !== null) {
            var folders = app.folders.whose({name: folderFilter})();
            if (folders.length > 0) {
                notes = folders[0].notes();
            }
        } else {
            notes = app.notes();
        }
        // Sort by modificationDate descending (newest first)
        notes = notes.slice().sort(function(a, b) {
            return b.modificationDate() - a.modificationDate();
        });
        var sliced = notes.slice(0, limit);
        var results = [];
        for (var i = 0; i < sliced.length; i++) {
            if (Date.now() - _start > softTimeoutMs) { _meta.timedOut = true; break; }
            var note = sliced[i];
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
                modificationDate: note.modificationDate().toISOString()
            });
        }
        JSON.stringify({results: results, meta: _meta});
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
        let clampedTimeout = clampSoftTimeoutMs(softTimeoutMs)
        return """
        var app = Application('Notes');
        app.includeStandardAdditions = true;
        var query = '\(safeQuery)'.toLowerCase();
        var folderFilter = \(folderFilter);
        var limit = \(limit);
        var softTimeoutMs = \(clampedTimeout);
        var _start = Date.now();
        var _meta = { timedOut: false };
        var notes = [];
        if (folderFilter !== null) {
            var folders = app.folders.whose({name: folderFilter})();
            if (folders.length > 0) {
                notes = folders[0].notes();
            }
        } else {
            notes = app.notes();
        }
        // Sort by modificationDate descending
        notes = notes.slice().sort(function(a, b) {
            return b.modificationDate() - a.modificationDate();
        });
        var results = [];
        for (var i = 0; i < notes.length && results.length < limit; i++) {
            if (Date.now() - _start > softTimeoutMs) { _meta.timedOut = true; break; }
            var note = notes[i];
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
                    modificationDate: note.modificationDate().toISOString()
                });
            }
        }
        JSON.stringify({results: results, meta: _meta});
        """
    }

    static func buildListFoldersScript(softTimeoutMs: Int = 22000) -> String {
        let clampedTimeout = clampSoftTimeoutMs(softTimeoutMs)
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

    private static func runScript(_ script: String, timeoutSeconds: Int = 30) throws -> String {
        do {
            return try ScriptRunner.run(script, timeoutSeconds: timeoutSeconds, appName: "Notes")
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
