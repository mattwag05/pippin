---
name: mail-bridge-scaffold
description: Scaffold a new MailBridge method, ArgumentParser subcommand struct, and JSON output model for a new `pippin mail` subcommand. Invoke when adding any new mail subcommand.
---

Given the subcommand name and description provided by the user, generate three coordinated pieces of code:

## 1. ArgumentParser Subcommand Struct

Target file: `pippin/Commands/MailCommands.swift` (create if it doesn't exist)

```swift
struct <Name>Command: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "<name>",
        abstract: "<one-line description>"
    )

    // Options/flags appropriate to this subcommand:
    // Read ops: --account, --mailbox, --limit, --unread
    // Write ops: always include --dry-run: Bool = false

    mutating func run() throws {
        let result = try MailBridge.<methodName>(/* args */)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        print(String(data: data, encoding: .utf8)!)
    }
}
```

Register in the top-level `Pippin` command's `subcommands` array.

## 2. MailBridge Method

Target file: `pippin/MailBridge/MailBridge.swift` (create if it doesn't exist)

Rules:
- Use `Process` to shell out to `/usr/bin/osascript` — never use `NSAppleScript` (not headless-safe)
- All AppleScript source is a String literal passed via `-e` flag or via a temp file
- No user-provided strings interpolated into AppleScript — validate inputs against allowlist first
- Capture both stdout and stderr from the Process; treat non-empty stderr as a soft error
- Return typed Swift structs, not raw strings
- Write operations: check `isDryRun` flag and return early with a description if true
- Wrap osascript call in a `DispatchSemaphore` + 10-second timeout to prevent launchd hangs

```swift
static func <methodName>(<params>) throws -> [MailMessage] {
    let script = """
        tell application "Mail"
            -- minimal AppleScript here
            -- use try/on error blocks
            -- return delimited string, not AppleScript record
        end tell
        """
    // Process setup, run, parse output
}
```

## 3. Output Model

Target file: `pippin/Models/MailModels.swift` (create if it doesn't exist)

Base schema (all read subcommands):
```swift
struct MailMessage: Codable {
    let id: String
    let account: String
    let mailbox: String
    let subject: String
    let from: String
    let to: [String]
    let date: Date
    let read: Bool
    var body: String?  // only populated by `read` subcommand
}
```

For new subcommands that don't return messages (e.g., `accounts`, `move`, `mark`), define an appropriate minimal struct.

## Safety Checklist Before Outputting

- [ ] No user-provided strings interpolated raw into AppleScript
- [ ] No `activate`, `open`, or GUI commands in AppleScript
- [ ] `--dry-run` flag present on all write operations
- [ ] `Process` call has timeout
- [ ] Errors go to stderr, stdout is always valid JSON or empty

## After Generating

Remind the user to invoke the `applescript-security-reviewer` agent on the new MailBridge method before running it.
