@testable import PippinLib
import XCTest

/// Unit tests for the shared `--fields` projector. The per-model `jsonData`
/// helpers and the agent-mode envelope both delegate here, so these guard the
/// one place projection logic lives.
final class FieldProjectionTests: XCTestCase {
    // MARK: - parse

    func testParseTrimsAndDropsBlanks() {
        XCTAssertEqual(FieldProjection.parse("id, title ,, body"), ["id", "title", "body"])
        XCTAssertNil(FieldProjection.parse(nil))
        XCTAssertNil(FieldProjection.parse(""))
        XCTAssertNil(FieldProjection.parse("  ,  "))
    }

    // MARK: - project shapes

    func testProjectArrayOfObjects() {
        let input: [Any] = [
            ["id": "1", "title": "a", "body": "x"],
            ["id": "2", "title": "b", "body": "y"],
        ]
        let out = FieldProjection.project(input, fields: ["id", "title"]) as? [[String: Any]]
        XCTAssertEqual(out?.count, 2)
        XCTAssertEqual(out?[0].keys.sorted(), ["id", "title"])
        XCTAssertEqual(out?[1]["title"] as? String, "b")
        XCTAssertNil(out?[0]["body"])
    }

    func testProjectPaginatedPageKeepsSiblingsProjectsItems() {
        let page: [String: Any] = [
            "items": [["id": "1", "body": "x"], ["id": "2", "body": "y"]],
            "next_cursor": "tok",
        ]
        let out = FieldProjection.project(page, fields: ["id"]) as? [String: Any]
        XCTAssertEqual(out?["next_cursor"] as? String, "tok", "sibling keys must be preserved")
        let items = out?["items"] as? [[String: Any]]
        XCTAssertEqual(items?.count, 2)
        XCTAssertEqual(items?[0].keys.sorted(), ["id"])
    }

    func testProjectPlainObject() {
        let obj: [String: Any] = ["id": "1", "title": "a", "body": "x"]
        let out = FieldProjection.project(obj, fields: ["title"]) as? [String: Any]
        XCTAssertEqual(out?.keys.sorted(), ["title"])
    }

    func testProjectMissingFieldOmitted() {
        let obj: [String: Any] = ["id": "1"]
        let out = FieldProjection.project(obj, fields: ["id", "nope"]) as? [String: Any]
        XCTAssertEqual(out?.keys.sorted(), ["id"], "unknown fields are silently dropped, not null")
    }

    func testProjectScalarUnchanged() {
        XCTAssertEqual(FieldProjection.project("scalar", fields: ["x"]) as? String, "scalar")
    }

    // MARK: - projectedObject (encode + project)

    func testProjectedObjectEncodesThenProjects() throws {
        struct Item: Encodable { let id: String; let title: String; let body: String }
        let items = [Item(id: "1", title: "a", body: "x")]
        let projected = try FieldProjection.projectedObject(items, fields: ["id", "title"]) as? [[String: Any]]
        XCTAssertEqual(projected?[0].keys.sorted(), ["id", "title"])
    }
}
