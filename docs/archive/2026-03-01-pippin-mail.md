# Pippin Mail CLI — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build `pippin mail list` and `pippin mail read` subcommands that output structured JSON from Apple Mail via a headless-safe JXA bridge, plus install the foundation macOS CLI toolkit.

**Architecture:** A Swift CLI using ArgumentParser dispatches `mail list` and `mail read` to a `MailBridge` module that shells out to `/usr/bin/osascript -l JavaScript` (JXA). JXA returns JSON directly, bypassing the fragile AppleScript string-parsing pipeline. Swift decodes, validates, and re-emits the result on stdout.

**Tech Stack:** Swift 5.9+, swift-argument-parser 1.5+, JXA (JavaScript for Automation), osascript, Package.swift, xcodebuild

---

## Message ID Format

The `id` field in all output uses the compound format `account||mailbox||messageId` where `messageId` is the Mail.app integer id. Consumers (including `read`) must pass this exact string back.

## JXA vs AppleScript

We use JXA (`osascript -l JavaScript`) instead of AppleScript because:
- JXA `Date.toISOString()` gives reliable ISO 8601 dates with no locale issues
- JXA can `JSON.stringify()` results directly — no tab-delimited parsing in Swift
- Same TCC permissions as AppleScript

## JXA Performance Pattern

Use batch property access to avoid per-message bridge calls:
```javascript
const filtered = mb.messages.whose({readStatus: false});
const ids = filtered.id();          // one bridge call for all ids
const subjects = filtered.subject(); // one bridge call for all subjects
// ...zip together in JS
```

---

## Task 1: Add .gitignore

**Files:**
- Create: `.gitignore`

**Step 1: Create the file**

```
# Xcode
*.xcuserstate
xcuserdata/
DerivedData/
*.moved-aside
*.pbxuser
!default.pbxuser
*.mode1v3
!default.mode1v3
*.mode2v3
!default.mode2v3
*.perspectivev3
!default.perspectivev3

# Swift Package Manager
.build/
.swiftpm/

# macOS
.DS_Store
.AppleDouble
.LSOverride

# Editor
.idea/
*.swp
*~
```

**Step 2: Stage and commit**

```bash
cd /Users/matthewwagner/Projects/pippin
git add .gitignore docs/
git commit -m "Add .gitignore and docs directory"
```

---

## Task 2: Install Foundation CLI Tools

**Step 1: Install brew taps and packages**

```bash
# Taps first
brew tap keith/formulae
brew tap RhetTbull/macnotesapp
brew tap steipete/tap
brew tap mxcl/made

# Core Apple app CLIs
brew install keith/formulae/reminders-cli
brew install keith/formulae/contacts-cli
brew install steipete/tap/imsg
brew install imessage-exporter
brew install macnotesapp
brew install tag

# File & system utilities
brew install trash duti blueutil mas

# Notifications & scripting
brew install terminal-notifier mxcl/made/swift-sh
```

**Step 2: Install gem and pipx tools**

```bash
gem install icalpal
pipx install osxmetadata
```

**Step 3: Smoke-test each tool**

```bash
# Each should print help or version without crashing
reminders help
contacts help
imsg --help
icalpal --help
mas help
tag --help
trash --help
blueutil --help
```

**Step 4: Grant permissions (manual)**

Open **System Settings → Privacy & Security** and grant:
- **Full Disk Access** → Terminal.app
- **Contacts** → Terminal.app
- **Reminders** → Terminal.app

Then run `reminders show` and `contacts list` interactively once to trigger any remaining prompts.

**Step 5: Commit**

```bash
# Nothing to commit for tools — they install into brew/gem/pipx
# Just note completion
```

---

## Task 3: Add Package.swift with ArgumentParser

The Xcode project skeleton has no `Package.swift`. We add one so `swift build` and xcodebuild both work. The Xcode build hook currently uses `xcodebuild`; after this task we update it to use `swift build`.

**Files:**
- Create: `Package.swift`
- Modify: `.claude/hooks/xcodebuild-check.py` (update build command)

