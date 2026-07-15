@testable import PippinLib
import XCTest

/// Tests for `MailBridge.ListMeta` JSON decoding. The `timedOut` field landed
/// when soft-timeout was extended from `mail_search` to `mail_list`; legacy
/// fixtures (and any caller that omits it) must still decode cleanly.
final class MailBridgeListMetaTests: XCTestCase {
    func testDecodesNewPayloadWithTimedOutFalse() throws {
        let json = #"{"accountsScanned":1,"mailboxesScanned":1,"messagesExamined":50,"timedOut":false}"#
        let meta = try JSONDecoder().decode(MailBridge.ListMeta.self, from: Data(json.utf8))
        XCTAssertEqual(meta.accountsScanned, 1)
        XCTAssertEqual(meta.mailboxesScanned, 1)
        XCTAssertEqual(meta.messagesExamined, 50)
        XCTAssertFalse(meta.timedOut)
    }

    func testDecodesNewPayloadWithTimedOutTrue() throws {
        let json = #"{"accountsScanned":2,"mailboxesScanned":2,"messagesExamined":120,"timedOut":true}"#
        let meta = try JSONDecoder().decode(MailBridge.ListMeta.self, from: Data(json.utf8))
        XCTAssertTrue(meta.timedOut)
    }

    func testDecodesLegacyPayloadWithoutTimedOut() throws {
        // Older JXA scripts omit the field entirely. Must default to false, not error.
        let json = #"{"accountsScanned":1,"mailboxesScanned":1,"messagesExamined":20}"#
        let meta = try JSONDecoder().decode(MailBridge.ListMeta.self, from: Data(json.utf8))
        XCTAssertEqual(meta.accountsScanned, 1)
        XCTAssertFalse(meta.timedOut, "missing timedOut must default to false")
    }

    func testDecodesFullListResponseWrapper() throws {
        let json = """
        {
          "results": [],
          "meta": {"accountsScanned":1,"mailboxesScanned":1,"messagesExamined":10,"timedOut":true}
        }
        """
        let response = try JSONDecoder().decode(MailBridge.ListResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.results.count, 0)
        XCTAssertTrue(response.meta.timedOut)
    }

    func testDecodesShortfallTelemetryFields() throws {
        let json = #"{"accountsScanned":1,"mailboxesScanned":1,"messagesExamined":50,"timedOut":false,"reachedMailboxEnd":false,"oldestExaminedMs":1700000000000}"#
        let meta = try JSONDecoder().decode(MailBridge.ListMeta.self, from: Data(json.utf8))
        XCTAssertFalse(meta.reachedMailboxEnd)
        XCTAssertEqual(meta.oldestExaminedMs, 1_700_000_000_000)
    }

    func testShortfallTelemetryDefaultsWhenAbsent() throws {
        // Legacy scripts (and search/activity) omit the new fields.
        let json = #"{"accountsScanned":1,"mailboxesScanned":1,"messagesExamined":20}"#
        let meta = try JSONDecoder().decode(MailBridge.ListMeta.self, from: Data(json.utf8))
        XCTAssertTrue(meta.reachedMailboxEnd, "absent reachedMailboxEnd defaults to true (no shortfall)")
        XCTAssertNil(meta.oldestExaminedMs)
    }

    // MARK: - beforeShortfallHint

    /// Oldest scanned message (2023) is still newer than a 2020 --before cutoff
    /// and the window was truncated → advise the user the scan fell short.
    func testShortfallHintFiresWhenWindowTooShallow() {
        let oldest2023 = 1_672_531_200_000.0 // 2023-01-01 UTC
        let hint = MailBridge.beforeShortfallHint(
            resultsEmpty: true, timedOut: false, before: "2020-01-01",
            reachedMailboxEnd: false, oldestExaminedMs: oldest2023
        )
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.contains("did not reach 2020-01-01"))
    }

    func testShortfallHintSuppressedWhenMailboxFullyScanned() {
        // Whole mailbox scanned, still empty → a true "no matches," no hint.
        XCTAssertNil(MailBridge.beforeShortfallHint(
            resultsEmpty: true, timedOut: false, before: "2020-01-01",
            reachedMailboxEnd: true, oldestExaminedMs: 1_672_531_200_000
        ))
    }

    func testShortfallHintSuppressedWhenResultsPresent() {
        XCTAssertNil(MailBridge.beforeShortfallHint(
            resultsEmpty: false, timedOut: false, before: "2020-01-01",
            reachedMailboxEnd: false, oldestExaminedMs: 1_672_531_200_000
        ))
    }

    func testShortfallHintSuppressedWhenNoBeforeFilter() {
        XCTAssertNil(MailBridge.beforeShortfallHint(
            resultsEmpty: true, timedOut: false, before: nil,
            reachedMailboxEnd: false, oldestExaminedMs: 1_672_531_200_000
        ))
    }

    /// Oldest scanned message is already older than --before → deeper scanning
    /// wouldn't help; empty is genuine, so no shortfall hint.
    func testShortfallHintSuppressedWhenScanReachedPastCutoff() {
        let oldest2019 = 1_546_300_800_000.0 // 2019-01-01 UTC, older than 2020 cutoff
        XCTAssertNil(MailBridge.beforeShortfallHint(
            resultsEmpty: true, timedOut: false, before: "2020-01-01",
            reachedMailboxEnd: false, oldestExaminedMs: oldest2019
        ))
    }
}
