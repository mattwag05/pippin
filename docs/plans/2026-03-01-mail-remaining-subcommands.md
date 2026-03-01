# Mail Remaining Subcommands Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement `pippin mail accounts`, `search`, `mark`, `move`, and `send` subcommands, completing the mail CLI defined in `macos-cli-automation-plan.md`.

**Architecture:** Each subcommand follows the established pattern: an `AsyncParsableCommand` struct in `MailCommand.swift` calls a static method on `MailBridge`, which builds a JXA script, runs it via `runScript()`, and decodes the JSON result. Read ops return `[MailMessage]` or `[MailAccount]`; write ops return `MailActionResult`. Two PRs: PR 1 (accounts + search, read-only), PR 2 (mark + move + send, write ops with `--dry-run`).

**Tech Stack:** Swift 5.9+, swift-argument-parser 1.7.0, JXA (JavaScript for Automation), osascript

---

## Background / Key Files

| File | Role |
|------|------|
| `pippin/Commands/MailCommand.swift` | All ArgumentParser subcommand structs — add new ones here |
| `pippin/MailBridge/MailBridge.swift` | All JXA logic — add public methods + script builders here |
| `pippin/Models/MailModels.swift` | Codable output types — add `MailAccount` and `MailActionResult` here |

**Existing utilities to reuse (don't rewrite):**
- `jsEscape()` at `MailBridge.swift:56` — escapes user strings for safe JXA embedding
- `runScript()` at `MailBridge.swift:190` — executes osascript with concurrent pipe drain + 10s timeout
- `decodeMessages()` at `MailBridge.swift:248` — decodes `[MailMessage]` from JSON string
- Compound ID parsing at `MailBridge.swift:42-48` — split on `"||"` into `(account, mailbox, messageId)`
- JXA startup poll loop (8 attempts × 0.5s) — copy from any existing script builder in `MailBridge.swift`
- `JSONEncoder` with `.prettyPrinted, .sortedKeys` — copy from any existing `run()` method

---

## PR 1: `accounts` + `search` (read-only)

**Branch:** `feature/mail-accounts-search`

```bash
cd /Users/matthewwagner/Projects/pippin
git checkout -b feature/mail-accounts-search
```

---

### Task 1: Add `MailAccount` and `MailActionResult` models

**Files:**
- Modify: `pippin/Models/MailModels.swift`

**Step 1: Add models to the end of MailModels.swift**

```swift
struct MailAccount: Codable {
    let name: String
    let email: String
}

struct MailActionResult: Codable {
    let success: Bool
    let action: String
    let details: [String: String]
}
```

**Step 2: Verify build**

```bash
swift build 2>&1
```

Expected: `Build complete!`

**Step 3: Commit**

```bash
cd /Users/matthewwagner/Projects/pippin
git add pippin/Models/MailModels.swift
git commit -m "feat: add MailAccount and MailActionResult models"
```

---

### Task 2: Implement `MailBridge.listAccounts()`

**Files:**
- Modify: `pippin/MailBridge/MailBridge.swift`

**Step 1: Add the public method after `readMessage()` (before the `// MARK: - Script Builders` line)**

```swift
static func listAccounts() throws -> [MailAccount] {
    let script = buildAccountsScript()
    let json = try runScript(script)
    return try decodeAccounts(from: json)
}
```

**Step 2: Add `buildAccountsScript()` after `buildReadScript()`, inside the Script Builders MARK section**

```swift
private static func buildAccountsScript() -> String {
    return """
    var mail = Application('Mail');
    var ready = false;
    for (var attempt = 0; attempt < 8; attempt++) {
        if (mail.accounts().length > 0) { ready = true; break; }
        delay(0.5);
    }
    if (!ready) { throw new Error('Mail not ready: no accounts visible after startup'); }

    var accounts = mail.accounts();
    var results = [];
    for (var a = 0; a < accounts.length; a++) {
        var acct = accounts[a];
        var emails = acct.emailAddresses();
        results.push({
            name: acct.name(),
            email: emails.length > 0 ? emails[0] : ''
        });
    }
    JSON.stringify(results);
    """
}
```

**Step 3: Add `decodeAccounts()` after `decodeMessage()`, inside the Decoders MARK section**

```swift
private static func decodeAccounts(from json: String) throws -> [MailAccount] {
    guard let data = json.data(using: .utf8) else {
        throw MailBridgeError.decodingFailed("Non-UTF8 output")
    }
    do {
        return try JSONDecoder().decode([MailAccount].self, from: data)
    } catch {
        throw MailBridgeError.decodingFailed(error.localizedDescription)
    }
}
```

**Step 4: Verify build**

```bash
swift build 2>&1
```

Expected: `Build complete!`

**Step 5: Invoke security review agents**

Invoke:
- `applescript-security-reviewer` agent — pass the `buildAccountsScript()` method body
- `headless-compatibility-checker` agent

Address any NEEDS REVISION or UNSAFE findings before continuing.

**Step 6: Commit**

```bash
cd /Users/matthewwagner/Projects/pippin
git add pippin/MailBridge/MailBridge.swift
git commit -m "feat: add MailBridge.listAccounts() with JXA accounts script"
```

---

### Task 3: Wire `accounts` subcommand

**Files:**
- Modify: `pippin/Commands/MailCommand.swift`

**Step 1: Add `Accounts` struct before `List` inside `MailCommand`**

```swift
struct Accounts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "accounts",
        abstract: "List configured Mail accounts."
    )

    mutating func run() async throws {
        let accounts = try MailBridge.listAccounts()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(accounts)
        print(String(data: data, encoding: .utf8)!)
    }
}
```

**Step 2: Register in `MailCommand.configuration`**

Change:
```swift
subcommands: [List.self, Read.self]
```
To:
```swift
subcommands: [Accounts.self, List.self, Read.self]
```

**Step 3: Verify build**

```bash
swift build 2>&1
```

Expected: `Build complete!`

**Step 4: Integration test**

```bash
swift run pippin mail accounts 2>&1
```

Expected: JSON array like:
```json
[
  {
    "email": "you@icloud.com",
    "name": "iCloud"
  }
]
```

Validate JSON is well-formed:
```bash
swift run pippin mail accounts 2>/dev/null | python3 -m json.tool
```

Expected: No errors, pretty-printed output.

**Step 5: Commit**

```bash
cd /Users/matthewwagner/Projects/pippin
git add pippin/Commands/MailCommand.swift
git commit -m "feat: add pippin mail accounts subcommand"
```

---

### Task 4: Implement `MailBridge.searchMessages()`

**Files:**
- Modify: `pippin/MailBridge/MailBridge.swift`

**Step 1: Add the public method after `listAccounts()`**

```swift
static func searchMessages(
    query: String,
    account: String? = nil,
    limit: Int = 10
) throws -> [MailMessage] {
    let script = buildSearchScript(query: query, account: account, limit: limit)
    let json = try runScript(script)
    return try decodeMessages(from: json)
}
```

**Step 2: Add `buildSearchScript()` after `buildAccountsScript()`**

The script checks subject and sender first (fast), then falls back to body content (slow). It short-circuits if subject or sender already matches to avoid unnecessary body fetches.

```swift
private static func buildSearchScript(
    query: String,
    account: String?,
    limit: Int
) -> String {
    let safeQuery = jsEscape(query)
    let acctFilter = account.map { "'\(jsEscape($0))'" } ?? "null"

    return """
    var mail = Application('Mail');
    var ready = false;
    for (var attempt = 0; attempt < 8; attempt++) {
        if (mail.accounts().length > 0) { ready = true; break; }
        delay(0.5);
    }
    if (!ready) { throw new Error('Mail not ready: no accounts visible after startup'); }

    var query = '\(safeQuery)'.toLowerCase();
    var acctFilter = \(acctFilter);
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
            var msgs = mb.messages();

            for (var i = 0; i < msgs.length && results.length < limit; i++) {
                var msg = msgs[i];
                var subject = msg.subject() || '';
                var sender = msg.sender() || '';

                // Check subject and sender first (fast, no body fetch needed)
                var matchedFast = subject.toLowerCase().indexOf(query) !== -1
                               || sender.toLowerCase().indexOf(query) !== -1;

                // Only fetch body if subject/sender didn't match
                var matched = matchedFast;
                if (!matched) {
                    var body = msg.content() || '';
                    matched = body.toLowerCase().indexOf(query) !== -1;
                }

                if (matched) {
                    results.push({
                        id: acctName + '||' + mb.name() + '||' + msg.id(),
                        account: acctName,
                        mailbox: mb.name(),
                        subject: subject,
                        from: sender,
                        to: [],
                        date: msg.dateSent().toISOString(),
                        read: msg.readStatus(),
                        body: null
                    });
                }
            }
        }
    }

    JSON.stringify(results);
    """
}
```

**Step 3: Verify build**

```bash
swift build 2>&1
```

Expected: `Build complete!`

**Step 4: Invoke security review agents**

Invoke:
- `applescript-security-reviewer` agent — review `buildSearchScript()`
- `headless-compatibility-checker` agent

Address any findings before continuing.

**Step 5: Commit**

```bash
cd /Users/matthewwagner/Projects/pippin
git add pippin/MailBridge/MailBridge.swift
git commit -m "feat: add MailBridge.searchMessages() with subject/sender/body JXA search"
```

---

### Task 5: Wire `search` subcommand

**Files:**
- Modify: `pippin/Commands/MailCommand.swift`

**Step 1: Add `Search` struct after `Accounts`**

```swift
struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search messages by subject, sender, or body."
    )

    @Argument(help: "Search query (case-insensitive, matches subject/sender/body).")
    var query: String

    @Option(name: .long, help: "Filter by account name.")
    var account: String?

    @Option(name: .long, help: "Maximum number of results to return (default: 10).")
    var limit: Int = 10

    mutating func run() async throws {
        let messages = try MailBridge.searchMessages(
            query: query,
            account: account,
            limit: limit
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(messages)
        print(String(data: data, encoding: .utf8)!)
    }
}
```

**Step 2: Register in `MailCommand.configuration`**

Change:
```swift
subcommands: [Accounts.self, List.self, Read.self]
```
To:
```swift
subcommands: [Accounts.self, Search.self, List.self, Read.self]
```

**Step 3: Verify build**

```bash
swift build 2>&1
```

Expected: `Build complete!`

**Step 4: Integration test**

Use a query string you know appears in your inbox (e.g. a sender name or subject word):

```bash
swift run pippin mail search "test" --limit 3 2>&1
```

Expected: JSON array of `MailMessage` objects matching the query (may be empty if no matches). Validate:

```bash
swift run pippin mail search "test" --limit 3 2>/dev/null | python3 -m json.tool
```

Also verify the `--account` filter works:

```bash
swift run pippin mail search "test" --account "iCloud" --limit 3 2>/dev/null | python3 -m json.tool
```

**Step 5: Invoke `/pippin-output-validator`**

Run the output validator skill on `mail search` to confirm JSON schema.

**Step 6: Commit**

```bash
cd /Users/matthewwagner/Projects/pippin
git add pippin/Commands/MailCommand.swift
git commit -m "feat: add pippin mail search subcommand"
```

---

### Task 6: Push PR 1

**Step 1: Push the branch**

Retrieve Forgejo credentials:
```bash
get-secret "Forgejo Admin Credentials"
```

```bash
cd /Users/matthewwagner/Projects/pippin
git push -u origin feature/mail-accounts-search
```

**Step 2: Create PR via Forgejo API**

```bash
FORGEJO_PASS=$(get-secret "Forgejo Admin Credentials")
curl -s -X POST \
  -u "matthewwagner:${FORGEJO_PASS}" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "feat: pippin mail accounts and search subcommands",
    "body": "Implements `pippin mail accounts` (list configured accounts) and `pippin mail search <query>` (case-insensitive search across subject, sender, and body).\n\n## Subcommands\n- `accounts` — returns `[{name, email}]`\n- `search <query> [--account x] [--limit 10]` — returns `[MailMessage]` (body: null)\n\nBoth are read-only and headless-safe.",
    "head": "feature/mail-accounts-search",
    "base": "main"
  }' \
  "https://forgejo.tail6e035b.ts.net/api/v1/repos/matthewwagner/pippin/pulls" | python3 -m json.tool
```

Expected: JSON response with `"state": "open"` and a PR URL.

**Step 3: Merge PR**

Either merge via the Forgejo web UI at `https://forgejo.tail6e035b.ts.net/matthewwagner/pippin/pulls` or via API:

```bash
PR_NUMBER=<number from above>
curl -s -X POST \
  -u "matthewwagner:${FORGEJO_PASS}" \
  -H "Content-Type: application/json" \
  -d '{"Do": "merge", "merge_message_field": "feat: pippin mail accounts and search subcommands"}' \
  "https://forgejo.tail6e035b.ts.net/api/v1/repos/matthewwagner/pippin/pulls/${PR_NUMBER}/merge"
```

**Step 4: Return to main and pull**

```bash
cd /Users/matthewwagner/Projects/pippin
git checkout main
git pull origin main
```

---

## PR 2: `mark` + `move` + `send` (write operations)

**Branch:** `feature/mail-write-ops`

```bash
cd /Users/matthewwagner/Projects/pippin
git checkout -b feature/mail-write-ops
```

---

### Task 7: Implement `MailBridge.markMessage()`

**Files:**
- Modify: `pippin/MailBridge/MailBridge.swift`

**Step 1: Add public method after `searchMessages()`**

```swift
static func markMessage(
    compoundId: String,
    read: Bool,
    dryRun: Bool = false
) throws -> MailActionResult {
    let parts = compoundId.components(separatedBy: "||")
    guard parts.count == 3 else {
        throw MailBridgeError.invalidMessageId(compoundId)
    }
    let account = parts[0]
    let mailboxName = parts[1]
    let msgId = parts[2]
    guard !msgId.isEmpty, msgId.allSatisfy({ $0.isNumber }) else {
        throw MailBridgeError.invalidMessageId(compoundId)
    }
    let script = buildMarkScript(account: account, mailbox: mailboxName, messageId: msgId, read: read, dryRun: dryRun)
    let json = try runScript(script)
    return try decodeActionResult(from: json)
}
```

**Step 2: Add `buildMarkScript()` after `buildSearchScript()`**

```swift
private static func buildMarkScript(
    account: String,
    mailbox: String,
    messageId: String,
    read: Bool,
    dryRun: Bool
) -> String {
    let safeAccount = jsEscape(account)
    let safeMailbox = jsEscape(mailbox)
    // messageId already validated as numeric by caller

    return """
    var mail = Application('Mail');
    var ready = false;
    for (var attempt = 0; attempt < 8; attempt++) {
        if (mail.accounts().length > 0) { ready = true; break; }
        delay(0.5);
    }
    if (!ready) { throw new Error('Mail not ready: no accounts visible after startup'); }

    var targetRead = \(read ? "true" : "false");
    var dryRun = \(dryRun ? "true" : "false");
    var found = false;

    var accounts = mail.accounts();
    for (var a = 0; a < accounts.length; a++) {
        var acct = accounts[a];
        if (acct.name() !== '\(safeAccount)') continue;

        var mailboxes = acct.mailboxes();
        for (var m = 0; m < mailboxes.length; m++) {
            var mb = mailboxes[m];
            if (mb.name() !== '\(safeMailbox)') continue;

            var msgs = mb.messages.whose({id: \(messageId)})();
            if (msgs.length === 0) throw new Error('Message not found: \(messageId)');

            if (!dryRun) {
                msgs[0].readStatus = targetRead;
            }
            found = true;
            break;
        }
        if (found) break;
    }

    if (!found) { throw new Error('Account or mailbox not found: \(safeAccount)/\(safeMailbox)'); }

    JSON.stringify({
        success: true,
        action: 'mark',
        details: {
            messageId: '\(jsEscape(account))||\(jsEscape(mailbox))||\(messageId)',
            readStatus: String(targetRead),
            dryRun: String(dryRun)
        }
    });
    """
}
```

**Step 3: Add `decodeActionResult()` after `decodeAccounts()`**

```swift
private static func decodeActionResult(from json: String) throws -> MailActionResult {
    guard let data = json.data(using: .utf8) else {
        throw MailBridgeError.decodingFailed("Non-UTF8 output")
    }
    do {
        return try JSONDecoder().decode(MailActionResult.self, from: data)
    } catch {
        throw MailBridgeError.decodingFailed(error.localizedDescription)
    }
}
```

**Step 4: Verify build**

```bash
swift build 2>&1
```

Expected: `Build complete!`

**Step 5: Invoke security review agents**

Invoke:
- `applescript-security-reviewer` agent — review `buildMarkScript()`
- `headless-compatibility-checker` agent

Address all findings before continuing.

**Step 6: Commit**

```bash
cd /Users/matthewwagner/Projects/pippin
git add pippin/MailBridge/MailBridge.swift
git commit -m "feat: add MailBridge.markMessage() and decodeActionResult()"
```

---

### Task 8: Wire `mark` subcommand

**Files:**
- Modify: `pippin/Commands/MailCommand.swift`

**Step 1: Add `Mark` struct after `Read`**

```swift
struct Mark: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mark",
        abstract: "Mark a message as read or unread."
    )

    @Argument(help: "Message id from `pippin mail list` output.")
    var messageId: String

    @Flag(name: .long, help: "Mark as read.")
    var read: Bool = false

    @Flag(name: .long, help: "Mark as unread.")
    var unread: Bool = false

    @Flag(name: .long, help: "Print what would happen without making changes.")
    var dryRun: Bool = false

    mutating func validate() throws {
        guard read != unread else {
            throw ValidationError("Specify exactly one of --read or --unread.")
        }
    }

    mutating func run() async throws {
        let result = try MailBridge.markMessage(
            compoundId: messageId,
            read: read,
            dryRun: dryRun
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        print(String(data: data, encoding: .utf8)!)
    }
}
```

**Step 2: Register in `MailCommand.configuration`**

Change:
```swift
subcommands: [Accounts.self, Search.self, List.self, Read.self]
```
To:
```swift
subcommands: [Accounts.self, Search.self, List.self, Read.self, Mark.self]
```

**Step 3: Verify build**

```bash
swift build 2>&1
```

Expected: `Build complete!`

**Step 4: Integration test with `--dry-run`**

First, get a message ID from list:
```bash
swift run pippin mail list --limit 1 2>/dev/null | python3 -c "import sys,json; msgs=json.load(sys.stdin); print(msgs[0]['id'] if msgs else 'NO MESSAGES')"
```

Then test mark (dry-run):
```bash
MSG_ID="<id from above>"
swift run pippin mail mark "${MSG_ID}" --unread --dry-run 2>/dev/null | python3 -m json.tool
```

Expected:
```json
{
  "action": "mark",
  "details": {
    "dryRun": "true",
    "messageId": "...",
    "readStatus": "false"
  },
  "success": true
}
```

Validate that `--dry-run` did NOT change the actual read status by re-running `list`.

**Step 5: Commit**

```bash
cd /Users/matthewwagner/Projects/pippin
git add pippin/Commands/MailCommand.swift
git commit -m "feat: add pippin mail mark subcommand"
```

---

### Task 9: Implement `MailBridge.moveMessage()`

**Files:**
- Modify: `pippin/MailBridge/MailBridge.swift`

**Step 1: Add public method after `markMessage()`**

```swift
static func moveMessage(
    compoundId: String,
    toMailbox: String,
    dryRun: Bool = false
) throws -> MailActionResult {
    let parts = compoundId.components(separatedBy: "||")
    guard parts.count == 3 else {
        throw MailBridgeError.invalidMessageId(compoundId)
    }
    let account = parts[0]
    let mailboxName = parts[1]
    let msgId = parts[2]
    guard !msgId.isEmpty, msgId.allSatisfy({ $0.isNumber }) else {
        throw MailBridgeError.invalidMessageId(compoundId)
    }
    let script = buildMoveScript(account: account, mailbox: mailboxName, messageId: msgId, toMailbox: toMailbox, dryRun: dryRun)
    let json = try runScript(script)
    return try decodeActionResult(from: json)
}
```

**Step 2: Add `buildMoveScript()` after `buildMarkScript()`**

```swift
private static func buildMoveScript(
    account: String,
    mailbox: String,
    messageId: String,
    toMailbox: String,
    dryRun: Bool
) -> String {
    let safeAccount = jsEscape(account)
    let safeMailbox = jsEscape(mailbox)
    let safeTarget = jsEscape(toMailbox)

    return """
    var mail = Application('Mail');
    var ready = false;
    for (var attempt = 0; attempt < 8; attempt++) {
        if (mail.accounts().length > 0) { ready = true; break; }
        delay(0.5);
    }
    if (!ready) { throw new Error('Mail not ready: no accounts visible after startup'); }

    var dryRun = \(dryRun ? "true" : "false");
    var sourceMsg = null;
    var targetMb = null;

    var accounts = mail.accounts();
    for (var a = 0; a < accounts.length; a++) {
        var acct = accounts[a];
        if (acct.name() !== '\(safeAccount)') continue;

        var mailboxes = acct.mailboxes();
        for (var m = 0; m < mailboxes.length; m++) {
            var mb = mailboxes[m];
            if (mb.name() === '\(safeMailbox)') {
                var msgs = mb.messages.whose({id: \(messageId)})();
                if (msgs.length === 0) throw new Error('Message not found: \(messageId)');
                sourceMsg = msgs[0];
            }
            if (mb.name() === '\(safeTarget)') {
                targetMb = mb;
            }
        }
        break;
    }

    if (sourceMsg === null) { throw new Error('Source message not found'); }
    if (targetMb === null) { throw new Error('Target mailbox not found: \(safeTarget)'); }

    if (!dryRun) {
        mail.move(sourceMsg, {to: targetMb});
    }

    JSON.stringify({
        success: true,
        action: 'move',
        details: {
            messageId: '\(safeAccount)||\(safeMailbox)||\(messageId)',
            from: '\(safeMailbox)',
            to: '\(safeTarget)',
            dryRun: String(dryRun)
        }
    });
    """
}
```

**Step 3: Verify build**

```bash
swift build 2>&1
```

Expected: `Build complete!`

**Step 4: Invoke security review agents**

Invoke:
- `applescript-security-reviewer` agent — review `buildMoveScript()`
- `headless-compatibility-checker` agent

**Step 5: Commit**

```bash
cd /Users/matthewwagner/Projects/pippin
git add pippin/MailBridge/MailBridge.swift
git commit -m "feat: add MailBridge.moveMessage() with JXA mail.move()"
```

---

### Task 10: Wire `move` subcommand

**Files:**
- Modify: `pippin/Commands/MailCommand.swift`

**Step 1: Add `Move` struct after `Mark`**

```swift
struct Move: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Move a message to another mailbox."
    )

    @Argument(help: "Message id from `pippin mail list` output.")
    var messageId: String

    @Option(name: .long, help: "Destination mailbox name.")
    var to: String

    @Flag(name: .long, help: "Print what would happen without making changes.")
    var dryRun: Bool = false

    mutating func run() async throws {
        let result = try MailBridge.moveMessage(
            compoundId: messageId,
            toMailbox: to,
            dryRun: dryRun
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        print(String(data: data, encoding: .utf8)!)
    }
}
```

**Step 2: Register in `MailCommand.configuration`**

```swift
subcommands: [Accounts.self, Search.self, List.self, Read.self, Mark.self, Move.self]
```

**Step 3: Verify build**

```bash
swift build 2>&1
```

Expected: `Build complete!`

**Step 4: Integration test with `--dry-run`**

```bash
MSG_ID="<id from mail list>"
swift run pippin mail move "${MSG_ID}" --to "Archive" --dry-run 2>/dev/null | python3 -m json.tool
```

Expected:
```json
{
  "action": "move",
  "details": {
    "dryRun": "true",
    "from": "INBOX",
    "messageId": "...",
    "to": "Archive"
  },
  "success": true
}
```

**Step 5: Commit**

```bash
cd /Users/matthewwagner/Projects/pippin
git add pippin/Commands/MailCommand.swift
git commit -m "feat: add pippin mail move subcommand"
```

---

### Task 11: Implement `MailBridge.sendMessage()`

**Files:**
- Modify: `pippin/MailBridge/MailBridge.swift`

**Step 1: Add public method after `moveMessage()`**

Note: `runScript()` has a 10-second timeout. Send operations may take longer (SMTP handshake). We pass `timeout: 30` to a new overload. Instead of modifying `runScript()`, we duplicate the logic with a longer timeout for send only.

```swift
static func sendMessage(
    to: String,
    subject: String,
    body: String,
    cc: String? = nil,
    from accountName: String? = nil,
    attachmentPath: String? = nil,
    dryRun: Bool = false
) throws -> MailActionResult {
    let script = buildSendScript(
        to: to,
        subject: subject,
        body: body,
        cc: cc,
        from: accountName,
        attachmentPath: attachmentPath,
        dryRun: dryRun
    )
    let json = try runScriptWithTimeout(script, seconds: 30)
    return try decodeActionResult(from: json)
}
```

**Step 2: Add `runScriptWithTimeout()` — a version of `runScript()` with a configurable timeout — after `runScript()` in the Process Runner MARK section**

```swift
private static func runScriptWithTimeout(_ script: String, seconds: Int) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-l", "JavaScript", "-e", script]

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()

    var stdoutData = Data()
    var stderrData = Data()
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

    let timeoutItem = DispatchWorkItem {
        if process.isRunning {
            process.terminate()
        }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds), execute: timeoutItem)

    process.waitUntilExit()
    timeoutItem.cancel()
    group.wait()

    if process.terminationReason == .uncaughtSignal {
        throw MailBridgeError.timeout
    }

    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
    let stderr = String(data: stderrData, encoding: .utf8) ?? ""

    guard process.terminationStatus == 0 else {
        throw MailBridgeError.scriptFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}
```

**Step 3: Add `buildSendScript()` after `buildMoveScript()`**

```swift
private static func buildSendScript(
    to: String,
    subject: String,
    body: String,
    cc: String?,
    from accountName: String?,
    attachmentPath: String?,
    dryRun: Bool
) -> String {
    let safeTo = jsEscape(to)
    let safeSubject = jsEscape(subject)
    let safeBody = jsEscape(body)
    let safeCc = cc.map { "'\(jsEscape($0))'" } ?? "null"
    let safeFrom = accountName.map { "'\(jsEscape($0))'" } ?? "null"
    let safeAttach = attachmentPath.map { "'\(jsEscape($0))'" } ?? "null"

    return """
    var mail = Application('Mail');
    var ready = false;
    for (var attempt = 0; attempt < 8; attempt++) {
        if (mail.accounts().length > 0) { ready = true; break; }
        delay(0.5);
    }
    if (!ready) { throw new Error('Mail not ready: no accounts visible after startup'); }

    var dryRun = \(dryRun ? "true" : "false");

    var msg = mail.OutgoingMessage({
        subject: '\(safeSubject)',
        content: '\(safeBody)',
        visible: false
    });
    mail.outgoingMessages.push(msg);

    var toRecip = mail.Recipient({address: '\(safeTo)'});
    msg.toRecipients.push(toRecip);

    var ccAddr = \(safeCc);
    if (ccAddr !== null) {
        var ccRecip = mail.CcRecipient({address: ccAddr});
        msg.ccRecipients.push(ccRecip);
    }

    var fromAcct = \(safeFrom);
    if (fromAcct !== null) {
        var accounts = mail.accounts();
        for (var a = 0; a < accounts.length; a++) {
            if (accounts[a].name() === fromAcct) {
                msg.sender = accounts[a].emailAddresses()[0];
                break;
            }
        }
    }

    var attachPath = \(safeAttach);
    if (attachPath !== null) {
        var att = mail.Attachment({fileName: attachPath});
        msg.attachments.push(att);
    }

    if (!dryRun) {
        msg.send();
    }

    JSON.stringify({
        success: true,
        action: 'send',
        details: {
            to: '\(safeTo)',
            subject: '\(safeSubject)',
            dryRun: String(dryRun)
        }
    });
    """
}
```

**Step 4: Verify build**

```bash
swift build 2>&1
```

Expected: `Build complete!`

**Step 5: Invoke security review agents**

Invoke:
- `applescript-security-reviewer` agent — review `buildSendScript()` (highest-risk method)
- `headless-compatibility-checker` agent

Address ALL findings before continuing. `send` is a write operation with external side effects.

**Step 6: Commit**

```bash
cd /Users/matthewwagner/Projects/pippin
git add pippin/MailBridge/MailBridge.swift
git commit -m "feat: add MailBridge.sendMessage() with 30s timeout and JXA OutgoingMessage"
```

---

### Task 12: Wire `send` subcommand

**Files:**
- Modify: `pippin/Commands/MailCommand.swift`

**Step 1: Add `Send` struct after `Move`**

```swift
struct Send: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send an email message."
    )

    @Option(name: .long, help: "Recipient email address.")
    var to: String

    @Option(name: .long, help: "Message subject.")
    var subject: String

    @Option(name: .long, help: "Message body text.")
    var body: String

    @Option(name: .long, help: "CC recipient email address.")
    var cc: String?

    @Option(name: .long, help: "Sending account name (uses Mail default if omitted).")
    var from: String?

    @Option(name: .long, help: "Path to file to attach.")
    var attach: String?

    @Flag(name: .long, help: "Print what would happen without sending.")
    var dryRun: Bool = false

    mutating func validate() throws {
        if let attachPath = attach {
            guard FileManager.default.fileExists(atPath: attachPath) else {
                throw ValidationError("Attachment file not found: \(attachPath)")
            }
        }
    }

    mutating func run() async throws {
        let result = try MailBridge.sendMessage(
            to: to,
            subject: subject,
            body: body,
            cc: cc,
            from: from,
            attachmentPath: attach,
            dryRun: dryRun
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        print(String(data: data, encoding: .utf8)!)
    }
}
```

**Step 2: Register in `MailCommand.configuration`**

```swift
subcommands: [Accounts.self, Search.self, List.self, Read.self, Mark.self, Move.self, Send.self]
```

**Step 3: Verify build**

```bash
swift build 2>&1
```

Expected: `Build complete!`

**Step 4: Integration test with `--dry-run`**

```bash
swift run pippin mail send \
  --to "test@example.com" \
  --subject "Test from pippin" \
  --body "Hello from pippin mail send" \
  --dry-run 2>/dev/null | python3 -m json.tool
```

Expected:
```json
{
  "action": "send",
  "details": {
    "dryRun": "true",
    "subject": "Test from pippin",
    "to": "test@example.com"
  },
  "success": true
}
```

**Step 5: Commit**

```bash
cd /Users/matthewwagner/Projects/pippin
git add pippin/Commands/MailCommand.swift
git commit -m "feat: add pippin mail send subcommand"
```

---

### Task 13: Run `/pippin-output-validator` on all new subcommands

Invoke the `/pippin-output-validator` skill to validate JSON output schemas for all five new subcommands:

- `mail accounts` → `[{"email": string, "name": string}]`
- `mail search` → `[MailMessage]` (same as `mail list`)
- `mail mark` → `{"action": string, "details": {...}, "success": bool}`
- `mail move` → same as mark
- `mail send` → same as mark

Address any schema mismatches before pushing.

---

### Task 14: Push PR 2

**Step 1: Push the branch**

```bash
cd /Users/matthewwagner/Projects/pippin
git push -u origin feature/mail-write-ops
```

**Step 2: Create PR via Forgejo API**

```bash
FORGEJO_PASS=$(get-secret "Forgejo Admin Credentials")
curl -s -X POST \
  -u "matthewwagner:${FORGEJO_PASS}" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "feat: pippin mail mark, move, send subcommands",
    "body": "Implements write subcommands for `pippin mail`:\n\n- `mark <id> --read|--unread [--dry-run]` — toggle read status\n- `move <id> --to <mailbox> [--dry-run]` — move message between mailboxes\n- `send --to <addr> --subject <text> --body <text> [--cc] [--from] [--attach] [--dry-run]` — send email\n\nAll write operations return `MailActionResult` JSON. All include `--dry-run` flag. `send` uses a 30-second timeout to accommodate SMTP handshake.",
    "head": "feature/mail-write-ops",
    "base": "main"
  }' \
  "https://forgejo.tail6e035b.ts.net/api/v1/repos/matthewwagner/pippin/pulls" | python3 -m json.tool
```

**Step 3: Merge and pull**

```bash
PR_NUMBER=<number from above>
curl -s -X POST \
  -u "matthewwagner:${FORGEJO_PASS}" \
  -H "Content-Type: application/json" \
  -d '{"Do": "merge", "merge_message_field": "feat: pippin mail mark, move, send subcommands"}' \
  "https://forgejo.tail6e035b.ts.net/api/v1/repos/matthewwagner/pippin/pulls/${PR_NUMBER}/merge"

git checkout main
git pull origin main
```

---

## Final Verification Checklist

- [ ] `swift build` — clean, no warnings
- [ ] `pippin mail accounts` — returns valid `[{email, name}]` JSON
- [ ] `pippin mail search "query"` — returns `[MailMessage]` matching query
- [ ] `pippin mail search "query" --account "iCloud"` — filtered correctly
- [ ] `pippin mail mark <id> --read --dry-run` — returns MailActionResult, no actual change
- [ ] `pippin mail mark <id> --unread` — actually toggles read status
- [ ] `pippin mail mark <id>` (no flag) — exits with error "Specify exactly one of --read or --unread"
- [ ] `pippin mail move <id> --to "Archive" --dry-run` — returns MailActionResult, message stays
- [ ] `pippin mail send --to x --subject x --body x --dry-run` — returns MailActionResult, nothing sent
- [ ] `pippin mail send --attach /nonexistent --dry-run` — exits with "Attachment file not found"
- [ ] All JSON output validated with `python3 -m json.tool`
- [ ] `applescript-security-reviewer` — APPROVED for all new MailBridge methods
- [ ] `headless-compatibility-checker` — HEADLESS-SAFE for all new MailBridge methods
- [ ] `/pippin-output-validator` — all schemas validated
- [ ] Both PRs merged to main