**Step 1: Create Package.swift**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "pippin",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.5.0"
        ),
    ],
    targets: [
        .executableTarget(
            name: "pippin",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "pippin"
        ),
    ]
)
```

**Step 2: Resolve dependencies**

```bash
cd /Users/matthewwagner/Projects/pippin
swift package resolve
```

Expected: Downloads ArgumentParser, creates `.build/` and `Package.resolved`.

**Step 3: Update the xcodebuild hook to use swift build**

Edit `.claude/hooks/xcodebuild-check.py` — replace the `xcodebuild` command with `swift build`:

Find:
```python
cmd = ["xcodebuild", "-scheme", "pippin", "build", "-quiet"]
```

Replace with:
```python
cmd = ["swift", "build"]
```

And update the working directory if needed to the project root.

**Step 4: Verify build passes with Hello World**

```bash
swift build 2>&1
```

Expected: `Build complete!`

**Step 5: Commit**

```bash
git add Package.swift Package.resolved .claude/hooks/xcodebuild-check.py
git commit -m "Add Package.swift with ArgumentParser; switch build hook to swift build"
```

---

## Task 4: Root Command Entry Point

**Files:**
- Modify: `pippin/main.swift`

**Step 1: Replace the Hello World stub**

```swift
import ArgumentParser

@main
struct Pippin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pippin",
        abstract: "macOS CLI toolkit for Apple app automation.",
        subcommands: [MailCommand.self]
    )
}
```

**Step 2: Verify build**

```bash
swift build 2>&1
```

Expected: Compile error about missing `MailCommand` — that's fine, it's our next task.

> Note: The PostToolUse hook will run `swift build` automatically after you save this file. If the error output confuses the hook, it's expected — `MailCommand` isn't defined yet.

**Step 3: Don't commit yet** — wait until `MailCommand` compiles cleanly.

---

## Task 5: Create Output Models

**Files:**
- Create: `pippin/Models/MailModels.swift`

**Step 1: Create the Models directory and file**

```swift
import Foundation

struct MailMessage: Codable {
    let id: String       // compound: "account||mailbox||messageId"
    let account: String
    let mailbox: String
    let subject: String
    let from: String
    let to: [String]
    let date: String     // ISO 8601
    let read: Bool
    let body: String?    // only populated by `read` command
}
```

**Step 2: Note on JSON encoding**

The JSON encoder used in the commands will use default key encoding (camelCase). No custom encoding strategy is needed — all fields are already String/Bool/Array.

---

## Task 6: Create MailBridge

**Files:**
- Create: `pippin/MailBridge/MailBridge.swift`

**Step 1: Create the MailBridge directory and file**

```swift
import Foundation

enum MailBridgeError: LocalizedError {
    case scriptFailed(String)
    case timeout
    case decodingFailed(String)
    case invalidMessageId(String)

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let msg): return "osascript error: \(msg)"
        case .timeout: return "osascript timed out (>10s)"
        case .decodingFailed(let msg): return "JSON decode failed: \(msg)"
        case .invalidMessageId(let id): return "Invalid message id format: \(id)"
        }
    }
}

struct MailBridge {

    // MARK: - Public API

    static func listMessages(
        account: String? = nil,
        mailbox: String = "INBOX",
        unread: Bool = false,
        limit: Int = 50
    ) throws -> [MailMessage] {
        let script = buildListScript(account: account, mailbox: mailbox, unread: unread, limit: limit)
        let json = try runScript(script)
        return try decodeMessages(from: json)
    }

    static func readMessage(compoundId: String) throws -> MailMessage {
        let parts = compoundId.components(separatedBy: "||")
        guard parts.count == 3 else {
            throw MailBridgeError.invalidMessageId(compoundId)
        }
        let (account, mailboxName, msgId) = (parts[0], parts[1], parts[2])
        let script = buildReadScript(account: account, mailbox: mailboxName, messageId: msgId)
        let json = try runScript(script)
        return try decodeMessage(from: json)
    }

    // MARK: - Script Builders

