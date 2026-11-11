@testable import PippinLib
import XCTest

/// `messages search --fields` must project the rows under `matches`, not the
/// result wrapper's own keys (pippin-xr89 AGT-8).
final class MessagesSearchFieldsTests: XCTestCase {
    private func render(fields: String) throws -> [String: Any] {
        let item = MessageItem(
            id: "m1", conversationId: "c1", date: "2026-01-01T00:00:00Z", text: "synthetic body",
            fromHandle: "+15550100", fromDisplayName: nil, isFromMe: false, isRead: true, service: "iMessage"
        )
        let payload = MessagesSearchResult(
            matches: [item], excludedCount: 2, query: "synthetic", scanTruncated: true, scannedAttributedCap: 500
        )
        var options = OutputOptions()
        options.fields = fields
        let json = try options.render(AgentResult(payload))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return try XCTUnwrap(envelope["data"] as? [String: Any])
            .merging(["_warnings": envelope["warnings"] ?? []]) { a, _ in a }
    }

    func testFieldsProjectMatchRowsAndKeepWrapperMetadata() throws {
        let data = try render(fields: "id,text")
        let matches = try XCTUnwrap(data["matches"] as? [[String: Any]])
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(Set(matches[0].keys), ["id", "text"])
        XCTAssertEqual(data["scan_truncated"] as? Bool, true, "scan_truncated must survive projection")
        XCTAssertEqual((data["_warnings"] as? [Any])?.count, 0, "no false 'No row has field(s)' warning")
    }
}
