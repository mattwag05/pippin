@testable import PippinLib
import XCTest

/// Tests for the `mail verify` raw-source deep parse (pippin-fwa): RFC 5322
/// header unfolding, auth-chain SET recovery (destroyed by the flat last-wins
/// `allHeaders()` dict), and chain-only warnings.
final class RawSourceTests: XCTestCase {
    /// Forwarded-message shape: two Received hops, two Authentication-Results
    /// (the ARC/forwarding case the flat dict collapses), a folded header, an
    /// ARC set, and a body that must not be parsed as headers.
    private let source = [
        "Received: from mx2.example.com (mx2.example.com [10.0.0.2])",
        "\tby mail.example.com with ESMTPS id abc123;",
        "\tMon, 27 Jul 2026 09:15:02 -0400",
        "Received: from sender.example.org (sender.example.org [10.0.0.9])",
        "\tby mx2.example.com with ESMTPS id def456",
        "Authentication-Results: mx2.example.com; dkim=pass; spf=pass; dmarc=pass",
        "Authentication-Results: forwarder.example.net; dkim=fail; spf=softfail",
        "ARC-Authentication-Results: i=1; forwarder.example.net; dmarc=permerror",
        "ARC-Seal: i=1; a=rsa-sha256; cv=none; d=forwarder.example.net; s=arc1;",
        "\tb=QUJDREVGabcdef0123456789",
        "DKIM-Signature: v=1; a=rsa-sha256; d=example.org; s=sel1;",
        "\tbh=Ym9keWhhc2g=; b=c2lnbmF0dXJl",
        "From: Sender <sender@example.org>",
        "Subject: Hello",
        "",
        "Body line that looks like a header: value",
        "Received: fake-in-body",
    ].joined(separator: "\r\n")

    // MARK: - RFC 5322 parsing

    func testParseUnfoldsAndPreservesOrderAndSets() {
        let headers = RawHeaders.parse(source)
        let received = headers.filter { $0.name == "Received" }.map(\.value)
        XCTAssertEqual(received.count, 2, "both Received hops kept, body's fake one excluded")
        XCTAssertTrue(received[0].hasPrefix("from mx2.example.com"), "topmost hop first")
        XCTAssertTrue(
            received[0].contains("id abc123; Mon, 27 Jul 2026 09:15:02 -0400"),
            "folded continuation lines joined into one value"
        )
        XCTAssertEqual(headers.filter { $0.name == "Authentication-Results" }.count, 2)
        XCTAssertEqual(headers.last?.name, "Subject", "parsing stopped at the blank line")
    }

    func testParseHandlesBareLFAndMissingBody() {
        let headers = RawHeaders.parse("A: 1\nB: 2\n continued\n")
        XCTAssertEqual(headers.map(\.name), ["A", "B"])
        XCTAssertEqual(headers[1].value, "2 continued")
    }

    func testParseIgnoresInvalidFieldNames() {
        // A colon-containing line whose "name" has spaces is not a header.
        let headers = RawHeaders.parse("Not a header: x\nReal-Header: y\n")
        XCTAssertEqual(headers.map(\.name), ["Real-Header"])
    }

    // MARK: - Auth chain extraction

    func testAuthChainCollectsSets() {
        let chain = RawHeaders.authChain(RawHeaders.parse(source))
        XCTAssertEqual(chain.received.count, 2)
        XCTAssertEqual(chain.authenticationResults.count, 2)
        XCTAssertEqual(chain.arcAuthenticationResults.count, 1)
        XCTAssertEqual(chain.arcSeals.count, 1)
        XCTAssertEqual(chain.dkimSignatures.count, 1)
    }

    func testSignatureDataElided() throws {
        let chain = RawHeaders.authChain(RawHeaders.parse(source))
        let seal = try XCTUnwrap(chain.arcSeals.first)
        XCTAssertFalse(seal.contains("QUJDREVG"), "b= blob stripped from ARC-Seal")
        XCTAssertTrue(seal.contains("d=forwarder.example.net"), "other tags kept")
        let dkim = try XCTUnwrap(chain.dkimSignatures.first)
        XCTAssertFalse(dkim.contains("c2lnbmF0dXJl"), "b= stripped from DKIM")
        XCTAssertFalse(dkim.contains("Ym9keWhhc2g"), "bh= stripped from DKIM")
        XCTAssertTrue(dkim.contains("s=sel1"), "selector kept")
    }

    // MARK: - Deep warnings

    func testDeepWarningsFindFailuresInEveryInstance() {
        // The flat dict only saw ONE Authentication-Results (last-wins); the
        // chain must surface failures from all instances, ARC included.
        let warnings = RawHeaders.deepWarnings(RawHeaders.authChain(RawHeaders.parse(source)))
        XCTAssertTrue(warnings.contains("Authentication failure: dkim=fail"))
        XCTAssertTrue(warnings.contains("Authentication failure: spf=softfail"))
        XCTAssertTrue(warnings.contains("Authentication failure: dmarc=permerror"), "from ARC-Authentication-Results")
    }

    func testDeepWarningsFlagBrokenArcChain() {
        let chain = RawHeaders.authChain(RawHeaders.parse(
            "ARC-Seal: i=1; cv=fail; d=x.com; s=s1; b=abc\nFrom: a@b.com\n\n"
        ))
        XCTAssertTrue(RawHeaders.deepWarnings(chain).contains(where: { $0.contains("cv=fail") }))
    }

    func testCleanChainProducesNoWarnings() {
        let chain = RawHeaders.authChain(RawHeaders.parse(
            "Authentication-Results: mx.example.com; dkim=pass; spf=pass; dmarc=pass\nARC-Seal: i=1; cv=none; b=abc\n\n"
        ))
        XCTAssertEqual(RawHeaders.deepWarnings(chain), [])
    }

    // MARK: - Source script

    func testBuildSourceScriptShape() {
        let script = MailBridge.buildSourceScript(account: "iCloud", mailbox: "INBOX", messageId: "42")
        XCTAssertTrue(script.contains("msgs[0].source()"))
        XCTAssertTrue(script.contains("{ source: src }"))
        XCTAssertTrue(script.contains("whose({id: 42})"))
        XCTAssertTrue(script.contains("throw new Error('Message not found');"))
    }
}
