@testable import PippinLib
import XCTest

/// Tests for pippin-ml9 phase-2 phishing signals: per-sender header baselines.
/// Modeled on the 2026-07-27 incident where the phish matched the contact's
/// baseline on every auth dimension but diverged on Date TZ offset (-0500 vs
/// the contact's invariant -0400).
final class SenderBaselineTests: XCTestCase {
    private func makeStore() throws -> SenderBaselineStore {
        try SenderBaselineStore(dbPath: NSTemporaryDirectory() + "pippin-test-baseline-\(UUID().uuidString).db")
    }

    private let legitHeaders: [String: String] = [
        "DKIM-Signature": "v=1; a=rsa-sha256; d=wfmnyc-com.20251104.gappssmtp.com; s=20251104; c=relaxed/relaxed",
        "Message-Id": "<CAJx1Zt7abc@mail.gmail.com>",
        "Date": "Mon, 27 Jul 2026 09:15:00 -0400",
        "Authentication-Results": "mx.google.com; dkim=pass; spf=pass; dmarc=pass",
    ]

    // MARK: - Fingerprint extraction

    func testFingerprintExtraction() {
        let fp = SenderFingerprint.extract(headers: legitHeaders)
        XCTAssertEqual(fp["dkim_domain"], "wfmnyc-com.20251104.gappssmtp.com")
        XCTAssertEqual(fp["dkim_selector"], "20251104")
        XCTAssertEqual(fp["msgid_domain"], "mail.gmail.com")
        XCTAssertEqual(fp["tz_offset"], "-0400")
        XCTAssertEqual(fp["auth_spf"], "pass")
        XCTAssertEqual(fp["auth_dkim"], "pass")
        XCTAssertEqual(fp["auth_dmarc"], "pass")
    }

    func testFingerprintAbsentDimensions() {
        let fp = SenderFingerprint.extract(headers: ["Subject": "hi"])
        XCTAssertEqual(fp["dkim_domain"], "absent")
        XCTAssertEqual(fp["auth_spf"], "absent")
        XCTAssertEqual(fp["tz_offset"], "absent")
    }

    func testEmailAddressExtraction() {
        XCTAssertEqual(HeaderAnomalies.emailAddress(in: "Jane Doe <Jane@Example.com>"), "jane@example.com")
        XCTAssertEqual(HeaderAnomalies.emailAddress(in: "jane@example.com"), "jane@example.com")
        XCTAssertNil(HeaderAnomalies.emailAddress(in: "no address here"))
    }

    // MARK: - Deviation detection

    private func seed(_ store: SenderBaselineStore, sender: String, count: Int, headers: [String: String]) {
        for i in 0 ..< count {
            _ = store.checkAndRecord(
                compoundId: "acc||INBOX||\(1000 + i)", sender: sender,
                fingerprint: SenderFingerprint.extract(headers: headers)
            )
        }
    }

    func testInvariantDeviationFlagged() throws {
        let store = try makeStore()
        seed(store, sender: "contact@wfmnyc.com", count: 3, headers: legitHeaders)

        var phish = legitHeaders
        phish["Date"] = "Mon, 27 Jul 2026 09:15:00 -0500"
        let warnings = store.checkAndRecord(
            compoundId: "acc||INBOX||9999", sender: "contact@wfmnyc.com",
            fingerprint: SenderFingerprint.extract(headers: phish)
        )
        XCTAssertTrue(warnings.contains { $0.contains("-0500") && $0.contains("-0400") },
                      "TZ offset deviation from invariant baseline must be flagged: \(warnings)")
    }

    func testNoDeviationBelowThreshold() throws {
        let store = try makeStore()
        seed(store, sender: "contact@wfmnyc.com", count: 2, headers: legitHeaders)

        var phish = legitHeaders
        phish["Date"] = "Mon, 27 Jul 2026 09:15:00 -0500"
        let warnings = store.checkAndRecord(
            compoundId: "acc||INBOX||9999", sender: "contact@wfmnyc.com",
            fingerprint: SenderFingerprint.extract(headers: phish)
        )
        XCTAssertTrue(warnings.isEmpty, "2 prior messages is below the baseline threshold: \(warnings)")
    }

    func testVariedBaselineNotFlagged() throws {
        let store = try makeStore()
        var altered = legitHeaders
        altered["Date"] = "Mon, 27 Jul 2026 09:15:00 -0700"
        seed(store, sender: "traveler@example.com", count: 2, headers: legitHeaders)
        seed(store, sender: "traveler@example.com", count: 2, headers: altered)

        var current = legitHeaders
        current["Date"] = "Mon, 27 Jul 2026 09:15:00 -0500"
        let warnings = store.checkAndRecord(
            compoundId: "acc||INBOX||9999", sender: "traveler@example.com",
            fingerprint: SenderFingerprint.extract(headers: current)
        )
        XCTAssertFalse(warnings.contains { $0.contains("TZ") || $0.contains("-0400") },
                       "a varied (non-invariant) dimension must not be flagged: \(warnings)")
    }

