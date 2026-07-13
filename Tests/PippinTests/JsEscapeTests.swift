@testable import PippinLib
import XCTest

final class JsEscapeTests: XCTestCase {
    // MARK: - Backslash (must be escaped first)

    func testBackslash() {
        XCTAssertEqual(jsEscape("a\\b"), "a\\\\b")
    }

    func testBackslashDouble() {
        XCTAssertEqual(jsEscape("\\\\"), "\\\\\\\\")
    }

    // MARK: - Null byte

    func testNullByte() {
        XCTAssertEqual(jsEscape("a\0b"), "a\\0b")
    }

    // MARK: - Quotes

    func testDoubleQuote() {
        XCTAssertEqual(jsEscape("say \"hi\""), "say \\\"hi\\\"")
    }

    func testSingleQuote() {
        XCTAssertEqual(jsEscape("it's"), "it\\'s")
    }

    func testBacktick() {
        XCTAssertEqual(jsEscape("`cmd`"), "\\`cmd\\`")
    }

    // MARK: - Newlines / line terminators

    func testNewline() {
        XCTAssertEqual(jsEscape("a\nb"), "a\\nb")
    }

    func testCarriageReturn() {
        XCTAssertEqual(jsEscape("a\rb"), "a\\rb")
    }

    func testLineSeparator() {
        XCTAssertEqual(jsEscape("a\u{2028}b"), "a\\u2028b")
    }

    func testParagraphSeparator() {
        XCTAssertEqual(jsEscape("a\u{2029}b"), "a\\u2029b")
    }

    // MARK: - Edge cases

    func testEmptyString() {
        XCTAssertEqual(jsEscape(""), "")
    }

    func testNoSpecialChars() {
        XCTAssertEqual(jsEscape("hello world"), "hello world")
    }

    func testAllSpecialCombined() {
        // Backslash must be doubled before other escapes are applied
        let input = "\\\0\"'`\n\r\u{2028}\u{2029}"
        // Build expected: \ → \\, \0 → \0, " → \", ' → \', ` → \`, \n → \n, \r → \r, U+2028 → \u2028, U+2029 → \u2029
        let expected = "\\\\" + "\\0" + "\\\"" + "\\'" + "\\`" + "\\n" + "\\r" + "\\u2028" + "\\u2029"
        XCTAssertEqual(jsEscape(input), expected)
    }

    // MARK: - Order of escaping (backslash first prevents double-escaping)

    func testBackslashNotDoubleEscaped() {
        // If we have a literal backslash followed by n, it should become \\n (backslash + n),
        // NOT \\n interpreted as newline escape.
        // Input: "\" + "n" (two chars) → "\\n" (two chars, escaped backslash + n)
        let input = "\\n" // Swift string: one backslash + n
        let result = jsEscape(input)
        // Should be "\\" + "n" = escaped backslash followed by n
        XCTAssertEqual(result, "\\\\n")
    }
}
