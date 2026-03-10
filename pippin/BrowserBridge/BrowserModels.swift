import Foundation

// MARK: - Page Info

public struct PageInfo: Codable, Sendable {
    public let url: String
    public let title: String
    public let status: Int? // HTTP status code if available

    public init(url: String, title: String, status: Int? = nil) {
        self.url = url
        self.title = title
        self.status = status
    }
}

// MARK: - Element Reference

public struct ElementRef: Codable, Sendable {
    public let ref: String // "@ref1", "@ref2", etc.
    public let role: String // "button", "link", "textbox", etc.
    public let name: String? // accessible name/label
    public let value: String? // current value (for inputs)
    public let children: [ElementRef] // child elements

    public init(ref: String, role: String, name: String? = nil, value: String? = nil, children: [ElementRef] = []) {
        self.ref = ref
        self.role = role
        self.name = name
        self.value = value
        self.children = children
    }
}

// MARK: - Snapshot Result

public struct SnapshotResult: Codable, Sendable {
    public let url: String
    public let title: String
    public let snapshot: [ElementRef] // top-level elements

    public init(url: String, title: String, snapshot: [ElementRef]) {
        self.url = url
        self.title = title
        self.snapshot = snapshot
    }
}

// MARK: - Tab Info

public struct TabInfo: Codable, Sendable {
    public let index: Int
    public let url: String
    public let title: String
    public let isActive: Bool

    public init(index: Int, url: String, title: String, isActive: Bool) {
        self.index = index
        self.url = url
        self.title = title
        self.isActive = isActive
    }
}

// MARK: - Errors

public enum BrowserBridgeError: LocalizedError, Sendable {
    case nodeNotInstalled // node/npx not found
    case playwrightNotInstalled // npx playwright not found
    case sessionNotActive // no active browser session
    case navigationFailed(String)
    case elementNotFound(String) // ref ID not found
    case actionFailed(String) // click/fill/etc. failed
    case fetchFailed(String) // HTTP fetch failed

    public var errorDescription: String? {
        switch self {
        case .nodeNotInstalled:
            return "Node.js is not installed. Install via Homebrew: brew install node"
        case .playwrightNotInstalled:
            return "Playwright is not installed. Install via npm: npm install -g playwright"
        case .sessionNotActive:
            return "No active browser session. Use 'pippin browser open <url>' to start one."
        case let .navigationFailed(msg):
            return "Browser navigation failed: \(msg)"
        case let .elementNotFound(ref):
            return "Element not found: \(ref)"
        case let .actionFailed(msg):
            return "Browser action failed: \(msg)"
        case let .fetchFailed(msg):
            return "HTTP fetch failed: \(msg)"
        }
    }
}