    func testRepeatCheckIsStable() throws {
        // Re-viewing the same phish must keep flagging it: the message's own
        // recorded fingerprint is excluded from its baseline comparison.
        let store = try makeStore()
        seed(store, sender: "contact@wfmnyc.com", count: 3, headers: legitHeaders)

        var phish = legitHeaders
        phish["Date"] = "Mon, 27 Jul 2026 09:15:00 -0500"
        let fp = SenderFingerprint.extract(headers: phish)
        let first = store.checkAndRecord(compoundId: "acc||INBOX||9999", sender: "contact@wfmnyc.com", fingerprint: fp)
        let second = store.checkAndRecord(compoundId: "acc||INBOX||9999", sender: "contact@wfmnyc.com", fingerprint: fp)
        XCTAssertEqual(first, second, "repeat views of the same message must produce identical warnings")
        XCTAssertFalse(second.isEmpty)
    }

    func testAuthAbsenceDeviationFlagged() throws {
        // "A contact whose mail always passes SPF suddenly absent" — the
        // absolute pass/fail rules in HeaderAnomalies can't catch this.
        let store = try makeStore()
        seed(store, sender: "contact@wfmnyc.com", count: 3, headers: legitHeaders)

        var phish = legitHeaders
        phish.removeValue(forKey: "Authentication-Results")
        let warnings = store.checkAndRecord(
            compoundId: "acc||INBOX||9999", sender: "contact@wfmnyc.com",
            fingerprint: SenderFingerprint.extract(headers: phish)
        )
        XCTAssertTrue(warnings.contains { $0.lowercased().contains("spf") && $0.contains("absent") },
                      "auth result vanishing vs an all-pass baseline must be flagged: \(warnings)")
    }

    func testDifferentSendersAreIndependent() throws {
        let store = try makeStore()
        seed(store, sender: "alice@example.com", count: 5, headers: legitHeaders)

        var other = legitHeaders
        other["Date"] = "Mon, 27 Jul 2026 09:15:00 -0500"
        let warnings = store.checkAndRecord(
            compoundId: "acc||INBOX||9999", sender: "bob@example.com",
            fingerprint: SenderFingerprint.extract(headers: other)
        )
        XCTAssertTrue(warnings.isEmpty, "one sender's baseline must not judge another sender: \(warnings)")
    }

    // MARK: - Compare-only check (list/search surfacing, pippin-fwa)

    func testCompareOnlyCheckFlagsWithoutRecording() throws {
        let store = try makeStore()
        seed(store, sender: "contact@wfmnyc.com", count: 3, headers: legitHeaders)

        var phish = legitHeaders
        phish["Date"] = "Mon, 27 Jul 2026 09:15:00 -0500"
        let fp = SenderFingerprint.extract(headers: phish)
        let warnings = store.check(compoundId: "acc||INBOX||9999", sender: "contact@wfmnyc.com", fingerprint: fp)
        XCTAssertTrue(warnings.contains { $0.contains("-0500") }, "deviation flagged: \(warnings)")

        // Nothing recorded: the baseline still holds exactly the 3 seeds, and
        // the phish row does not appear when excluding an unrelated id.
        let base = store.baseline(sender: "contact@wfmnyc.com", excluding: "acc||INBOX||other")
        XCTAssertEqual(base["tz_offset"], ["-0400": 3], "check() must not mutate the store")
    }

    // MARK: - Baseline reporting (mail verify)

    func testBaselineReportExcludesCurrentMessage() throws {
        let store = try makeStore()
        seed(store, sender: "contact@wfmnyc.com", count: 3, headers: legitHeaders)
        _ = store.checkAndRecord(
            compoundId: "acc||INBOX||9999", sender: "contact@wfmnyc.com",
            fingerprint: SenderFingerprint.extract(headers: legitHeaders)
        )
        let base = store.baseline(sender: "contact@wfmnyc.com", excluding: "acc||INBOX||9999")
        XCTAssertEqual(base["tz_offset"], ["-0400": 3])
    }

    func testIsDeviationRule() {
        XCTAssertTrue(SenderBaselineStore.isDeviation(prior: ["-0400": 3], current: "-0500"))
        XCTAssertFalse(SenderBaselineStore.isDeviation(prior: ["-0400": 3], current: "-0400"))
        XCTAssertFalse(SenderBaselineStore.isDeviation(prior: ["-0400": 2], current: "-0500"), "below threshold")
        XCTAssertFalse(SenderBaselineStore.isDeviation(prior: ["-0400": 2, "-0700": 2], current: "-0500"), "not invariant")
        XCTAssertFalse(SenderBaselineStore.isDeviation(prior: [:], current: "-0500"), "no history")
    }
}
