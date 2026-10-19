@testable import PippinLib
import XCTest

/// Runs the real Playwright readiness probe scripts through the browser
/// runtime's Node path (pippin-eru6). The pure classifier tests cannot see a
/// broken probe script; these do. A fake `playwright` package on an explicit
/// NODE_PATH stands in for the real one, so no network, npx, or install runs.
/// Skipped when Node is not installed.
final class PlaywrightProbeTests: XCTestCase {
    private var root: URL!
    private var savedNodePath: String?

    override func setUpWithError() throws {
        try XCTSkipUnless(BrowserBridge.isNodeAvailable(), "Node.js is not installed")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pippin-playwright-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        savedNodePath = ProcessInfo.processInfo.environment["NODE_PATH"]
    }

    override func tearDownWithError() throws {
        if let savedNodePath {
            setenv("NODE_PATH", savedNodePath, 1)
        } else {
            unsetenv("NODE_PATH")
        }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// Point NODE_PATH at a module directory. The runtime keeps an explicit
    /// NODE_PATH instead of adding the global npm directories.
    private func useNodePath(_ dir: URL) {
        setenv("NODE_PATH", dir.path, 1)
    }

    /// Writes `<root>/modules/playwright` whose WebKit executable path is
    /// `executablePath`, and returns the modules directory.
    private func installFakePlaywright(executablePath: String) throws -> URL {
        let modules = root.appendingPathComponent("modules")
        let package = modules.appendingPathComponent("playwright")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try #"{"name":"playwright","main":"index.js"}"#
            .write(to: package.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "module.exports = { webkit: { executablePath: () => \(String(reflecting: executablePath)) } };"
            .write(to: package.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        return modules
    }

    func testReadyWhenModuleResolvesAndWebKitExists() throws {
        let webkit = root.appendingPathComponent("fake-webkit")
        try "".write(to: webkit, atomically: true, encoding: .utf8)
        try useNodePath(installFakePlaywright(executablePath: webkit.path))

        XCTAssertEqual(BrowserBridge.playwrightReadiness(), .ready)
    }

    func testBrowserMissingWhenWebKitExecutableIsAbsent() throws {
        try useNodePath(installFakePlaywright(executablePath: root.appendingPathComponent("no-such-webkit").path))

        XCTAssertEqual(BrowserBridge.playwrightReadiness(), .browserMissing)
    }

    func testModuleMissingWhenPlaywrightDoesNotResolve() throws {
        let empty = root.appendingPathComponent("empty-modules")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        useNodePath(empty)

        XCTAssertEqual(BrowserBridge.playwrightReadiness(), .moduleMissing)
    }

    func testProbeFailsWhenTheModuleThrowsOnLoad() throws {
        // The browser runtime calls require('playwright'), so a package that
        // resolves but throws on load is broken, not "browser missing".
        let modules = try installFakePlaywright(executablePath: "/unused")
        try "throw new Error('broken install');"
            .write(to: modules.appendingPathComponent("playwright/index.js"), atomically: true, encoding: .utf8)
        useNodePath(modules)

        guard case let .probeFailed(reason) = BrowserBridge.playwrightReadiness() else {
            return XCTFail("expected probeFailed, got \(BrowserBridge.playwrightReadiness())")
        }
        XCTAssertTrue(reason.hasPrefix("module probe"), reason)
    }
}
