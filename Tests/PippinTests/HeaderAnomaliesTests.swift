@testable import PippinLib
import XCTest

/// Regression tests for pippin-0pk, modeled on the real 2026-07-27 incident: a
/// trusted contact's compromised account sent a phishing blast with VALID DKIM
/// (signed by the real Workspace tenant) but an unrelated outlook.com Reply-To
/// and undisclosed-recipients/Bcc delivery. The invariant under test: those
/// structural anomalies are flagged, and dkim=pass never suppresses a warning.
final class HeaderAnomaliesTests: XCTestCase {
    // Header shape mirrors Mail.app's allHeaders() parse (folded, last-wins).
    private let phishHeaders: [String: String] = [
        "Reply-To": "michael.d.yoland@outlook.com",
        "To": "undisclosed-recipients:;",
        "Authentication-Results": "mx.google.com; dkim=pass header.i=@wfmnyc-com.20251104.gappssmtp.com; spf=none; dmarc=none",
        "Message-Id": "<CAJx1Zt7@mail.gmail.com>",
    ]

    func testPhishFixtureYieldsWarnings() {
        let warnings = HeaderAnomalies.detect(
            from: "Trusted Contact <contact@wfmnyc.com>",
            to: [],
            headers: phishHeaders
        )
        XCTAssertNotNil(warnings)
        XCTAssertTrue(warnings!.contains { $0.contains("outlook.com") && $0.contains("wfmnyc.com") },
                      "Reply-To/From domain mismatch must be flagged: \(warnings!)")
        XCTAssertTrue(warnings!.contains { $0.contains("hidden") },
                      "undisclosed-recipients delivery must be flagged: \(warnings!)")
    }

    func testDkimPassDoesNotSuppressWarnings() {
        // Same fixture minus the recipient anomaly — the Reply-To warning must
        // survive a fully passing auth chain.
        let warnings = HeaderAnomalies.detect(
            from: "Trusted Contact <contact@wfmnyc.com>",
            to: ["mw321619@ohio.edu"],
            headers: [
                "Reply-To": "michael.d.yoland@outlook.com",
                "To": "mw321619@ohio.edu",
                "Authentication-Results": "mx.google.com; dkim=pass; spf=pass; dmarc=pass",
            ]
        )
        XCTAssertNotNil(warnings)
        XCTAssertTrue(warnings!.contains { $0.contains("Reply-To") })
    }

    func testLegitMessageFromSameContactYieldsNil() {
        let warnings = HeaderAnomalies.detect(
            from: "Trusted Contact <contact@wfmnyc.com>",
            to: ["mw321619@ohio.edu"],
            headers: [
                "To": "mw321619@ohio.edu",
                "Authentication-Results": "mx.google.com; dkim=pass header.i=@wfmnyc-com.20251104.gappssmtp.com",
                "Message-Id": "<CAJx1Zt8@mail.gmail.com>",
            ]
        )
        XCTAssertNil(warnings)
    }

    func testSameDomainReplyToNotFlagged() {
        let warnings = HeaderAnomalies.detect(
            from: "Support <support@example.com>",
            to: ["mw321619@ohio.edu"],
            headers: ["Reply-To": "no-reply@example.com", "To": "mw321619@ohio.edu"]
        )
        XCTAssertNil(warnings)
    }

    func testAuthFailuresFlagged() {
        let warnings = HeaderAnomalies.detect(
            from: "a@spoofed.com",
            to: ["mw321619@ohio.edu"],
            headers: [
                "To": "mw321619@ohio.edu",
                "Authentication-Results": "mx.google.com; spf=softfail smtp.mailfrom=spoofed.com; dkim=fail; dmarc=fail",
            ]
        )
        XCTAssertNotNil(warnings)
        XCTAssertTrue(warnings!.contains { $0.contains("spf=softfail") })
        XCTAssertTrue(warnings!.contains { $0.contains("dkim=fail") })
        XCTAssertTrue(warnings!.contains { $0.contains("dmarc=fail") })
    }

    func testReceivedSpfFailFlaggedWithoutAuthResultsHeader() {
        let warnings = HeaderAnomalies.detect(
            from: "a@spoofed.com",
            to: ["mw321619@ohio.edu"],
            headers: ["To": "mw321619@ohio.edu", "Received-Spf": "Fail (protection.outlook.com: domain of spoofed.com does not designate ...)"]
        )
        XCTAssertNotNil(warnings)
        XCTAssertTrue(warnings!.contains { $0.contains("SPF fail") })
    }

    func testNoHeadersYieldsNil() {
        XCTAssertNil(HeaderAnomalies.detect(from: "a@b.com", to: [], headers: nil))
        XCTAssertNil(HeaderAnomalies.detect(from: "a@b.com", to: [], headers: [:]))
    }

    func testEmailDomainParsing() {
        XCTAssertEqual(HeaderAnomalies.emailDomain(in: "Jane <jane@Example.COM>"), "example.com")
        XCTAssertEqual(HeaderAnomalies.emailDomain(in: "jane@example.com"), "example.com")
        XCTAssertNil(HeaderAnomalies.emailDomain(in: "undisclosed-recipients:;"))
    }
}
