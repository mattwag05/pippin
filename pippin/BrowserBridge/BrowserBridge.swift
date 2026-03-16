import Foundation

// MARK: - BrowserBridge

public enum BrowserBridge {
    // MARK: - Default Session Directory

    public static var defaultSessionDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".local/share/pippin/browser-session").path
    }

    // MARK: - Availability Checks

    /// Returns true if node is available on PATH.
    public static func isNodeAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["node"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Returns true if playwright package is available via npx.
    public static func isPlaywrightAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["npx", "playwright", "--version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: - Browser Operations

    /// Open a URL in a persistent browser session and return page info.
    public static func open(url: String, sessionDir: String? = nil) throws -> PageInfo {
        guard isNodeAvailable() else { throw BrowserBridgeError.nodeNotInstalled }
        let session = sessionDir ?? defaultSessionDir
        try ensureSessionDir(session)
        let script = buildOpenScript(url: url, sessionDir: session)
        let json = try runNodeScript(script, timeoutSeconds: 30)
        return try decodeJSON(PageInfo.self, from: json)
    }

    /// Take an accessibility snapshot of the current page.
    public static func snapshot(sessionDir: String? = nil) throws -> SnapshotResult {
        guard isNodeAvailable() else { throw BrowserBridgeError.nodeNotInstalled }
        let session = sessionDir ?? defaultSessionDir
        let script = buildSnapshotScript(sessionDir: session)
        let json = try runNodeScript(script, timeoutSeconds: 20)

        // Parse the raw snapshot response which contains url, title, and raw snapshot array
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw BrowserBridgeError.decodingFailed("Failed to parse snapshot response")
        }

        let url = obj["url"] as? String ?? ""
        let title = obj["title"] as? String ?? ""
        let rawSnapshot = obj["snapshot"] as? [[String: Any]] ?? []
        let elements = AccessibilityTree.fromArray(rawSnapshot)

        return SnapshotResult(url: url, title: title, snapshot: elements)
    }

    /// Take a screenshot and save to outputPath. Returns the saved path.
    public static func screenshot(outputPath: String, sessionDir: String? = nil) throws -> String {
        guard isNodeAvailable() else { throw BrowserBridgeError.nodeNotInstalled }
        let session = sessionDir ?? defaultSessionDir
        let script = buildScreenshotScript(outputPath: outputPath, sessionDir: session)
        _ = try runNodeScript(script, timeoutSeconds: 20)
        return outputPath
    }

    /// Click an element by @ref ID.
    public static func click(ref: String, sessionDir: String? = nil) throws -> Bool {
        guard isNodeAvailable() else { throw BrowserBridgeError.nodeNotInstalled }
        let session = sessionDir ?? defaultSessionDir
        let script = buildClickScript(ref: ref, sessionDir: session)
        let json = try runNodeScript(script, timeoutSeconds: 15)
        return try decodeBoolResult(from: json)
    }

    /// Fill an input element by @ref ID with a value.
    public static func fill(ref: String, value: String, sessionDir: String? = nil) throws -> Bool {
        guard isNodeAvailable() else { throw BrowserBridgeError.nodeNotInstalled }
        let session = sessionDir ?? defaultSessionDir
        let script = buildFillScript(ref: ref, value: value, sessionDir: session)
        let json = try runNodeScript(script, timeoutSeconds: 15)
        return try decodeBoolResult(from: json)
    }

    /// Scroll the page in a direction ("up", "down", "left", "right").
    public static func scroll(direction: String, sessionDir: String? = nil) throws -> Bool {
        guard isNodeAvailable() else { throw BrowserBridgeError.nodeNotInstalled }
        let session = sessionDir ?? defaultSessionDir
        let script = buildScrollScript(direction: direction, sessionDir: session)
        let json = try runNodeScript(script, timeoutSeconds: 10)
        return try decodeBoolResult(from: json)
    }

    /// List all open tabs.
    public static func tabs(sessionDir: String? = nil) throws -> [TabInfo] {
        guard isNodeAvailable() else { throw BrowserBridgeError.nodeNotInstalled }
        let session = sessionDir ?? defaultSessionDir
        let script = buildTabsScript(sessionDir: session)
        let json = try runNodeScript(script, timeoutSeconds: 10)
        return try decodeJSON([TabInfo].self, from: json)
    }

    /// Close the browser session.
    public static func close(sessionDir: String? = nil) throws {
        guard isNodeAvailable() else { throw BrowserBridgeError.nodeNotInstalled }
        let session = sessionDir ?? defaultSessionDir
        let script = buildCloseScript(sessionDir: session)
        _ = try runNodeScript(script, timeoutSeconds: 10)
    }

    /// Simple HTTP fetch without a browser — uses URLSession.
    public static func fetch(url: String) throws -> String {
        guard let requestURL = URL(string: url) else {
            throw BrowserBridgeError.fetchFailed("Invalid URL: \(url)")
        }
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<String, Error> = .failure(BrowserBridgeError.fetchFailed("timeout"))
        let task = URLSession.shared.dataTask(with: requestURL) { data, _, error in
            if let error {
                result = .failure(BrowserBridgeError.fetchFailed(error.localizedDescription))
            } else if let data, let str = String(data: data, encoding: .utf8) {
                result = .success(str)
            } else {
                result = .failure(BrowserBridgeError.fetchFailed("No data returned"))
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return try result.get()
    }

    // MARK: - Script Builders

    /// Escape a Swift string for safe embedding inside a JavaScript single-quoted string.
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

    static func buildOpenScript(url: String, sessionDir: String) -> String {
        let safeUrl = jsEscape(url)
        let safeSession = jsEscape(sessionDir)
        return """
        const { webkit } = require('playwright');
        (async () => {
            const browser = await webkit.launchPersistentContext('\(safeSession)', { headless: true });
            const page = browser.pages()[0] || await browser.newPage();
            let status = null;
            page.on('response', resp => { if (resp.url() === page.url()) status = resp.status(); });
            await page.goto('\(safeUrl)', { waitUntil: 'domcontentloaded', timeout: 25000 });
            const title = await page.title();
            const finalUrl = page.url();
            console.log(JSON.stringify({ url: finalUrl, title: title, status: status }));
            await browser.close();
        })().catch(e => { process.stderr.write(e.message + '\\n'); process.exit(1); });
        """
    }

    static func buildSnapshotScript(sessionDir: String) -> String {
        let safeSession = jsEscape(sessionDir)
        return """
        const { webkit } = require('playwright');
        (async () => {
            const browser = await webkit.launchPersistentContext('\(safeSession)', { headless: true });
            const page = browser.pages()[0] || await browser.newPage();
            const title = await page.title();
            const url = page.url();
            const snapshot = await page.accessibility.snapshot({ interestingOnly: false });
            const children = (snapshot && snapshot.children) ? snapshot.children : [];
            console.log(JSON.stringify({ url: url, title: title, snapshot: children }));
            await browser.close();
        })().catch(e => { process.stderr.write(e.message + '\\n'); process.exit(1); });
        """
    }

    static func buildScreenshotScript(outputPath: String, sessionDir: String) -> String {
        let safePath = jsEscape(outputPath)
        let safeSession = jsEscape(sessionDir)
        return """
        const { webkit } = require('playwright');
        (async () => {
            const browser = await webkit.launchPersistentContext('\(safeSession)', { headless: true });
            const page = browser.pages()[0] || await browser.newPage();
            await page.screenshot({ path: '\(safePath)', fullPage: false });
            console.log(JSON.stringify({ saved: '\(safePath)' }));
            await browser.close();
        })().catch(e => { process.stderr.write(e.message + '\\n'); process.exit(1); });
        """
    }

    static func buildClickScript(ref: String, sessionDir: String) -> String {
        let safeRef = jsEscape(ref)
        let safeSession = jsEscape(sessionDir)
        return """
        const { webkit } = require('playwright');
        (async () => {
            const browser = await webkit.launchPersistentContext('\(safeSession)', { headless: true });
            const page = browser.pages()[0] || await browser.newPage();
            // Walk accessibility tree to find element by ref label
            const snapshot = await page.accessibility.snapshot({ interestingOnly: false });
            // Use getByRole + accessible name matching as best-effort approach
            // Since we don't have a direct ref→selector mapping, we enumerate interactive elements
            const locators = await page.locator('[aria-label], button, a, input, select, textarea').all();
            let clicked = false;
            for (let i = 0; i < locators.length; i++) {
                const label = '@ref' + (i + 1);
                if (label === '\(safeRef)') {
                    await locators[i].click({ timeout: 5000 });
                    clicked = true;
                    break;
                }
            }
            if (!clicked) { throw new Error('Element not found: \(safeRef)'); }
            console.log(JSON.stringify({ success: true }));
            await browser.close();
        })().catch(e => { process.stderr.write(e.message + '\\n'); process.exit(1); });
        """
    }

    static func buildFillScript(ref: String, value: String, sessionDir: String) -> String {
        let safeRef = jsEscape(ref)
        let safeValue = jsEscape(value)
        let safeSession = jsEscape(sessionDir)
        return """
        const { webkit } = require('playwright');
        (async () => {
            const browser = await webkit.launchPersistentContext('\(safeSession)', { headless: true });
            const page = browser.pages()[0] || await browser.newPage();
            const locators = await page.locator('input, textarea, [contenteditable]').all();
            let filled = false;
            for (let i = 0; i < locators.length; i++) {
                const label = '@ref' + (i + 1);
                if (label === '\(safeRef)') {
                    await locators[i].fill('\(safeValue)', { timeout: 5000 });
                    filled = true;
                    break;
                }
            }
            if (!filled) { throw new Error('Element not found: \(safeRef)'); }
            console.log(JSON.stringify({ success: true }));
            await browser.close();
        })().catch(e => { process.stderr.write(e.message + '\\n'); process.exit(1); });
        """
    }

    static func buildScrollScript(direction: String, sessionDir: String) -> String {
        let safeDirection = jsEscape(direction)
        let safeSession = jsEscape(sessionDir)
        return """
        const { webkit } = require('playwright');
        (async () => {
            const browser = await webkit.launchPersistentContext('\(safeSession)', { headless: true });
            const page = browser.pages()[0] || await browser.newPage();
            const dir = '\(safeDirection)'.toLowerCase();
            const scrollMap = {
                'down':  [0,  600],
                'up':    [0, -600],
                'right': [600,  0],
                'left':  [-600, 0]
            };
            const delta = scrollMap[dir] || [0, 600];
            await page.mouse.wheel(delta[0], delta[1]);
            console.log(JSON.stringify({ success: true }));
            await browser.close();
        })().catch(e => { process.stderr.write(e.message + '\\n'); process.exit(1); });
        """
    }

    static func buildTabsScript(sessionDir: String) -> String {
        let safeSession = jsEscape(sessionDir)
        return """
        const { webkit } = require('playwright');
        (async () => {
            const browser = await webkit.launchPersistentContext('\(safeSession)', { headless: true });
            const pages = browser.pages();
            const results = [];
            for (let i = 0; i < pages.length; i++) {
                const p = pages[i];
                results.push({
                    index: i,
                    url: p.url(),
                    title: await p.title(),
                    isActive: i === pages.length - 1
                });
            }
            console.log(JSON.stringify(results));
            await browser.close();
        })().catch(e => { process.stderr.write(e.message + '\\n'); process.exit(1); });
        """
    }

    static func buildCloseScript(sessionDir: String) -> String {
        let safeSession = jsEscape(sessionDir)
        return """
        const { webkit } = require('playwright');
        (async () => {
            const browser = await webkit.launchPersistentContext('\(safeSession)', { headless: true });
            await browser.close();
            console.log(JSON.stringify({ success: true }));
        })().catch(e => { process.stderr.write(e.message + '\\n'); process.exit(1); });
        """
    }

    // MARK: - Helpers

    private static func ensureSessionDir(_ path: String) throws {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw BrowserBridgeError.scriptFailed("Cannot create session directory \(path): \(error.localizedDescription)")
        }
    }

    private static func decodeBoolResult(from json: String) throws -> Bool {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw BrowserBridgeError.decodingFailed("Failed to parse action result")
        }
        return obj["success"] as? Bool ?? false
    }

    // MARK: - Node Process Runner

    /// Run an inline Node.js script and return stdout.
    static func runNodeScript(_ script: String, timeoutSeconds: Int = 15) throws -> String {
        // Write the script to a temp file to avoid shell quoting issues
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("pippin-browser-\(UUID().uuidString).js")
        do {
            try script.write(to: tmpFile, atomically: true, encoding: .utf8)
        } catch {
            throw BrowserBridgeError.scriptFailed("Failed to write temp script: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let process = Process()
        // Use env to pick up PATH-installed node
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", tmpFile.path]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw BrowserBridgeError.nodeNotInstalled
        }

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
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: timeoutItem)

        process.waitUntilExit()
        timeoutItem.cancel()
        group.wait()

        // Detect timeout via termination reason
        if process.terminationReason == .uncaughtSignal {
            throw BrowserBridgeError.timeout
        }

        let stdoutStr = (String(data: stdoutData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let stderrStr = (String(data: stderrData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            throw BrowserBridgeError.scriptFailed(stderrStr.isEmpty ? "Node process exited with status \(process.terminationStatus)" : stderrStr)
        }

        return stdoutStr
    }

    // MARK: - JSON Decoder

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        guard !json.isEmpty else {
            throw BrowserBridgeError.decodingFailed("Node script returned empty output")
        }
        guard let data = json.data(using: .utf8) else {
            throw BrowserBridgeError.decodingFailed("Non-UTF8 output from Node script")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw BrowserBridgeError.decodingFailed("JSON decode error: \(error.localizedDescription)")
        }
    }
}
