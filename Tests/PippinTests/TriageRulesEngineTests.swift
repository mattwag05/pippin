@testable import PippinLib
import XCTest

// MARK: - Helpers

private func makeMessage(
    id: String = "acc||INBOX||1",
    subject: String = "Hello",
    from: String = "sender@example.com",
    account: String = "acc",
    bodyPreview: String? = nil
) -> MailMessage {
    MailMessage(
        id: id,
        account: account,
        mailbox: "INBOX",
        subject: subject,
        from: from,
        to: ["me@example.com"],
        date: "2026-04-20T12:00:00Z",
        read: false,
        bodyPreview: bodyPreview
    )
}

private func makeRule(
    id: String = "r1",
    name: String = "Test Rule",
    conditions: [RuleCondition],
    conditionOperator: ConditionOperator = .and,
    action: RuleAction = RuleAction(setCategory: .promotional, setUrgency: 1),
    enabled: Bool = true
) -> TriageRule {
    TriageRule(
        id: id,
        name: name,
        conditions: conditions,
        conditionOperator: conditionOperator,
        action: action,
        enabled: enabled
    )
}

// MARK: - Tests

final class TriageRulesEngineTests: XCTestCase {
    // MARK: - No rules

    func testNoRulesReturnsAllAsRemaining() {
        let messages = [makeMessage(id: "m1"), makeMessage(id: "m2")]
        let (remaining, ruleTriaged) = TriageRulesEngine.apply(rules: [], to: messages)
        XCTAssertEqual(remaining.count, 2)
        XCTAssertTrue(ruleTriaged.isEmpty)
    }

    // MARK: - Sender matching

