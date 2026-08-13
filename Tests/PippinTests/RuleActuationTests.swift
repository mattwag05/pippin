@testable import PippinLib
import XCTest

// MARK: - Helpers

private func actuationMessage(
    id: String = "acc||INBOX||1",
    subject: String = "Hello",
    from: String = "bulk@example.com",
    date: String = "2026-01-01T12:00:00Z",
    read: Bool = true
) -> MailMessage {
    MailMessage(
        id: id,
        account: "acc",
        mailbox: "INBOX",
        subject: subject,
        from: from,
        to: ["me@example.com"],
        date: date,
        read: read
    )
}

private func actuationRule(
    id: String = "r1",
    name: String = "Archive bulk",
    value: String = "bulk@example.com",
    action: RuleAction,
    enabled: Bool = true
) -> TriageRule {
    TriageRule(
        id: id,
        name: name,
        conditions: [RuleCondition(field: .sender, matchOperator: .contains, value: value)],
        conditionOperator: .and,
        action: action,
        enabled: enabled
    )
}

private let referenceNow = ISO8601DateFormatter().date(from: "2026-02-01T12:00:00Z")!

// MARK: - RuleAction

final class RuleActionActuationTests: XCTestCase {
    func testClassifyOnlyActionIsNotActuating() {
        XCTAssertFalse(RuleAction(setCategory: .promotional, setUrgency: 1).isActuating)
        XCTAssertFalse(RuleAction(skip: true).isActuating)
        XCTAssertFalse(RuleAction().isActuating)
    }

    func testMoveOrMarkIsActuating() {
        XCTAssertTrue(RuleAction(moveTo: "Archive").isActuating)
        XCTAssertTrue(RuleAction(markRead: true).isActuating)
        XCTAssertTrue(RuleAction(markRead: false).isActuating)
        XCTAssertTrue(RuleAction(setCategory: .promotional, moveTo: "Archive").isActuating)
    }

    /// A rules file written before actuation existed must keep decoding.
    func testDecodesRulesFileWithoutActuationFields() throws {
        let json = """
        { "setCategory": "promotional", "setUrgency": 1 }
        """
        let action = try JSONDecoder().decode(RuleAction.self, from: Data(json.utf8))
        XCTAssertEqual(action.setCategory, .promotional)
        XCTAssertNil(action.moveTo)
        XCTAssertNil(action.markRead)
        XCTAssertFalse(action.isActuating)
    }

    func testDecodesActuationFields() throws {
        let json = """
        { "moveTo": "Archive", "markRead": true }
        """
        let action = try JSONDecoder().decode(RuleAction.self, from: Data(json.utf8))
        XCTAssertEqual(action.moveTo, "Archive")
        XCTAssertEqual(action.markRead, true)
        XCTAssertTrue(action.isActuating)
    }
}

// MARK: - TriageRulesEngine.actionable

final class TriageRulesActionableTests: XCTestCase {
    func testReturnsOnlyActuatingMatches() {
        let actuating = actuationRule(id: "r1", value: "bulk@", action: RuleAction(moveTo: "Archive"))
        let classifyOnly = actuationRule(id: "r2", value: "news@", action: RuleAction(setCategory: .promotional))

        let matches = TriageRulesEngine.actionable(
            rules: [actuating, classifyOnly],
            to: [
                actuationMessage(id: "m1", from: "bulk@example.com"),
                actuationMessage(id: "m2", from: "news@example.com"),
                actuationMessage(id: "m3", from: "human@example.com"),
            ]
        )

        XCTAssertEqual(matches.map(\.message.id), ["m1"])
        XCTAssertEqual(matches[0].rule.name, "Archive bulk")
    }

    /// `skip: true` means "drop this message"; it must never mutate the mailbox
    /// even if someone also puts a `moveTo` on the same rule.
    func testSkipRuleNeverActuates() {
        let rule = actuationRule(action: RuleAction(skip: true, moveTo: "Archive"))
        let matches = TriageRulesEngine.actionable(rules: [rule], to: [actuationMessage()])
        XCTAssertTrue(matches.isEmpty)
    }

    func testDisabledRuleNeverActuates() {
        let rule = actuationRule(action: RuleAction(moveTo: "Archive"), enabled: false)
        let matches = TriageRulesEngine.actionable(rules: [rule], to: [actuationMessage()])
        XCTAssertTrue(matches.isEmpty)
    }

    func testNoRulesYieldsNoActions() {
        XCTAssertTrue(TriageRulesEngine.actionable(rules: [], to: [actuationMessage()]).isEmpty)
    }

    /// Must use the same first-match-wins ordering as `apply`, so a message is
    /// never planned against a rule `apply` would not have chosen.
    func testFirstMatchWinsMatchesApplyOrdering() {
        let first = actuationRule(id: "r1", name: "First", value: "bulk@", action: RuleAction(skip: true))
        let second = actuationRule(id: "r2", name: "Second", value: "bulk@", action: RuleAction(moveTo: "Archive"))

        // The skip rule wins the match, so nothing actuates.
        XCTAssertTrue(TriageRulesEngine.actionable(rules: [first, second], to: [actuationMessage()]).isEmpty)
        // Reversed, the move rule wins.
        XCTAssertEqual(
            TriageRulesEngine.actionable(rules: [second, first], to: [actuationMessage()]).count, 1
        )
    }
}

// MARK: - RuleApplyPlanner guardrails

