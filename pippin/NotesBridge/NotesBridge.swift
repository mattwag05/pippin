import Foundation

enum NotesBridge {
    // MARK: - Public API

    static func listNotes(folder: String? = nil, limit: Int = 50) throws -> [NoteInfo] {
        let clampedLimit = max(1, min(limit, 500))
        let script = buildListScript(folder: folder, limit: clampedLimit)
        let json = try runScript(script)
        return try decode([NoteInfo].self, from: json)
    }

    static func showNote(id: String) throws -> NoteInfo {
        let script = buildShowScript(id: id)
        let json = try runScript(script)
        return try decode(NoteInfo.self, from: json)
    }

    static func searchNotes(query: String, folder: String? = nil, limit: Int = 50) throws -> [NoteInfo] {
        let clampedLimit = max(1, min(limit, 500))
        let script = buildSearchScript(query: query, folder: folder, limit: clampedLimit)
        let json = try runScript(script)
        return try decode([NoteInfo].self, from: json)
    }

    static func listFolders() throws -> [NoteFolder] {
        let script = buildListFoldersScript()
        let json = try runScript(script)
        return try decode([NoteFolder].self, from: json)
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

    // MARK: - JXA Script Builders

    static func buildListScript(folder: String?, limit: Int) -> String {
        let folderFilter = jsEscapeOptional(folder)
        return """
        var app = Application('Notes');
        app.includeStandardAdditions = true;
        var folderFilter = \(folderFilter);
        var limit = \(limit);
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
        var results = sliced.map(function(note) {
            var folderId = '';
            var folderName = '';
            try { folderId = note.container().id(); } catch(e) {}
            try { folderName = note.container().name(); } catch(e) {}
            return {
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
        });
        JSON.stringify(results);
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

    static func buildSearchScript(query: String, folder: String?, limit: Int) -> String {
        let safeQuery = jsEscape(query)
        let folderFilter = jsEscapeOptional(folder)
        return """
        var app = Application('Notes');
        app.includeStandardAdditions = true;
        var query = '\(safeQuery)'.toLowerCase();
        var folderFilter = \(folderFilter);
        var limit = \(limit);
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
        JSON.stringify(results);
        """
    }

    static func buildListFoldersScript() -> String {
        return """
        var app = Application('Notes');
        app.includeStandardAdditions = true;
        var folders = app.folders();
        var results = folders.map(function(f) {
            var count = 0;
            try { count = f.notes().length; } catch(e) {}
            return {
                id: f.id(),
                name: f.name(),
                account: null,
                noteCount: count
            };
        });
        JSON.stringify(results);
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Drain both pipes concurrently to avoid deadlock on large output (>64KB pipe buffer)
        // nonisolated(unsafe): each var is written once by one GCD block; group.wait() provides happens-before
        nonisolated(unsafe) var stdoutData = Data()
        nonisolated(unsafe) var stderrData = Data()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        // Set up timeout: terminate after timeoutSeconds
        let timeoutItem = DispatchWorkItem {
            guard process.isRunning else { return }
            process.terminate() // SIGTERM — give osascript 2 seconds to clean up
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: timeoutItem)

        process.waitUntilExit()
        timeoutItem.cancel()
        group.wait()

        // Detect timeout via termination reason (SIGTERM from our terminate() call)
        if process.terminationReason == .uncaughtSignal {
            throw NotesBridgeError.timeout
        }

        let stdoutStr = (String(data: stdoutData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawStderr = (String(data: stderrData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            throw NotesBridgeError.scriptFailed(rawStderr)
        }

        // osascript can exit 0 and still write errors to stderr (e.g. TCC denial).
        // Filter benign framework log lines (timestamp-prefixed CoreData/NSDateFormatter noise)
        // before treating stderr as a script failure.
        let errorLines = rawStderr
            .components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return false }
                let looksLikeLogLine = trimmed.first?.isNumber == true && trimmed.contains("osascript[")
                return !looksLikeLogLine
            }
        if !errorLines.isEmpty {
            throw NotesBridgeError.scriptFailed(errorLines.joined(separator: "\n"))
        }

        return stdoutStr
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