    func testSenderContainsMatch() {
        let rule = makeRule(conditions: [
            RuleCondition(field: .sender, matchOperator: .contains, value: "newsletter"),
        ])
        let matched = makeMessage(from: "weekly-newsletter@brand.com")
        let unmatched = makeMessage(from: "boss@company.com")

        let (remaining, ruleTriaged) = TriageRulesEngine.apply(rules: [rule], to: [matched, unmatched])
        XCTAssertEqual(ruleTriaged.count, 1)
        XCTAssertEqual(ruleTriaged[0].compoundId, matched.id)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].id, unmatched.id)
    }

    func testSenderEqualsMatch() {
        let rule = makeRule(conditions: [
            RuleCondition(field: .sender, matchOperator: .equals, value: "noreply@github.com"),
        ])
        let matched = makeMessage(from: "noreply@github.com")
        let unmatched = makeMessage(from: "other@github.com")

        let (remaining, ruleTriaged) = TriageRulesEngine.apply(rules: [rule], to: [matched, unmatched])
        XCTAssertEqual(ruleTriaged.count, 1)
        XCTAssertEqual(remaining.count, 1)
    }

    func testSenderStartsWithMatch() {
        let rule = makeRule(conditions: [
            RuleCondition(field: .sender, matchOperator: .startsWith, value: "noreply"),
        ])
        let matched = makeMessage(from: "noreply@service.com")
        let unmatched = makeMessage(from: "hello@noreply.com")

        let (remaining, ruleTriaged) = TriageRulesEngine.apply(rules: [rule], to: [matched, unmatched])
        XCTAssertEqual(ruleTriaged.count, 1)
        XCTAssertEqual(ruleTriaged[0].compoundId, matched.id)
        XCTAssertEqual(remaining.count, 1)
    }

    // MARK: - Subject matching

    func testSubjectContainsMatch() {
        let rule = makeRule(conditions: [
            RuleCondition(field: .subject, matchOperator: .contains, value: "unsubscribe"),
        ])
        let matched = makeMessage(subject: "Click here to unsubscribe from our list")
        let unmatched = makeMessage(subject: "Meeting at 3pm")

        let (remaining, ruleTriaged) = TriageRulesEngine.apply(rules: [rule], to: [matched, unmatched])
        XCTAssertEqual(ruleTriaged.count, 1)
        XCTAssertEqual(remaining.count, 1)
    }

    // MARK: - Keyword field (bodyPreview fallback)

    func testKeywordMatchesBodyPreview() {
        let rule = makeRule(conditions: [
            RuleCondition(field: .keyword, matchOperator: .contains, value: "invoice"),
        ])
        let withPreview = makeMessage(subject: "Your receipt", bodyPreview: "Please find your invoice attached.")
        let withoutMatch = makeMessage(subject: "Hello there", bodyPreview: "Just saying hi.")

        let (remaining, ruleTriaged) = TriageRulesEngine.apply(rules: [rule], to: [withPreview, withoutMatch])
        XCTAssertEqual(ruleTriaged.count, 1)
        XCTAssertEqual(ruleTriaged[0].compoundId, withPreview.id)
        XCTAssertEqual(remaining.count, 1)
    }

    func testKeywordFallsBackToSubjectWhenNoPreview() {
        let rule = makeRule(conditions: [
            RuleCondition(field: .keyword, matchOperator: .contains, value: "invoice"),
        ])
        let message = makeMessage(subject: "Your invoice is ready", bodyPreview: nil)

        let (remaining, ruleTriaged) = TriageRulesEngine.apply(rules: [rule], to: [message])
        XCTAssertEqual(ruleTriaged.count, 1)
        XCTAssertTrue(remaining.isEmpty)
    }

    // MARK: - Account field

    func testAccountContainsMatch() {
        let rule = makeRule(conditions: [
            RuleCondition(field: .account, matchOperator: .contains, value: "work"),
        ])
        let workMsg = makeMessage(account: "work-gmail")
        let personalMsg = makeMessage(account: "personal")

        let (remaining, ruleTriaged) = TriageRulesEngine.apply(rules: [rule], to: [workMsg, personalMsg])
        XCTAssertEqual(ruleTriaged.count, 1)
        XCTAssertEqual(ruleTriaged[0].compoundId, workMsg.id)
        XCTAssertEqual(remaining.count, 1)
    }

    // MARK: - Regex operator

    func testRegexMatchOperator() {
        let rule = makeRule(conditions: [
            RuleCondition(field: .sender, matchOperator: .matches, value: "no-?reply@"),
        ])
        let matched1 = makeMessage(id: "m1", from: "noreply@foo.com")
        let matched2 = makeMessage(id: "m2", from: "no-reply@bar.com")
        let unmatched = makeMessage(id: "m3", from: "hello@baz.com")

        let (remaining, ruleTriaged) = TriageRulesEngine.apply(rules: [rule], to: [matched1, matched2, unmatched])
        XCTAssertEqual(ruleTriaged.count, 2)
        XCTAssertEqual(remaining.count, 1)
    }

    func testInvalidRegexDoesNotMatch() {
        let rule = makeRule(conditions: [
            RuleCondition(field: .sender, matchOperator: .matches, value: "[invalid"),
        ])
        let message = makeMessage(from: "anyone@example.com")
        let (remaining, ruleTriaged) = TriageRulesEngine.apply(rules: [rule], to: [message])
        XCTAssertEqual(remaining.count, 1)
        XCTAssertTrue(ruleTriaged.isEmpty)
    }

    // MARK: - AND vs OR condition operators

    func testAndConditionRequiresBothToMatch() {
        let rule = makeRule(
            conditions: [
                RuleCondition(field: .sender, matchOperator: .contains, value: "newsletter"),
                RuleCondition(field: .subject, matchOperator: .contains, value: "weekly"),
            ],
            conditionOperator: .and
        )
        let bothMatch = makeMessage(subject: "Your weekly digest", from: "newsletter@brand.com")
        let onlyFirst = makeMessage(subject: "Important update", from: "newsletter@brand.com")
        let onlySecond = makeMessage(subject: "weekly digest", from: "marketing@brand.com")

        let (remaining, ruleTriaged) = TriageRulesEngine.apply(rules: [rule], to: [bothMatch, onlyFirst, onlySecond])
        XCTAssertEqual(ruleTriaged.count, 1)
        XCTAssertEqual(ruleTriaged[0].compoundId, bothMatch.id)
        XCTAssertEqual(remaining.count, 2)
    }

    func testOrConditionRequiresEitherToMatch() {
        let rule = makeRule(
            conditions: [
                RuleCondition(field: .sender, matchOperator: .contains, value: "newsletter"),
                RuleCondition(field: .subject, matchOperator: .contains, value: "weekly"),
            ],
            conditionOperator: .or
        )
        let senderOnly = makeMessage(subject: "General update", from: "newsletter@brand.com")
        let subjectOnly = makeMessage(subject: "Your weekly update", from: "other@brand.com")
        let neither = makeMessage(subject: "Hello", from: "friend@example.com")

        let (remaining, ruleTriaged) = TriageRulesEngine.apply(rules: [rule], to: [senderOnly, subjectOnly, neither])
        XCTAssertEqual(ruleTriaged.count, 2)
        XCTAssertEqual(remaining.count, 1)
    }

    // MARK: - skip action

    func testSkipExcludesMessageFromAllLists() {
        let rule = makeRule(
            conditions: [RuleCondition(field: .sender, matchOperator: .contains, value: "spam")],
            action: RuleAction(skip: true)
        )
        let spam = makeMessage(from: "spam@junk.com")
        let legit = makeMessage(from: "legit@example.com")

        let (remaining, ruleTriaged) = TriageRulesEngine.apply(rules: [rule], to: [spam, legit])
        XCTAssertEqual(remaining.count, 1)
        XCTAssertTrue(ruleTriaged.isEmpty)
        XCTAssertEqual(remaining[0].id, legit.id)
    }

    // MARK: - Disabled rules

    func testDisabledRuleIsIgnored() {
        let rule = makeRule(
            conditions: [RuleCondition(field: .sender, matchOperator: .contains, value: "newsletter")],
            enabled: false
        )
        let message = makeMessage(from: "newsletter@brand.com")
        let (remaining, ruleTriaged) = TriageRulesEngine.apply(rules: [rule], to: [message])
        XCTAssertEqual(remaining.count, 1)
        XCTAssertTrue(ruleTriaged.isEmpty)
    }

    // MARK: - Action fields propagated

    func testRuleActionCategoryAndUrgencyPropagated() {
        let rule = makeRule(
            conditions: [RuleCondition(field: .sender, matchOperator: .contains, value: "promo")],
            action: RuleAction(setCategory: .promotional, setUrgency: 1)
        )
        let message = makeMessage(from: "promo@shop.com")
        let (_, ruleTriaged) = TriageRulesEngine.apply(rules: [rule], to: [message])
        XCTAssertEqual(ruleTriaged[0].category, .promotional)
        XCTAssertEqual(ruleTriaged[0].urgency, 1)
    }

    func testRuleActionDefaultsWhenNil() {
        let rule = makeRule(
            conditions: [RuleCondition(field: .sender, matchOperator: .contains, value: "promo")],
            action: RuleAction() // no category or urgency set
        )
        let message = makeMessage(from: "promo@shop.com")
        let (_, ruleTriaged) = TriageRulesEngine.apply(rules: [rule], to: [message])
        XCTAssertEqual(ruleTriaged[0].category, .informational)
        XCTAssertEqual(ruleTriaged[0].urgency, 2)
    }

    func testRuleActionOneLinerContainsRuleName() {
        let rule = makeRule(
            name: "Newsletter Filter",
            conditions: [RuleCondition(field: .sender, matchOperator: .contains, value: "newsletter")]
        )
        let message = makeMessage(from: "newsletter@brand.com")
        let (_, ruleTriaged) = TriageRulesEngine.apply(rules: [rule], to: [message])
        XCTAssertTrue(ruleTriaged[0].oneLiner.contains("Newsletter Filter"))
    }

    // MARK: - Case-insensitive matching

    func testMatchingIsCaseInsensitive() {
        let rule = makeRule(conditions: [
            RuleCondition(field: .sender, matchOperator: .contains, value: "NEWSLETTER"),
        ])
        let message = makeMessage(from: "newsletter@brand.com")
        let (remaining, ruleTriaged) = TriageRulesEngine.apply(rules: [rule], to: [message])
        XCTAssertEqual(ruleTriaged.count, 1)
        XCTAssertTrue(remaining.isEmpty)
    }

    // MARK: - First matching rule wins

    func testFirstMatchingRuleWins() {
        let rule1 = makeRule(
            id: "r1", name: "Rule 1",
            conditions: [RuleCondition(field: .sender, matchOperator: .contains, value: "promo")],
            action: RuleAction(setCategory: .promotional, setUrgency: 1)
        )
        let rule2 = makeRule(
            id: "r2", name: "Rule 2",
            conditions: [RuleCondition(field: .sender, matchOperator: .contains, value: "promo")],
            action: RuleAction(setCategory: .urgent, setUrgency: 5)
        )
        let message = makeMessage(from: "promo@shop.com")
        let (_, ruleTriaged) = TriageRulesEngine.apply(rules: [rule1, rule2], to: [message])
        XCTAssertEqual(ruleTriaged.count, 1)
        XCTAssertEqual(ruleTriaged[0].category, .promotional)
    }

    // MARK: - Codable round-trip

    func testTriageRuleCodableRoundTrip() throws {
        let rule = TriageRule(
            id: "test-rule",
            name: "My Rule",
            conditions: [
                RuleCondition(field: .sender, matchOperator: .contains, value: "newsletter"),
                RuleCondition(field: .subject, matchOperator: .matches, value: "\\bweekly\\b"),
            ],
            conditionOperator: .or,
            action: RuleAction(setCategory: .promotional, setUrgency: 1, label: "promo", skip: nil),
            enabled: true
        )
        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(TriageRule.self, from: data)
        XCTAssertEqual(decoded.id, rule.id)
        XCTAssertEqual(decoded.name, rule.name)
        XCTAssertEqual(decoded.conditions.count, 2)
        XCTAssertEqual(decoded.conditions[0].field, .sender)
        XCTAssertEqual(decoded.conditions[0].matchOperator, .contains)
        XCTAssertEqual(decoded.conditionOperator, .or)
        XCTAssertEqual(decoded.action.setCategory, .promotional)
        XCTAssertEqual(decoded.action.setUrgency, 1)
        XCTAssertEqual(decoded.action.label, "promo")
        XCTAssertTrue(decoded.enabled)
    }

    func testConditionOperatorCodingKey() throws {
        let json = """
        {
          "field": "sender",
          "operator": "contains",
          "value": "test"
        }
        """
        let condition = try JSONDecoder().decode(RuleCondition.self, from: Data(json.utf8))
        XCTAssertEqual(condition.field, .sender)
        XCTAssertEqual(condition.matchOperator, .contains)
        XCTAssertEqual(condition.value, "test")
    }

    // MARK: - loadRules from disk

    func testLoadRulesReturnsEmptyForMissingFile() {
        let rules = TriageRulesEngine.loadRules(path: "/nonexistent/path/triage-rules.json")
        XCTAssertTrue(rules.isEmpty)
    }

    func testLoadRulesFiltersDisabledEntries() throws {
        let rulesJSON = """
        [
          { "id":"r1","name":"Active","conditions":[{"field":"sender","operator":"contains","value":"spam"}],"conditionOperator":"and","action":{},"enabled":true },
          { "id":"r2","name":"Disabled","conditions":[{"field":"sender","operator":"contains","value":"foo"}],"conditionOperator":"and","action":{},"enabled":false }
        ]
        """
        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("triage-rules-test.json")
        try Data(rulesJSON.utf8).write(to: tmpFile)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let rules = TriageRulesEngine.loadRules(path: tmpFile.path)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].id, "r1")
    }
}