    private static func buildListScript(
        account: String?,
        mailbox: String,
        unread: Bool,
        limit: Int
    ) -> String {
        // Safely embed parameters — escape single quotes in JS strings
        let acctFilter = account.map { "'" + $0.replacingOccurrences(of: "'", with: "\\'") + "'" } ?? "null"
        let mbName = mailbox.replacingOccurrences(of: "'", with: "\\'")

        return """
        var mail = Application('Mail');
        var acctFilter = \(acctFilter);
        var mbFilter = '\(mbName)';
        var unreadOnly = \(unread ? "true" : "false");
        var limit = \(limit);
        var results = [];

        var accounts = mail.accounts();
        for (var a = 0; a < accounts.length && results.length < limit; a++) {
            var acct = accounts[a];
            var acctName = acct.name();
            if (acctFilter !== null && acctName !== acctFilter) continue;

            var mailboxes = acct.mailboxes();
            for (var m = 0; m < mailboxes.length && results.length < limit; m++) {
                var mb = mailboxes[m];
                if (mb.name() !== mbFilter) continue;

                var filter = unreadOnly ? {readStatus: false} : {};
                var msgs = mb.messages.whose(filter)();
                var count = Math.min(msgs.length, limit - results.length);

                // Batch-fetch properties (one bridge call each)
                var ids       = msgs.slice(0, count).map(function(msg) { return msg.id(); });
                var subjects  = msgs.slice(0, count).map(function(msg) { return msg.subject(); });
                var senders   = msgs.slice(0, count).map(function(msg) { return msg.sender(); });
                var dates     = msgs.slice(0, count).map(function(msg) { return msg.dateSent().toISOString(); });
                var readFlags = msgs.slice(0, count).map(function(msg) { return msg.readStatus(); });

                for (var i = 0; i < count; i++) {
                    results.push({
                        id: acctName + '||' + mbFilter + '||' + ids[i],
                        account: acctName,
                        mailbox: mbFilter,
                        subject: subjects[i],
                        from: senders[i],
                        to: [],
                        date: dates[i],
                        read: readFlags[i],
                        body: null
                    });
                }
            }
        }

        JSON.stringify(results);
        """
    }

    private static func buildReadScript(account: String, mailbox: String, messageId: String) -> String {
        let safeAccount = account.replacingOccurrences(of: "'", with: "\\'")
        let safeMailbox = mailbox.replacingOccurrences(of: "'", with: "\\'")
        let safeMsgId = messageId.replacingOccurrences(of: "'", with: "\\'")

        return """
        var mail = Application('Mail');
        var result = null;

        var accounts = mail.accounts();
        for (var a = 0; a < accounts.length; a++) {
            var acct = accounts[a];
            if (acct.name() !== '\(safeAccount)') continue;

            var mailboxes = acct.mailboxes();
            for (var m = 0; m < mailboxes.length; m++) {
                var mb = mailboxes[m];
                if (mb.name() !== '\(safeMailbox)') continue;

                var msgs = mb.messages.whose({id: \(safeMsgId)})();
                if (msgs.length === 0) break;

                var msg = msgs[0];
                result = {
                    id: '\(safeAccount)||\\(safeMailbox)||\(safeMsgId)',
                    account: '\(safeAccount)',
                    mailbox: '\(safeMailbox)',
                    subject: msg.subject(),
                    from: msg.sender(),
                    to: [],
                    date: msg.dateSent().toISOString(),
                    read: msg.readStatus(),
                    body: msg.content()
                };
                break;
            }
            if (result !== null) break;
        }

        if (result === null) { throw new Error('Message not found: \(safeAccount)||\(safeMailbox)||\(safeMsgId)'); }
        JSON.stringify(result);
        """
    }

    // MARK: - Process Runner

    private static func runScript(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // 10-second timeout
        var timedOut = false
        let deadline = DispatchTime.now() + .seconds(10)
        if process.isRunning {
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                if process.isRunning {
                    timedOut = true
                    process.terminate()
                }
            }
        }
        process.waitUntilExit()

        if timedOut { throw MailBridgeError.timeout }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw MailBridgeError.scriptFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Decoders

    private static func decodeMessages(from json: String) throws -> [MailMessage] {
        guard let data = json.data(using: .utf8) else {
            throw MailBridgeError.decodingFailed("Non-UTF8 output")
        }
        do {
            return try JSONDecoder().decode([MailMessage].self, from: data)
        } catch {
            throw MailBridgeError.decodingFailed(error.localizedDescription)
        }
    }

