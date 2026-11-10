@testable import PippinLib
import XCTest

/// RT-20 / RT-21: a NUL in an argument used to abort the whole process with an
/// uncaught NSInvalidArgumentException, because an argv string cannot hold one.
final class NULArgumentTests: XCTestCase {
    private func call(_ json: String) async throws -> [String: Any] {
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(json.utf8))
        // `/bin/echo` stands in for pippin: a call that got through would print its argv.
        let response = await MCPDispatcher.handle(request, pippinPath: "/bin/echo")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(response))) as? [String: Any])
        return try XCTUnwrap(root["result"] as? [String: Any])
    }

    private func errorCode(_ result: [String: Any]) throws -> String? {
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return (envelope["error"] as? [String: Any])?["code"] as? String
    }

    func testNULInAnyStringArgumentIsATypedErrorAndTheServerKeepsAnswering() async throws {
        let calls = [
            #"{"name":"notes_search","arguments":{"query":"a\u0000b"}}"#,
            #"{"name":"notes_create","arguments":{"title":"t","body":"x\u0000"}}"#,
            #"{"name":"job_show","arguments":{"id":"\u0000"}}"#,
            #"{"name":"mail_show","arguments":{"messageIds":["a||b||1","a||b||\u00002"]}}"#,
            #"{"name":"batch","arguments":{"entries":[{"cmd":"notes","args":["show","a\u0000b"]}]}}"#,
        ]
        for params in calls {
            let result = try await call(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":\#(params)}"#)
            XCTAssertEqual(try errorCode(result), "invalid_argument", params)
        }
        let later = try await call(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        XCTAssertEqual((later["tools"] as? [[String: Any]])?.count, MCPToolRegistry.tools.count)
    }

    func testRunChildRefusesNULInsteadOfTruncatingTheArgument() {
        XCTAssertThrowsError(try MCPServerRuntime.runChild(argv: ["show", "a\0b"], pippinPath: "/bin/echo")) { error in
            guard case MCPServerRuntimeError.nulInArgument = error else {
                return XCTFail("expected nulInArgument, got \(error)")
            }
        }
    }

    /// The CLI path: `pippin batch --entries` never passes the MCP validator.
    func testBatchEntryWithNULGetsItsOwnErrorAndTheOthersRun() {
        let bad = BatchCommand.runOne(entry: BatchEntry(cmd: "notes", args: ["show", "a\0b"]), pippinPath: "/bin/echo", underMCP: false)
        XCTAssertEqual(bad["error"]?["code"]?.stringValue, "invalid_argument")
        let good = BatchCommand.runOne(entry: BatchEntry(cmd: "notes", args: ["show", "ab"]), pippinPath: "/bin/echo", underMCP: false)
        XCTAssertEqual(good["error"]?["code"]?.stringValue, "invalid_json", "echo printed the argv, so the entry ran")
    }
}
