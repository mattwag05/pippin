import ArgumentParser
import Foundation

/// Execute the actuating half of the triage rules file (`moveTo` / `markRead`).
///
/// Deliberately a separate command from `mail triage` rather than a
/// `triage --apply` flag: triage is safe to run casually and must stay that
/// way. Nothing here mutates without `--live`.
public struct MailApplyRules: AgentCommand {
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

    public mutating func execute() async throws -> AgentResult {
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
        // Started before the scan so the whole command fits the MCP child cap.
        let budget = BatchBudget.forCurrentContext()
        let (scanOutcome, result, notAttempted) = try await detachBlocking {
            () -> (MailBridge.ListOutcome, RuleApplyResult, Int) in
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

            let run = MailApplyRules.actuate(
                plan.planned, live: live, budget: budget,
                mark: { _ = try MailBridge.markMessage(compoundId: $0, read: $1) },
                move: { _ = try MailBridge.moveMessage(compoundId: $0, toMailbox: $1) }
            )
            let actions = run.actions

            let result = RuleApplyResult(
                dryRun: !live,
                scanned: messages.count,
                matched: matches.count,
                planned: actions.count,
                applied: run.applied,
                failed: run.failed,
                heldTooNew: plan.heldTooNew,
                heldUnread: plan.heldUnread,
                heldOverCap: plan.heldOverCap,
                bySender: MailApplyRules.groupBySender(actions)
            )
            return (scanOutcome, result, run.notAttempted)
        }

        var warnings: [String] = []
        if scanOutcome.timedOut {
            warnings.append("mailbox scan timed out — some matching messages were not seen this run")
        }
        if notAttempted > 0 {
            warnings.append(
                "stopped at the time budget: \(notAttempted) planned message(s) were not attempted and are listed with applied: false. Run again to continue."
            )
        }
        warnings += scanOutcome.fastPathNote.map { [$0] } ?? []
        return AgentResult(
            result, warnings: warnings.isEmpty ? nil : warnings,
            partial: scanOutcome.timedOut || notAttempted > 0
        )
    }

    static let notAttemptedNote = "not attempted: the run stopped at its time budget"

    /// Apply each planned match in order, stopping once `budget` is spent so a
    /// long run under MCP answers with its per-message report instead of being
    /// killed mid-loop. Messages past the stop are reported, not counted as failed.
    static func actuate(
        _ planned: [RuleMatch],
        live: Bool,
        budget: BatchBudget,
        mark: (_ compoundId: String, _ read: Bool) throws -> Void,
        move: (_ compoundId: String, _ toMailbox: String) throws -> Void
    ) -> (actions: [RuleApplyAction], applied: Int, failed: Int, notAttempted: Int) {
        var actions: [RuleApplyAction] = []
        var appliedCount = 0
        var failedCount = 0
        var notAttempted = 0

        for match in planned {
            let moveTo = match.rule.action.moveTo
            let markRead = match.rule.action.markRead
            var applied = false
            var failure: String?

            if live, budget.exceeded {
                failure = notAttemptedNote
                notAttempted += 1
            } else if live {
                var marked = false
                do {
                    // Mark before move: moving rewrites the message's
                    // mailbox, which invalidates the compound id the mark
                    // would need.
                    if let markRead {
                        try mark(match.message.id, markRead)
                        marked = true
                    }
                    if let moveTo {
                        try move(match.message.id, moveTo)
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
                operationalDate: match.message.operationalDate,
                rule: match.rule.name,
                moveTo: moveTo,
                markRead: markRead,
                applied: applied,
                error: failure
            ))
        }
        return (actions, appliedCount, failedCount, notAttempted)
    }

    // MARK: - Private

    /// Sender groups, largest first — an unexpectedly large group is the
    /// signal that a rule is over-broad.
    private static func groupBySender(_ actions: [RuleApplyAction]) -> [RuleApplySenderGroup] {
        Dictionary(grouping: actions, by: \.from)
            .map { RuleApplySenderGroup(sender: $0.key, count: $0.value.count, actions: $0.value) }
            .sorted { $0.count == $1.count ? $0.sender < $1.sender : $0.count > $1.count }
    }
}
