@testable import PippinLib
import XCTest

/// `mail apply-rules` actuation loop under a time budget (RC-12).
final class RuleApplyBudgetTests: XCTestCase {
    private func matches(_ count: Int) -> [RuleMatch] {
        let rule = TriageRule(
            id: "r1", name: "Archive bulk",
            conditions: [RuleCondition(field: .sender, matchOperator: .contains, value: "bulk@example.com")],
            conditionOperator: .and,
            action: RuleAction(moveTo: "Archive", markRead: true),
            enabled: true
        )
        return (1 ... count).map { index in
            RuleMatch(
                message: MailMessage(
                    id: "acc||INBOX||\(index)", account: "acc", mailbox: "INBOX", subject: "Hello",
                    from: "bulk@example.com", to: ["me@example.com"], date: "2026-01-01T12:00:00Z", read: true
                ),
                rule: rule
            )
        }
    }

    func testStopsAtTheBudgetAndReportsEveryMessage() {
        var moved: [String] = []
        let run = MailApplyRules.actuate(
            matches(4), live: true, budget: BatchBudget(softTimeoutMs: 20),
            mark: { _, _ in },
            move: { id, _ in
                moved.append(id)
                if moved.count == 2 { Thread.sleep(forTimeInterval: 0.06) }
            }
        )
        XCTAssertEqual(moved, ["acc||INBOX||1", "acc||INBOX||2"], "nothing may be actuated after the budget is spent")
        XCTAssertEqual(run.applied, 2)
        XCTAssertEqual(run.failed, 0)
        XCTAssertEqual(run.notAttempted, 2)
        XCTAssertEqual(run.actions.map(\.applied), [true, true, false, false])
        XCTAssertEqual(
            run.actions.map(\.error),
            [nil, nil, MailApplyRules.notAttemptedNote, MailApplyRules.notAttemptedNote]
        )
    }

    func testUnlimitedBudgetAppliesEverythingAndKeepsGoingPastAFailure() {
        struct Boom: Error {}
        var marked = 0
        let run = MailApplyRules.actuate(
            matches(3), live: true, budget: BatchBudget(softTimeoutMs: 0),
            mark: { id, _ in
                marked += 1
                if id.hasSuffix("||2") { throw Boom() }
            },
            move: { _, _ in }
        )
        XCTAssertEqual(marked, 3)
        XCTAssertEqual(run.applied, 2)
        XCTAssertEqual(run.failed, 1)
        XCTAssertEqual(run.notAttempted, 0)
    }

    func testDryRunTouchesNothingEvenWithASpentBudget() {
        let spent = BatchBudget(softTimeoutMs: 1)
        Thread.sleep(forTimeInterval: 0.01)
        let run = MailApplyRules.actuate(
            matches(2), live: false, budget: spent,
            mark: { _, _ in XCTFail("dry run must not mark") },
            move: { _, _ in XCTFail("dry run must not move") }
        )
        XCTAssertEqual(run.actions.count, 2)
        XCTAssertEqual(run.notAttempted, 0)
        XCTAssertEqual(run.actions.compactMap(\.error), [])
    }
}
