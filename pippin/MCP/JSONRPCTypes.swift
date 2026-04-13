import Foundation

// JSON-RPC 2.0 envelope types scoped to the MCP subset pippin actually handles.
// Kept deliberately small — only the fields we read and write.

// MARK: - RPC ID

/// JSON-RPC IDs may be strings, numbers, or null. We preserve whichever form arrived
/// so the response echoes the same shape back to the client.
enum JSONRPCID: Codable, Equatable {
    case string(String)
    case int(Int64)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "JSON-RPC id must be string, number, or null"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - Request

struct JSONRPCRequest: Decodable {
    let jsonrpc: String
    let id: JSONRPCID?
    let method: String
    let params: JSONValue?

    enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decodeIfPresent(String.self, forKey: .jsonrpc) ?? "2.0"
        id = try container.decodeIfPresent(JSONRPCID.self, forKey: .id)
        method = try container.decode(String.self, forKey: .method)
        params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
    }

    /// Is this a JSON-RPC notification (no id field)?
    var isNotification: Bool {
        id == nil
    }
}

// MARK: - Response

struct JSONRPCResponse: Encodable {
    let jsonrpc: String
    let id: JSONRPCID
    let result: JSONValue?
    let error: JSONRPCError?

    init(id: JSONRPCID, result: JSONValue) {
        jsonrpc = "2.0"
        self.id = id
        self.result = result
        error = nil
    }

    init(id: JSONRPCID, error: JSONRPCError) {
        jsonrpc = "2.0"
        self.id = id
        result = nil
        self.error = error
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        if let result {
            try container.encode(result, forKey: .result)
        }
        if let error {
            try container.encode(error, forKey: .error)
        }
    }

    enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result, error
    }
}

struct JSONRPCError: Encodable {
    let code: Int
    let message: String
    let data: JSONValue?

    init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    // Standard JSON-RPC 2.0 error codes.
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
}

// MARK: - MCP-specific payloads

/// `initialize` response payload.
struct MCPInitializeResult: Encodable {
    struct ServerInfo: Encodable {
        let name: String
        let version: String
    }

    struct Capabilities: Encodable {
        struct ToolsCapability: Encodable {
            let listChanged: Bool
        }

        let tools: ToolsCapability
    }

    let protocolVersion: String
    let capabilities: Capabilities
    let serverInfo: ServerInfo
}

/// `tools/list` response payload.
struct MCPToolsListResult: Encodable {
    let tools: [MCPToolDescriptor]
}

/// Public-facing tool description sent to clients via `tools/list`.
struct MCPToolDescriptor: Encodable {
    let name: String
    let description: String
    let inputSchema: JSONValue
}

/// `tools/call` response payload.
struct MCPToolCallResult: Encodable {
    struct Content: Encodable {
        let type: String
        let text: String

        init(text: String) {
            type = "text"
            self.text = text
        }
    }

    let content: [Content]
    let isError: Bool

    init(text: String, isError: Bool = false) {
        content = [Content(text: text)]
        self.isError = isError
    }
}
