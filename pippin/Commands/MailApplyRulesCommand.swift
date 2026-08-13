import ArgumentParser
import Foundation

/// Execute the actuating half of the triage rules file (`moveTo` / `markRead`).
///
/// Deliberately a separate command from `mail triage` rather than a
/// `triage --apply` flag: triage is safe to run casually and must stay that
/// way. Nothing here mutates without `--live`.
public struct MailApplyRules: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "apply-rules",
        abstract: "Apply triage rules' move/mark actions to a mailbox. Previews only unless --live."
    )

    @Option(name: .long, help: "Filter by account name.")
    public var account: String?

    @Option(name: .long, help: "Mailbox to scan (default: INBOX).")
    public var mailbox: String = "INBOX"

    @Option(name: .customLong("scan-limit"), help: "Messages to enumerate from the mailbox (default: 500).")
    public var scanLimit: Int = 500

    @Option(name: .customLong("max-actions"), help: "Cap on messages actuated per run (default: 200). Oldest are acted on first.")
    public var maxActions: Int = 200

    @Option(name: .customLong("min-age-days"), help: "Never touch messages newer than this many days (default: 14).")
    public var minAgeDays: Int = 14

    @Flag(name: .customLong("skip-unread"), help: "Leave unread messages alone.")
    public var skipUnread: Bool = false

    @Flag(name: .long, help: "Actually perform the actions. Without this the plan is printed and nothing changes.")
    public var live: Bool = false

    @Option(name: .long, help: "Path to triage-rules.json (default: ~/.config/pippin/triage-rules.json).")
    public var rulesFile: String?

    @OptionGroup public var output: OutputOptions

    public init() {}

    public mutating func validate() throws {
        if scanLimit < 1 {
            throw ValidationError("--scan-limit must be at least 1")
        }
        if maxActions < 1 {
            throw ValidationError("--max-actions must be at least 1")
        }
        if minAgeDays < 0 {
            throw ValidationError("--min-age-days cannot be negative")
        }
    }

    public mutating func run() async throws {
        let account = self.account
        let mailbox = self.mailbox
        let scanLimit = self.scanLimit
        let maxActions = self.maxActions
        let minAgeDays = self.minAgeDays
        let skipUnread = self.skipUnread
        let live = self.live
        let rulesFile = self.rulesFile

        // listMessages spawns osascript and each move/mark is its own blocking
        // AppleScript round trip; hop off the cooperative pool.
        let (scanOutcome, result) = try await detachBlocking {
            () -> (MailBridge.ListOutcome, RuleApplyResult) in
            let scanOutcome = try MailBridge.listMessages(
                account: account,
                mailbox: mailbox,
                unread: false,
                limit: scanLimit,
                offset: 0
            )
            let messages = scanOutcome.messages
            let rules = TriageRulesEngine.loadRules(path: rulesFile)
            let matches = TriageRulesEngine.actionable(rules: rules, to: messages)

            let plan = RuleApplyPlanner.plan(
                matches: matches,
                now: Date(),
                minAgeDays: minAgeDays,
                skipUnread: skipUnread,
                maxActions: maxActions
            )

            var actions: [RuleApplyAction] = []
            var appliedCount = 0
            var failedCount = 0

            for match in plan.planned {
                let moveTo = match.rule.action.moveTo
                let markRead = match.rule.action.markRead
                var applied = false
                var failure: String?

                if live {
                    var marked = false
                    do {
                        // Mark before move: moving rewrites the message's
                        // mailbox, which invalidates the compound id the mark
                        // would need.
                        if let markRead {
                            _ = try MailBridge.markMessage(compoundId: match.message.id, read: markRead)
                            marked = true
                        }
                        if let moveTo {
                            _ = try MailBridge.moveMessage(compoundId: match.message.id, toMailbox: moveTo)
                        }
                        applied = true
                        appliedCount += 1
                    } catch {
                        // One unreachable message must not abandon the rest of
                        // the run. Say so when the mark landed and only the move
                        // failed — the message is half-actuated, and a rerun
                        // will re-mark an already-marked message.
                        failure = marked
                            ? "marked, but the move failed: \(error.localizedDescription)"
                            : error.localizedDescription
                        failedCount += 1
                    }
                }

                actions.append(RuleApplyAction(
                    messageId: match.message.id,
                    subject: match.message.subject,
                    from: match.message.from,
                    date: match.message.date,
                    rule: match.rule.name,
                    moveTo: moveTo,
                    markRead: markRead,
                    applied: applied,
                    error: failure
                ))
            }

            let result = RuleApplyResult(
                dryRun: !live,
                scanned: messages.count,
                matched: matches.count,
                planned: actions.count,
                applied: appliedCount,
                failed: failedCount,
                heldTooNew: plan.heldTooNew,
                heldUnread: plan.heldUnread,
                heldOverCap: plan.heldOverCap,
                bySender: MailApplyRules.groupBySender(actions)
            )
            return (scanOutcome, result)
        }

        try output.emit(
            result,
            timedOut: scanOutcome.timedOut,
            timedOutHint: "mailbox scan timed out — some matching messages were not seen this run",
            extraWarnings: scanOutcome.fastPathNote.map { [$0] } ?? []
        ) {
            renderText(result)
        }
    }

    // MARK: - Private

    /// Sender groups, largest first — an unexpectedly large group is the
    /// signal that a rule is over-broad.
    private static func groupBySender(_ actions: [RuleApplyAction]) -> [RuleApplySenderGroup] {
        Dictionary(grouping: actions, by: \.from)
            .map { RuleApplySenderGroup(sender: $0.key, count: $0.value.count, actions: $0.value) }
            .sorted { $0.count == $1.count ? $0.sender < $1.sender : $0.count > $1.count }
    }

    private func renderText(_ result: RuleApplyResult) {
        if result.planned == 0 {
            // "Nothing matched" and "everything matched was held by a guard"
            // are very different answers — don't collapse them.
            print(result.matched == 0
                ? "No messages matched an actuating rule."
                : "\(result.matched) message(s) matched, but none were eligible this run.")
            printCounts(result)
            return
        }

        print(result.dryRun
            ? "PLAN — dry run, nothing was changed. Re-run with --live to apply."
            : "APPLIED — \(result.applied) message(s) actuated.")
        print("")

        for group in result.bySender {
            // A sender can match different rules on different messages, so
            // summarize every distinct action rather than assuming the first.
            let targets = Set(group.actions.map(describeAction)).sorted().joined(separator: " / ")
            let rules = Set(group.actions.map(\.rule)).sorted().joined(separator: ", ")
            print("  \(group.sender)  (\(group.count))  \(targets)  [\(rules)]")
            for action in group.actions.prefix(3) {
                let failed = action.error.map { " — FAILED: \($0)" } ?? ""
                print("      \(action.date.prefix(10))  \(TextFormatter.truncate(action.subject, to: 60))\(failed)")
            }
            if group.count > 3 {
                print("      … and \(group.count - 3) more")
            }
        }

        print("")
        printCounts(result)
    }

    private func printCounts(_ result: RuleApplyResult) {
        var held: [String] = []
        if result.heldTooNew > 0 { held.append("\(result.heldTooNew) newer than \(minAgeDays)d") }
        if result.heldUnread > 0 { held.append("\(result.heldUnread) unread") }
        if result.heldOverCap > 0 { held.append("\(result.heldOverCap) over the \(maxActions) cap") }
        let heldText = held.isEmpty ? "" : " · held: \(held.joined(separator: ", "))"
        print("Scanned \(result.scanned) · matched \(result.matched) · planned \(result.planned)\(heldText)")
        if result.failed > 0 {
            print("\(result.failed) action(s) failed — see the per-message lines above.")
        }
    }

    private func describeAction(_ action: RuleApplyAction) -> String {
        var parts: [String] = []
        if let moveTo = action.moveTo { parts.append("→ \(moveTo)") }
        if let markRead = action.markRead { parts.append(markRead ? "mark read" : "mark unread") }
        return parts.joined(separator: " + ")
    }
}
