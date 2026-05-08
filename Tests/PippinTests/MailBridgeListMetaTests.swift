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
}