final class RuleApplyPlannerTests: XCTestCase {
    private func match(id: String, date: String, read: Bool = true) -> RuleMatch {
        RuleMatch(
            message: actuationMessage(id: id, date: date, read: read),
            rule: actuationRule(action: RuleAction(moveTo: "Archive"))
        )
    }

    func testAgeGuardHoldsMessagesNewerThanFloor() {
        let plan = RuleApplyPlanner.plan(
            matches: [
                match(id: "old", date: "2026-01-01T12:00:00Z"), // 31 days
                match(id: "new", date: "2026-01-28T12:00:00Z"), // 4 days
            ],
            now: referenceNow,
            minAgeDays: 14,
            skipUnread: false,
            maxActions: 100
        )
        XCTAssertEqual(plan.planned.map(\.message.id), ["old"])
        XCTAssertEqual(plan.heldTooNew, 1)
    }

    func testAgeGuardBoundaryIsInclusive() {
        // Exactly minAgeDays old is eligible.
        let plan = RuleApplyPlanner.plan(
            matches: [match(id: "boundary", date: "2026-01-18T12:00:00Z")],
            now: referenceNow,
            minAgeDays: 14,
            skipUnread: false,
            maxActions: 100
        )
        XCTAssertEqual(plan.planned.count, 1)
        XCTAssertEqual(plan.heldTooNew, 0)
    }

    /// An unparseable date must fail closed — held, not archived.
    func testUndateableMessageIsHeld() {
        let plan = RuleApplyPlanner.plan(
            matches: [match(id: "junk", date: "not-a-date")],
            now: referenceNow,
            minAgeDays: 14,
            skipUnread: false,
            maxActions: 100
        )
        XCTAssertTrue(plan.planned.isEmpty)
        XCTAssertEqual(plan.heldTooNew, 1)
    }

    func testFractionalSecondDatesParse() {
        let plan = RuleApplyPlanner.plan(
            matches: [match(id: "frac", date: "2026-01-01T12:00:00.000Z")],
            now: referenceNow,
            minAgeDays: 14,
            skipUnread: false,
            maxActions: 100
        )
        XCTAssertEqual(plan.planned.map(\.message.id), ["frac"])
        XCTAssertEqual(plan.heldTooNew, 0)
    }

    func testSkipUnreadHoldsUnreadMessages() {
        let matches = [
            match(id: "read", date: "2026-01-01T12:00:00Z", read: true),
            match(id: "unread", date: "2026-01-01T12:00:00Z", read: false),
        ]
        let held = RuleApplyPlanner.plan(
            matches: matches, now: referenceNow, minAgeDays: 14, skipUnread: true, maxActions: 100
        )
        XCTAssertEqual(held.planned.map(\.message.id), ["read"])
        XCTAssertEqual(held.heldUnread, 1)

        let notHeld = RuleApplyPlanner.plan(
            matches: matches, now: referenceNow, minAgeDays: 14, skipUnread: false, maxActions: 100
        )
        XCTAssertEqual(notHeld.planned.count, 2)
        XCTAssertEqual(notHeld.heldUnread, 0)
    }

    /// A capped run must drain the oldest backlog, not skim whatever the scan
    /// returned first — otherwise repeated capped runs never reach old mail.
    func testCapTakesOldestFirst() {
        let plan = RuleApplyPlanner.plan(
            matches: [
                match(id: "newest", date: "2026-01-15T12:00:00Z"),
                match(id: "oldest", date: "2025-06-01T12:00:00Z"),
                match(id: "middle", date: "2025-12-01T12:00:00Z"),
            ],
            now: referenceNow,
            minAgeDays: 14,
            skipUnread: false,
            maxActions: 2
        )
        XCTAssertEqual(plan.planned.map(\.message.id), ["oldest", "middle"])
        XCTAssertEqual(plan.heldOverCap, 1)
    }

    func testHeldOverCapIsZeroWhenUnderCap() {
        let plan = RuleApplyPlanner.plan(
            matches: [match(id: "a", date: "2026-01-01T12:00:00Z")],
            now: referenceNow,
            minAgeDays: 14,
            skipUnread: false,
            maxActions: 200
        )
        XCTAssertEqual(plan.heldOverCap, 0)
    }

    /// The cap counts only eligible messages — ones already held by the age or
    /// unread guard must not consume cap slots.
    func testHeldMessagesDoNotConsumeCap() {
        let plan = RuleApplyPlanner.plan(
            matches: [
                match(id: "tooNew", date: "2026-01-30T12:00:00Z"),
                match(id: "old1", date: "2025-06-01T12:00:00Z"),
                match(id: "old2", date: "2025-07-01T12:00:00Z"),
            ],
            now: referenceNow,
            minAgeDays: 14,
            skipUnread: false,
            maxActions: 2
        )
        XCTAssertEqual(plan.planned.map(\.message.id), ["old1", "old2"])
        XCTAssertEqual(plan.heldTooNew, 1)
        XCTAssertEqual(plan.heldOverCap, 0)
    }

    func testMinAgeZeroAllowsEverythingDateable() {
        let plan = RuleApplyPlanner.plan(
            matches: [match(id: "today", date: "2026-02-01T11:00:00Z")],
            now: referenceNow,
            minAgeDays: 0,
            skipUnread: false,
            maxActions: 100
        )
        XCTAssertEqual(plan.planned.count, 1)
    }
}
