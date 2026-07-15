@testable import PippinLib
import XCTest

/// Tests for `NotesBridge.Outcome<T>` JSON decoding. The `meta.timedOut`
/// field was added with the soft-timeout fix; older script payloads (or any
/// future script that omits `meta`) must still decode cleanly with `timedOut`
/// defaulting to `false`.
final class NotesBridgeOutcomeDecodingTests: XCTestCase {
    func testDecodeNewPayloadWithTimedOutFalse() throws {
        let json = """
        {
          "results": [],
          "meta": {"timedOut": false}
        }
        """
        let outcome = try JSONDecoder().decode(NotesBridge.Outcome<[NoteFolder]>.self, from: Data(json.utf8))
        XCTAssertFalse(outcome.timedOut)
        XCTAssertEqual(outcome.results.count, 0)
    }

    func testDecodeNewPayloadWithTimedOutTrue() throws {
        let json = """
        {
          "results": [
            {"id":"x-coredata://abc/ICFolder/p1","name":"Work","account":null,"noteCount":42}
          ],
          "meta": {"timedOut": true}
        }
        """
        let outcome = try JSONDecoder().decode(NotesBridge.Outcome<[NoteFolder]>.self, from: Data(json.utf8))
        XCTAssertTrue(outcome.timedOut)
        XCTAssertEqual(outcome.results.count, 1)
        XCTAssertEqual(outcome.results.first?.name, "Work")
    }

    func testDecodeLegacyPayloadWithoutMetaDefaultsTimedOutFalse() throws {
        // Backward-compat: any payload without `meta` should still decode.
        let json = """
        {"results": []}
        """
        let outcome = try JSONDecoder().decode(NotesBridge.Outcome<[NoteFolder]>.self, from: Data(json.utf8))
        XCTAssertFalse(outcome.timedOut)
    }

    func testDecodeMetaWithoutTimedOutDefaultsFalse() throws {
        // Future-proof: meta object present but missing the field.
        let json = """
        {"results": [], "meta": {}}
        """
        let outcome = try JSONDecoder().decode(NotesBridge.Outcome<[NoteFolder]>.self, from: Data(json.utf8))
        XCTAssertFalse(outcome.timedOut)
    }

    func testDecodeOutcomeWithNotesArray() throws {
        // List/search payloads carry no `body` (never fetched) and use the
        // envelope-v2 date keys `createdAt`/`modifiedAt`.
        let json = """
        {
          "results": [
            {
              "id": "x-coredata://abc/ICNote/p1",
              "title": "T",
              "plainText": "B",
              "folder": "F",
              "folderId": "x-coredata://abc/ICFolder/p1",
              "account": null,
              "createdAt": "2026-01-01T00:00:00.000Z",
              "modifiedAt": "2026-01-02T00:00:00.000Z"
            }
          ],
          "meta": {"timedOut": true}
        }
        """
        let outcome = try JSONDecoder().decode(NotesBridge.Outcome<[NoteInfo]>.self, from: Data(json.utf8))
        XCTAssertTrue(outcome.timedOut)
        XCTAssertEqual(outcome.results.first?.title, "T")
        XCTAssertNil(outcome.results.first?.body, "body is absent from list/search payloads")
        XCTAssertEqual(outcome.results.first?.creationDate, "2026-01-01T00:00:00.000Z")
        XCTAssertEqual(outcome.results.first?.modificationDate, "2026-01-02T00:00:00.000Z")
    }
}
