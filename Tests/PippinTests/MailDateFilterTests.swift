import JavaScriptCore
@testable import PippinLib
import XCTest

/// `--after` / `--before` name whole local days, both inclusive (DAT-11).
final class MailDateFilterTests: XCTestCase {
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let utc = TimeZone(identifier: "UTC")!

    func testBoundsCoverTheWholeLocalDay() {
        let bounds = MailBridge.dayFilterInstants(after: "2026-07-10", before: "2026-07-10", timeZone: newYork)
        XCTAssertEqual(bounds.after, "2026-07-10T04:00:00Z", "local midnight, not UTC midnight")
        XCTAssertEqual(bounds.before, "2026-07-11T03:59:59Z", "the last second of the same local day")
    }

    func testAbsentAndNonDayValuesPassThrough() {
        let none = MailBridge.dayFilterInstants(after: nil, before: nil, timeZone: utc)
        XCTAssertNil(none.after)
        XCTAssertNil(none.before)
        let odd = MailBridge.dayFilterInstants(after: "2026-07-10T04:00:00Z", before: "garbage", timeZone: utc)
        XCTAssertEqual(odd.after, "2026-07-10T04:00:00Z")
        XCTAssertEqual(odd.before, "garbage")
    }

    func testEveryReadPathParsesTheResolvedInstant() throws {
        let bounds = MailBridge.dayFilterInstants(after: "2026-07-10", before: "2026-07-10", timeZone: newYork)
        let after = try XCTUnwrap(bounds.after)
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-10T04:00:00Z"))
        XCTAssertEqual(MailEnvelopeIndex.parseFilterDateUTC(after), expected, "Envelope Index")
        XCTAssertEqual(parseCalendarDate(after), expected, "pippin's own store")
        let context = try XCTUnwrap(JSContext())
        XCTAssertEqual(
            context.evaluateScript("new Date('\(after)').getTime()").toDouble(),
            expected.timeIntervalSince1970 * 1000, "JXA"
        )
        // A bare day still parses, for callers that reach the index directly.
        XCTAssertNotNil(MailEnvelopeIndex.parseFilterDateUTC("2026-07-10"))
    }
}
