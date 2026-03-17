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

    public struct Open: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "open",
            abstract: "Open a URL in the browser and return page info."
        )

        @Argument(help: "URL to open.")
        public var url: String

        @Option(name: .long, help: "Browser session directory (default: ~/.local/share/pippin/browser-session).")
        public var sessionDir: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            let info = try BrowserBridge.open(url: url, sessionDir: sessionDir)
            if output.isJSON {
                try printJSON(info)
            } else if output.isAgent {
                try printAgentJSON(info)
            } else {
                print("URL:   \(info.url)")
                print("Title: \(info.title)")
                if let status = info.status {
                    print("Status: \(status)")
                }
            }
        }
    }

    // MARK: - Snapshot

    public struct Snapshot: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "snapshot",
            abstract: "Take an accessibility snapshot of the current page."
        )

        @Option(name: .long, help: "Browser session directory (default: ~/.local/share/pippin/browser-session).")
        public var sessionDir: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            let result = try BrowserBridge.snapshot(sessionDir: sessionDir)
            if output.isJSON {
                try printJSON(result)
            } else if output.isAgent {
                try printAgentJSON(result)
            } else {
                print("URL:   \(result.url)")
                print("Title: \(result.title)")
                print("")
                printTree(result.snapshot, indent: 0)
            }
        }

        private func printTree(_ elements: [ElementRef], indent: Int) {
            let prefix = String(repeating: "  ", count: indent)
            for element in elements {
                let refPart = element.ref.isEmpty ? "" : " \(element.ref)"
                let namePart = element.name.map { " \"\($0)\"" } ?? ""
                let valuePart = element.value.map { " = \($0)" } ?? ""
                print("\(prefix)[\(element.role)]\(refPart)\(namePart)\(valuePart)")
                if !element.children.isEmpty {
                    printTree(element.children, indent: indent + 1)
                }
            }
        }
    }

    // MARK: - Screenshot

    public struct Screenshot: AsyncParsableCommand {
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

        public mutating func run() async throws {
            let savedPath = try BrowserBridge.screenshot(outputPath: file, sessionDir: sessionDir)
            let result = BrowserActionResult(success: true, action: "screenshot", details: ["path": savedPath])
            if output.isJSON {
                try printJSON(result)
            } else if output.isAgent {
                try printAgentJSON(result)
            } else {
                print("Screenshot saved to: \(savedPath)")
            }
        }
    }

    // MARK: - Click

    public struct Click: AsyncParsableCommand {
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

        public mutating func run() async throws {
            _ = try BrowserBridge.click(ref: ref, sessionDir: sessionDir)
            let result = BrowserActionResult(success: true, action: "click", details: ["ref": ref])
            if output.isJSON {
                try printJSON(result)
            } else if output.isAgent {
                try printAgentJSON(result)
            } else {
                print("Clicked \(ref)")
            }
        }
    }

    // MARK: - Fill

    public struct Fill: AsyncParsableCommand {
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

        public mutating func run() async throws {
            _ = try BrowserBridge.fill(ref: ref, value: value, sessionDir: sessionDir)
            let result = BrowserActionResult(success: true, action: "fill", details: ["ref": ref])
            if output.isJSON {
                try printJSON(result)
            } else if output.isAgent {
                try printAgentJSON(result)
            } else {
                print("Filled \(ref)")
            }
        }
    }

    // MARK: - Scroll

    public struct Scroll: AsyncParsableCommand {
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

        public mutating func run() async throws {
            let validDirections = ["up", "down", "left", "right"]
            guard validDirections.contains(direction.lowercased()) else {
                throw BrowserCommandError(
                    message: "Invalid direction '\(direction)'. Must be one of: up, down, left, right."
                )
            }
            _ = try BrowserBridge.scroll(direction: direction.lowercased(), sessionDir: sessionDir)
            let result = BrowserActionResult(success: true, action: "scroll", details: ["direction": direction.lowercased()])
            if output.isJSON {
                try printJSON(result)
            } else if output.isAgent {
                try printAgentJSON(result)
            } else {
                print("Scrolled \(direction)")
            }
        }
    }

    // MARK: - Tabs

    public struct Tabs: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "tabs",
            abstract: "List all open browser tabs."
        )

        @Option(name: .long, help: "Browser session directory (default: ~/.local/share/pippin/browser-session).")
        public var sessionDir: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            let tabs = try BrowserBridge.tabs(sessionDir: sessionDir)
            if output.isJSON {
                try printJSON(tabs)
            } else if output.isAgent {
                try printAgentJSON(tabs)
            } else {
                if tabs.isEmpty {
                    print("No open tabs.")
                    return
                }
                let activeMarker = "*"
                let inactiveMarker = " "
                for tab in tabs {
                    let marker = tab.isActive ? activeMarker : inactiveMarker
                    print("\(marker) [\(tab.index)] \(tab.title)  \(tab.url)")
                }
            }
        }
    }

    // MARK: - Close

    public struct Close: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "close",
            abstract: "Close the current browser session."
        )

        @Option(name: .long, help: "Browser session directory (default: ~/.local/share/pippin/browser-session).")
        public var sessionDir: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            try BrowserBridge.close(sessionDir: sessionDir)
            let result = BrowserActionResult(success: true, action: "close")
            if output.isJSON {
                try printJSON(result)
            } else if output.isAgent {
                try printAgentJSON(result)
            } else {
                print("Browser session closed.")
            }
        }
    }

    // MARK: - Fetch

    public struct Fetch: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "fetch",
            abstract: "Fetch a URL via HTTP (no browser required)."
        )

        @Argument(help: "URL to fetch.")
        public var url: String

        public init() {}

        public mutating func run() async throws {
            let content = try BrowserBridge.fetch(url: url)
            print(content)
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
