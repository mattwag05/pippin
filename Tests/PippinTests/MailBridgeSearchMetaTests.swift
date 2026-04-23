@testable import PippinLib
import XCTest

/// Tests for `MailBridge.SearchMeta` JSON decoding. The `timedOut` field was
/// added when soft-timeout was introduced; older scripts (or any future caller
/// that omits it) must still decode cleanly.
final class MailBridgeSearchMetaTests: XCTestCase {
    func testDecodesNewPayloadWithTimedOutFalse() throws {
        let json = #"{"accountsScanned":2,"mailboxesScanned":12,"messagesExamined":340,"timedOut":false}"#
        let meta = try JSONDecoder().decode(MailBridge.SearchMeta.self, from: Data(json.utf8))
        XCTAssertEqual(meta.accountsScanned, 2)
        XCTAssertEqual(meta.mailboxesScanned, 12)
        XCTAssertEqual(meta.messagesExamined, 340)
        XCTAssertFalse(meta.timedOut)
    }

    func testDecodesNewPayloadWithTimedOutTrue() throws {
        let json = #"{"accountsScanned":5,"mailboxesScanned":40,"messagesExamined":1200,"timedOut":true}"#
        let meta = try JSONDecoder().decode(MailBridge.SearchMeta.self, from: Data(json.utf8))
        XCTAssertTrue(meta.timedOut)
    }

    func testDecodesLegacyPayloadWithoutTimedOut() throws {
        // Older JXA scripts omit the field entirely. Must default to false, not error.
        let json = #"{"accountsScanned":1,"mailboxesScanned":3,"messagesExamined":50}"#
        let meta = try JSONDecoder().decode(MailBridge.SearchMeta.self, from: Data(json.utf8))
        XCTAssertEqual(meta.accountsScanned, 1)
        XCTAssertFalse(meta.timedOut, "missing timedOut must default to false")
    }

    func testDecodesFullSearchResponseWrapper() throws {
        let json = """
        {
          "results": [],
          "meta": {"accountsScanned":1,"mailboxesScanned":2,"messagesExamined":10,"timedOut":true}
        }
        """
        let response = try JSONDecoder().decode(MailBridge.SearchResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.results.count, 0)
        XCTAssertTrue(response.meta.timedOut)
    }
}
