@testable import PippinLib
import XCTest

final class JSONRPCTests: XCTestCase {
    // MARK: - ID decoding

    func testDecodesStringID() throws {
        let json = #"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.id, .string("abc"))
    }

    func testDecodesIntID() throws {
        let json = #"{"jsonrpc":"2.0","id":42,"method":"ping"}"#
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.id, .int(42))
    }

    func testDecodesNotificationWithoutID() throws {
        let json = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(json.utf8))
        XCTAssertNil(request.id)
        XCTAssertTrue(request.isNotification)
    }

    // MARK: - Response encoding

    func testEncodesResultResponse() throws {
        let response = JSONRPCResponse(id: .int(1), result: .object(["ok": .bool(true)]))
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(decoded?["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(decoded?["id"] as? Int, 1)
        XCTAssertNotNil(decoded?["result"])
        XCTAssertNil(decoded?["error"])
    }

    func testEncodesErrorResponse() throws {
        let response = JSONRPCResponse(
            id: .int(2),
            error: JSONRPCError(code: JSONRPCError.methodNotFound, message: "nope")
        )
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(decoded?["result"])
        let errDict = decoded?["error"] as? [String: Any]
        XCTAssertEqual(errDict?["code"] as? Int, -32601)
        XCTAssertEqual(errDict?["message"] as? String, "nope")
    }

    // MARK: - Dispatcher

    func testDispatchInitializeReturnsCapabilities() throws {
        let json = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(json.utf8))
        let response = MCPDispatcher.handle(request, pippinPath: "/bin/echo")
        XCTAssertNotNil(response)
        let data = try JSONEncoder().encode(XCTUnwrap(response))
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let result = decoded?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2024-11-05")
        let serverInfo = result?["serverInfo"] as? [String: Any]
        XCTAssertEqual(serverInfo?["name"] as? String, "pippin")
    }

    func testDispatchToolsListReturnsAllRegisteredTools() throws {
        let json = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(json.utf8))
        let response = MCPDispatcher.handle(request, pippinPath: "/bin/echo")
        let data = try JSONEncoder().encode(XCTUnwrap(response))
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let result = decoded?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, MCPToolRegistry.tools.count)
    }

    func testDispatchToolsCallUnknownToolReturnsMethodNotFound() throws {
        let json = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"does_not_exist","arguments":{}}}"#
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(json.utf8))
        let response = MCPDispatcher.handle(request, pippinPath: "/bin/echo")
        let data = try JSONEncoder().encode(XCTUnwrap(response))
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let errDict = decoded?["error"] as? [String: Any]
        XCTAssertEqual(errDict?["code"] as? Int, JSONRPCError.methodNotFound)
    }

    func testDispatchUnknownMethodReturnsMethodNotFound() throws {
        let json = #"{"jsonrpc":"2.0","id":99,"method":"bogus/method"}"#
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(json.utf8))
        let response = MCPDispatcher.handle(request, pippinPath: "/bin/echo")
        let data = try JSONEncoder().encode(XCTUnwrap(response))
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let errDict = decoded?["error"] as? [String: Any]
        XCTAssertEqual(errDict?["code"] as? Int, JSONRPCError.methodNotFound)
    }

    func testDispatchNotificationReturnsNil() throws {
        let json = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(json.utf8))
        let response = MCPDispatcher.handle(request, pippinPath: "/bin/echo")
        XCTAssertNil(response, "Notifications must not produce a response")
    }

    func testDispatchToolsCallArgumentErrorReturnsToolResultWithIsErrorTrue() throws {
        // reminders_create requires title — send empty args, expect tool-level error.
        let json = #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"reminders_create","arguments":{}}}"#
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(json.utf8))
        let response = MCPDispatcher.handle(request, pippinPath: "/bin/echo")
        let data = try JSONEncoder().encode(XCTUnwrap(response))
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // Should be a tool-result, not a JSON-RPC-level error.
        XCTAssertNil(decoded?["error"])
        let result = decoded?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
        let content = result?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String
        XCTAssertTrue(text?.contains("title") ?? false, "Error message should name the missing field")
    }
}
