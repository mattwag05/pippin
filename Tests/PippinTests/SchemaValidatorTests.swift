@testable import PippinLib
import XCTest

final class SchemaValidatorTests: XCTestCase {
    // MARK: - Required fields

    func testMissingRequiredThrows() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("query")]),
        ])
        XCTAssertThrowsError(try SchemaValidator.validate(args: .object([:]), against: schema)) { error in
            XCTAssertEqual(error as? SchemaValidatorError, .missingRequired("query"))
        }
    }

    func testNilArgsWithRequiredThrows() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
        ])
        XCTAssertThrowsError(try SchemaValidator.validate(args: nil, against: schema)) { error in
            XCTAssertEqual(error as? SchemaValidatorError, .missingRequired("id"))
        }
    }

    func testNoRequiredPasses() throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "limit": .object(["type": .string("integer")]),
            ]),
        ])
        XCTAssertNoThrow(try SchemaValidator.validate(args: .object([:]), against: schema))
        XCTAssertNoThrow(try SchemaValidator.validate(args: nil, against: schema))
    }

    // MARK: - Type checks

    func testStringTypeMismatchThrows() {
        let schema: JSONValue = .object([
            "properties": .object([
                "query": .object(["type": .string("string")]),
            ]),
        ])
        XCTAssertThrowsError(
            try SchemaValidator.validate(
                args: .object(["query": .int(42)]), against: schema
            )
        ) { error in
            guard case let .wrongType(field, expected, got) = error as? SchemaValidatorError else {
                return XCTFail("expected wrongType, got \(error)")
            }
            XCTAssertEqual(field, "query")
            XCTAssertEqual(expected, "string")
            XCTAssertEqual(got, "integer")
        }
    }

    func testIntegerTypePasses() throws {
        let schema: JSONValue = .object([
            "properties": .object([
                "limit": .object(["type": .string("integer")]),
            ]),
        ])
        XCTAssertNoThrow(try SchemaValidator.validate(
            args: .object(["limit": .int(10)]), against: schema
        ))
    }

    func testBooleanTypeMismatchThrows() {
        let schema: JSONValue = .object([
            "properties": .object([
                "unread": .object(["type": .string("boolean")]),
            ]),
        ])
        XCTAssertThrowsError(try SchemaValidator.validate(
            args: .object(["unread": .string("yes")]), against: schema
        ))
    }

    func testArrayTypePasses() throws {
        let schema: JSONValue = .object([
            "properties": .object([
                "entries": .object(["type": .string("array")]),
            ]),
        ])
        XCTAssertNoThrow(try SchemaValidator.validate(
            args: .object(["entries": .array([.string("x")])]), against: schema
        ))
    }

    func testExtraFieldsTolerated() throws {
        // Schema doesn't declare `extra`; validator should ignore it.
        let schema: JSONValue = .object([
            "properties": .object([
                "query": .object(["type": .string("string")]),
            ]),
        ])
        XCTAssertNoThrow(try SchemaValidator.validate(
            args: .object(["query": .string("x"), "extra": .int(99)]),
            against: schema
        ))
    }

    func testUnknownTypeTagTolerated() throws {
        // If the schema uses a type tag we don't recognize, accept.
        let schema: JSONValue = .object([
            "properties": .object([
                "blob": .object(["type": .string("mystery-type")]),
            ]),
        ])
        XCTAssertNoThrow(try SchemaValidator.validate(
            args: .object(["blob": .string("anything")]), against: schema
        ))
    }

    func testNonObjectArgsThrow() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
        XCTAssertThrowsError(try SchemaValidator.validate(
            args: .array([.string("x")]), against: schema
        )) { error in
            guard case let .wrongType(field, _, got) = error as? SchemaValidatorError else {
                return XCTFail("expected wrongType, got \(error)")
            }
            XCTAssertEqual(field, "<root>")
            XCTAssertEqual(got, "array")
        }
    }

    // MARK: - Real MCP tool schemas

    func testValidatesAgainstMailSearchSchema() throws {
        let tool = try XCTUnwrap(MCPToolRegistry.tool(named: "mail_search"))
        // Missing required `query`
        XCTAssertThrowsError(try SchemaValidator.validate(
            args: .object([:]), against: tool.inputSchema
        ))
        // With `query` — passes
        XCTAssertNoThrow(try SchemaValidator.validate(
            args: .object(["query": .string("invoice")]), against: tool.inputSchema
        ))
        // `limit` with wrong type
        XCTAssertThrowsError(try SchemaValidator.validate(
            args: .object(["query": .string("x"), "limit": .string("many")]),
            against: tool.inputSchema
        ))
    }

    func testValidatesAgainstJobRunSchema() throws {
        let tool = try XCTUnwrap(MCPToolRegistry.tool(named: "job_run"))
        XCTAssertThrowsError(try SchemaValidator.validate(
            args: .object([:]), against: tool.inputSchema
        ))
        XCTAssertNoThrow(try SchemaValidator.validate(
            args: .object(["argv": .array([.string("doctor")])]),
            against: tool.inputSchema
        ))
    }
}
