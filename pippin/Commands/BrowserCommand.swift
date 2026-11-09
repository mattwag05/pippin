import ArgumentParser
import Foundation

public struct BrowserCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "browser",
        abstract: "Control a headless WebKit browser.",
        subcommands: [
            Open.self, Snapshot.self, Screenshot.self,
            Click.self, Fill.self, Scroll.self,
            Tabs.self, Close.self, Fetch.self,
        ]
    )

    public init() {}

    // MARK: - Open

    public struct Open: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "open",
            abstract: "Open a URL in the browser and return page info."
        )

        @Argument(help: "URL to open.")
        public var url: String

        @Option(name: .long, help: "Browser session directory (default: ~/.local/share/pippin/browser-session).")
        public var sessionDir: String?

        @Option(name: .long, help: "Retry up to N times when --expect-field check fails (default: 0).")
        public var retry: Int = 0

        @Option(name: .long, help: "Dot-path into the payload (e.g. 'title') that must be non-empty for success.")
        public var expectField: String?

        @Option(name: .long, help: "Delay between retry attempts in milliseconds (default: 500).")
        public var retryDelayMs: Int = 500

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let url = self.url
            let sessionDir = self.sessionDir
            let (info, attempts) = try await BrowserRetry.run(
                retry: retry,
                delayMs: retryDelayMs,
                expectField: expectField
            ) {
                try BrowserBridge.open(url: url, sessionDir: sessionDir)
            }
            if retry > 0 {
                return AgentResult(WithAttempts(payload: info, attempts: attempts))
            } else {
                return AgentResult(info)
            }
        }
    }

    // MARK: - Snapshot

    public struct Snapshot: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "snapshot",
            abstract: "Take an accessibility snapshot of the current page."
        )

        @Option(name: .long, help: "Browser session directory (default: ~/.local/share/pippin/browser-session).")
        public var sessionDir: String?

        @Option(name: .long, help: "Retry up to N times when --expect-field check fails (default: 0).")
        public var retry: Int = 0

        @Option(name: .long, help: "Dot-path into the payload (e.g. 'snapshot.0.ref') that must be non-empty for success.")
        public var expectField: String?

        @Option(name: .long, help: "Delay between retry attempts in milliseconds (default: 500).")
        public var retryDelayMs: Int = 500

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let sessionDir = self.sessionDir
            let (result, attempts) = try await BrowserRetry.run(
                retry: retry,
                delayMs: retryDelayMs,
                expectField: expectField
            ) {
                try BrowserBridge.snapshot(sessionDir: sessionDir)
            }
            if retry > 0 {
                return AgentResult(WithAttempts(payload: result, attempts: attempts))
            } else {
                return AgentResult(result)
            }
        }
    }

    // MARK: - Screenshot

    public struct Screenshot: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "screenshot",
            abstract: "Capture a screenshot of the current page."
        )

        @Option(name: .long, help: "Output file path for the screenshot.")
        public var file: String = "screenshot.png"

        @Option(name: .long, help: "Browser session directory (default: ~/.local/share/pippin/browser-session).")
        public var sessionDir: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let file = self.file
            let sessionDir = self.sessionDir
            let savedPath = try await detachBlocking {
                try BrowserBridge.screenshot(outputPath: file, sessionDir: sessionDir)
            }
            let result = BrowserActionResult(success: true, action: "screenshot", details: ["path": savedPath])
            return AgentResult(result)
        }
    }

    // MARK: - Click

    public struct Click: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "click",
            abstract: "Click an element by @ref ID."
        )

        @Argument(help: "Element reference ID (e.g. @ref3).")
        public var ref: String

        @Option(name: .long, help: "Browser session directory (default: ~/.local/share/pippin/browser-session).")
        public var sessionDir: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let ref = self.ref
            let sessionDir = self.sessionDir
            _ = try await detachBlocking {
                try BrowserBridge.click(ref: ref, sessionDir: sessionDir)
            }
            let result = BrowserActionResult(success: true, action: "click", details: ["ref": ref])
            return AgentResult(result)
        }
    }

    // MARK: - Fill

    public struct Fill: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "fill",
            abstract: "Fill an input element by @ref ID."
        )

        @Argument(help: "Element reference ID (e.g. @ref5).")
        public var ref: String

        @Argument(help: "Value to fill into the element.")
        public var value: String

        @Option(name: .long, help: "Browser session directory (default: ~/.local/share/pippin/browser-session).")
        public var sessionDir: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let ref = self.ref
            let value = self.value
            let sessionDir = self.sessionDir
            _ = try await detachBlocking {
                try BrowserBridge.fill(ref: ref, value: value, sessionDir: sessionDir)
            }
            let result = BrowserActionResult(success: true, action: "fill", details: ["ref": ref])
            return AgentResult(result)
        }
    }

    // MARK: - Scroll

    public struct Scroll: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "scroll",
            abstract: "Scroll the page in a direction."
        )

        @Argument(help: "Scroll direction: up, down, left, or right.")
        public var direction: String

        @Option(name: .long, help: "Browser session directory (default: ~/.local/share/pippin/browser-session).")
        public var sessionDir: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let validDirections = ["up", "down", "left", "right"]
            guard validDirections.contains(direction.lowercased()) else {
                throw BrowserCommandError(
                    message: "Invalid direction '\(direction)'. Must be one of: up, down, left, right."
                )
            }
            let lowered = direction.lowercased()
            let sessionDir = self.sessionDir
            _ = try await detachBlocking {
                try BrowserBridge.scroll(direction: lowered, sessionDir: sessionDir)
            }
            let result = BrowserActionResult(success: true, action: "scroll", details: ["direction": lowered])
            return AgentResult(result)
        }
    }

    // MARK: - Tabs

    public struct Tabs: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "tabs",
            abstract: "List all open browser tabs."
        )

        @Option(name: .long, help: "Browser session directory (default: ~/.local/share/pippin/browser-session).")
        public var sessionDir: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let sessionDir = self.sessionDir
            let tabs = try await detachBlocking {
                try BrowserBridge.tabs(sessionDir: sessionDir)
            }
            return AgentResult(tabs)
        }
    }

    // MARK: - Close

    public struct Close: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "close",
            abstract: "Close the current browser session."
        )

        @Option(name: .long, help: "Browser session directory (default: ~/.local/share/pippin/browser-session).")
        public var sessionDir: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let sessionDir = self.sessionDir
            try await detachBlocking {
                try BrowserBridge.close(sessionDir: sessionDir)
            }
            let result = BrowserActionResult(success: true, action: "close")
            return AgentResult(result)
        }
    }

    // MARK: - Fetch

    public struct Fetch: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "fetch",
            abstract: "Fetch a URL via HTTP (no browser required)."
        )

        @Argument(help: "URL to fetch.")
        public var url: String

        @Option(name: .long, help: "Retry up to N times when --expect-field check fails (default: 0).")
        public var retry: Int = 0

        @Option(name: .long, help: "Dot-path into the payload (e.g. 'content') that must be non-empty for success.")
        public var expectField: String?

        @Option(name: .long, help: "Delay between retry attempts in milliseconds (default: 500).")
        public var retryDelayMs: Int = 500

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let url = self.url
            let (result, attempts) = try await BrowserRetry.run(
                retry: retry,
                delayMs: retryDelayMs,
                expectField: expectField
            ) {
                let content = try BrowserBridge.fetch(url: url)
                return FetchResult(url: url, content: content)
            }
            if retry > 0 {
                return AgentResult(WithAttempts(payload: result, attempts: attempts))
            } else {
                return AgentResult(result)
            }
        }
    }
}

// MARK: - BrowserCommandError

private struct BrowserCommandError: LocalizedError {
    let message: String
    var errorDescription: String? {
        message
    }
}

extension BrowserCommandError: RemediableError {
    var agentCode: String {
        "browser_command_error"
    }

    var nextStep: NextStep {
        .none
    }
}
