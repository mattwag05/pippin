@testable import PippinLib
import XCTest

final class JSONValueTests: XCTestCase {
    // MARK: - intValue coercion

    func testIntValueFromInt() {
        XCTAssertEqual(JSONValue.int(42).intValue, 42)
        XCTAssertEqual(JSONValue.int(0).intValue, 0)
        XCTAssertEqual(JSONValue.int(-7).intValue, -7)
    }

    func testIntValueFromInRangeDoubleTruncates() {
        XCTAssertEqual(JSONValue.double(5.0).intValue, 5)
        XCTAssertEqual(JSONValue.double(5.7).intValue, 5, "fractional doubles truncate toward zero")
        XCTAssertEqual(JSONValue.double(1e18).intValue, Int64(1e18))
    }

    func testIntValueFromNonNumberIsNil() {
        XCTAssertNil(JSONValue.string("5").intValue, "a numeric string is not coerced")
        XCTAssertNil(JSONValue.bool(true).intValue)
        XCTAssertNil(JSONValue.null.intValue)
    }

    // MARK: - intValue overflow guard (regression)

    //
    // A JSON number larger than Int64 decodes as `.double`; `Int64(Double)`
    // traps for non-finite / out-of-range values. An MCP arg like
    // `{"limit": 1e19}` must yield nil (treated as absent), never crash.

    func testIntValueOutOfRangeDoubleReturnsNilNotTrap() {
        XCTAssertNil(JSONValue.double(1e19).intValue, "above Int64.max")
        XCTAssertNil(JSONValue.double(-1e19).intValue, "below Int64.min")
        XCTAssertNil(JSONValue.double(.infinity).intValue)
        XCTAssertNil(JSONValue.double(-.infinity).intValue)
        XCTAssertNil(JSONValue.double(.nan).intValue)
        XCTAssertNil(JSONValue.double(Double(Int64.max)).intValue, "Int64.max rounds up as Double — out of range")
    }

    func testHugeJSONNumberDecodesToDoubleAndIntValueDoesNotTrap() throws {
        // End-to-end: the MCP arg path is decode(JSONValue) → intValue.
        for literal in ["1e19", "99999999999999999999", "-1e19"] {
            let obj = try JSONDecoder().decode(JSONValue.self, from: Data("{\"limit\": \(literal)}".utf8))
            XCTAssertNil(obj["limit"]?.intValue, "huge literal \(literal) must coerce to nil, not crash")
        }
    }

    func testReasonableJSONIntegerStillDecodesAndCoerces() throws {
        let obj = try JSONDecoder().decode(JSONValue.self, from: Data("{\"limit\": 50}".utf8))
        XCTAssertEqual(obj["limit"]?.intValue, 50)
    }

    // MARK: - other accessors

    func testStringAndBoolAccessors() {
        XCTAssertEqual(JSONValue.string("hi").stringValue, "hi")
        XCTAssertNil(JSONValue.int(1).stringValue)
        XCTAssertEqual(JSONValue.bool(true).boolValue, true)
        XCTAssertNil(JSONValue.string("true").boolValue, "a string is not coerced to Bool")
    }

    func testSubscriptOnlyWorksOnObjects() {
        XCTAssertEqual(JSONValue.object(["a": .int(1)])["a"], .int(1))
        XCTAssertNil(JSONValue.object(["a": .int(1)])["missing"])
        XCTAssertNil(JSONValue.array([.int(1)])["a"], "subscript on a non-object is nil")
    }
}
