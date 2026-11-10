@testable import PippinLib
import XCTest

/// `pippin mcp-server --apps`: a client sees and can call only the named groups.
final class AppFilterTests: XCTestCase {
    private func call(_ json: String, apps: Set<String>?) async throws -> [String: Any] {
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(json.utf8))
        let response = await MCPDispatcher.handle(request, pippinPath: "/bin/echo", apps: apps)
        let encoded = try JSONEncoder().encode(XCTUnwrap(response))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    }

    func testListShowsOnlyTheNamedGroups() async throws {
        let root = try await call(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, apps: ["notes", "reminders"])
        let tools = try XCTUnwrap((root["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertFalse(names.isEmpty)
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("notes_") || $0.hasPrefix("reminders_") }, "\(names)")
    }

    func testAHiddenToolCannotBeCalled() async throws {
        let json = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"mail_send","arguments":{}}}"#
        let root = try await call(json, apps: ["notes"])
        XCTAssertEqual((root["error"] as? [String: Any])?["code"] as? Int, JSONRPCError.methodNotFound)
    }

    func testNoFilterShowsEveryTool() async throws {
        let root = try await call(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, apps: nil)
        let tools = try XCTUnwrap((root["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, MCPToolRegistry.tools.count)
    }

    func testAnUnknownGroupIsRefused() {
        XCTAssertThrowsError(try McpServerCommand.parse(["--apps", "notes,nope"]))
        XCTAssertNoThrow(try McpServerCommand.parse(["--apps", "notes, calendar"]))
    }
}
