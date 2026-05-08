@testable import PippinLib
import XCTest

/// Tests for `MailBridge.ActivityMeta` JSON decoding. Mirrors `ListMeta` —
/// activity lives behind the same soft-timeout fix and must decode legacy
/// payloads (no `timedOut`) without erroring.
final class MailBridgeActivityMetaTests: XCTestCase {
    func testDecodesNewPayloadWithTimedOutFalse() throws {
        let json = #"{"accountsScanned":1,"mailboxesScanned":2,"messagesExamined":80,"timedOut":false}"#
        let meta = try JSONDecoder().decode(MailBridge.ActivityMeta.self, from: Data(json.utf8))
        XCTAssertEqual(meta.accountsScanned, 1)
        XCTAssertEqual(meta.mailboxesScanned, 2)
        XCTAssertEqual(meta.messagesExamined, 80)
        XCTAssertFalse(meta.timedOut)
    }

    func testDecodesNewPayloadWithTimedOutTrue() throws {
        let json = #"{"accountsScanned":3,"mailboxesScanned":6,"messagesExamined":900,"timedOut":true}"#
        let meta = try JSONDecoder().decode(MailBridge.ActivityMeta.self, from: Data(json.utf8))
        XCTAssertTrue(meta.timedOut)
    }

    func testDecodesLegacyPayloadWithoutTimedOut() throws {
        let json = #"{"accountsScanned":1,"mailboxesScanned":2,"messagesExamined":40}"#
        let meta = try JSONDecoder().decode(MailBridge.ActivityMeta.self, from: Data(json.utf8))
        XCTAssertEqual(meta.mailboxesScanned, 2)
        XCTAssertFalse(meta.timedOut, "missing timedOut must default to false")
    }

    func testDecodesFullActivityResponseWrapper() throws {
        let json = """
        {
          "results": [],
          "meta": {"accountsScanned":2,"mailboxesScanned":4,"messagesExamined":200,"timedOut":true}
        }
        """
        let response = try JSONDecoder().decode(MailBridge.ActivityResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.results.count, 0)
        XCTAssertTrue(response.meta.timedOut)
    }
}