    private static func decodeMessage(from json: String) throws -> MailMessage {
        guard let data = json.data(using: .utf8) else {
            throw MailBridgeError.decodingFailed("Non-UTF8 output")
        }
        do {
            return try JSONDecoder().decode(MailMessage.self, from: data)
        } catch {
            throw MailBridgeError.decodingFailed(error.localizedDescription)
        }
    }
}
```

**Step 2: Invoke security review agents (required)**

After writing this file, invoke:
- `applescript-security-reviewer` agent — checks for injection, privilege creep, error leakage, headless safety
- `headless-compatibility-checker` agent — checks TCC assumptions, Mail launch behavior, blocking ops, timeout handling

Address any NEEDS REVISION or UNSAFE findings before continuing.

---

## Task 7: Create Mail Subcommands

**Files:**
- Create: `pippin/Commands/MailCommand.swift`

**Step 1: Create the Commands directory and file**

```swift
import ArgumentParser
import Foundation

struct MailCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mail",
        abstract: "Interact with Apple Mail.",
        subcommands: [List.self, Read.self]
    )

    // MARK: - list

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List messages. Defaults to INBOX, all messages, limit 50."
        )

        @Option(name: .long, help: "Filter by account name.")
        var account: String?

        @Option(name: .long, help: "Mailbox name (default: INBOX).")
        var mailbox: String = "INBOX"

        @Flag(name: .long, help: "Only show unread messages.")
        var unread: Bool = false

        @Option(name: .long, help: "Maximum number of messages to return.")
        var limit: Int = 50

        mutating func run() async throws {
            let messages = try MailBridge.listMessages(
                account: account,
                mailbox: mailbox,
                unread: unread,
                limit: limit
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(messages)
            print(String(data: data, encoding: .utf8)!)
        }
    }

    // MARK: - read

    struct Read: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "read",
            abstract: "Read a message by its compound id (from `mail list` output)."
        )

        @Argument(help: "Message id from `pippin mail list` output.")
        var messageId: String

        mutating func run() async throws {
            let message = try MailBridge.readMessage(compoundId: messageId)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(message)
            print(String(data: data, encoding: .utf8)!)
        }
    }
}
```

**Step 2: Build**

```bash
swift build 2>&1
```

Expected: `Build complete!`

If there are compile errors, fix them before continuing.

**Step 3: Commit**

```bash
git add pippin/main.swift pippin/Models/ pippin/MailBridge/ pippin/Commands/
git commit -m "feat: implement pippin mail list and read subcommands"
```

---

## Task 8: End-to-End Verification

**Step 1: Find the built binary**

```bash
swift build --show-bin-path
# → .build/debug/pippin
```

**Step 2: Smoke-test help**

```bash
.build/debug/pippin --help
.build/debug/pippin mail --help
.build/debug/pippin mail list --help
.build/debug/pippin mail read --help
```

Expected: ArgumentParser-generated help text for each level.

**Step 3: Live test — list**

Make sure Mail.app has the Automation permission for Terminal (System Settings → Privacy → Automation → Terminal → Mail).

```bash
.build/debug/pippin mail list --unread --limit 5
```

Expected: JSON array of MailMessage objects (may be empty if no unread mail).

If you get `osascript error: Not authorized to send Apple events to Mail.`:
- Open System Settings → Privacy & Security → Automation
- Enable Mail for Terminal.app
- Re-run

**Step 4: Live test — read**

Copy an `id` field from the `list` output (format: `account||INBOX||12345`):

```bash
.build/debug/pippin mail read "account||INBOX||12345"
```

Expected: Single MailMessage JSON with `body` populated.

**Step 5: Run pippin-output-validator skill**

Invoke `/pippin-output-validator` to formally validate JSON schema and performance.

**Step 6: Commit if all checks pass**

```bash
git add -A
git commit -m "feat: verified pippin mail list and read end-to-end"
```

---

## Verification Checklist

- [ ] `swift build` — clean, no warnings
- [ ] `pippin --help` — shows `mail` subcommand
- [ ] `pippin mail list` — returns valid JSON array
- [ ] `pippin mail list --unread --limit 5` — filtered correctly
- [ ] `pippin mail read <id>` — returns JSON with `body` field
- [ ] JSON matches schema: `id, account, mailbox, subject, from, to[], date, read, body?`
- [ ] applescript-security-reviewer: APPROVED
- [ ] headless-compatibility-checker: HEADLESS-SAFE
- [ ] Performance: `list` completes in under 3 seconds
- [ ] No stderr output on success
