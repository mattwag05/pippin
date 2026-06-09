@testable import PippinLib
import XCTest

/// Tests for the handle→contact-name reverse index that ties messages/mail
/// senders to Apple Contacts. Pure (built via `add`, no CNContactStore).
final class ContactIndexTests: XCTestCase {
    func testEmptyByDefault() {
        XCTAssertTrue(ContactIndex().isEmpty)
        XCTAssertNil(ContactIndex().displayName(for: "a@b.com"))
    }

    func testEmailMatchIsCaseInsensitive() {
        var idx = ContactIndex()
        idx.add(name: "Alice Smith", phones: [], emails: ["Alice@Example.com"])
        XCTAssertFalse(idx.isEmpty)
        XCTAssertEqual(idx.displayName(for: "alice@example.com"), "Alice Smith")
        XCTAssertEqual(idx.displayName(for: "ALICE@EXAMPLE.COM"), "Alice Smith")
        XCTAssertNil(idx.displayName(for: "bob@example.com"))
    }

    func testEmailUnwrapsHeaderAndMailto() {
        var idx = ContactIndex()
        idx.add(name: "Alice", phones: [], emails: ["alice@example.com"])
        // "Name <addr>" header form and mailto: prefix both resolve.
        XCTAssertEqual(idx.displayName(for: "Alice Smith <alice@example.com>"), "Alice")
        XCTAssertEqual(idx.displayName(for: "mailto:alice@example.com"), "Alice")
    }

    func testPhoneNormalizationAcrossFormats() {
        var idx = ContactIndex()
        // Contact stored in free-form local format.
        idx.add(name: "Bob Jones", phones: ["(513) 267-1812"], emails: [])
        // Handle arrives E.164 with country code — last-10 bridges it.
        XCTAssertEqual(idx.displayName(for: "+15132671812"), "Bob Jones")
        XCTAssertEqual(idx.displayName(for: "513-267-1812"), "Bob Jones")
        XCTAssertEqual(idx.displayName(for: "5132671812"), "Bob Jones")
        XCTAssertNil(idx.displayName(for: "+19998887777"))
    }

    func testPhoneStoredWithCountryCodeMatchesBothWays() {
        var idx = ContactIndex()
        idx.add(name: "Carol", phones: ["+1 (513) 267-1812"], emails: [])
        XCTAssertEqual(idx.displayName(for: "+15132671812"), "Carol") // exact full-digits
        XCTAssertEqual(idx.displayName(for: "5132671812"), "Carol") // last-10 of stored
    }

    func testFirstWriteWinsOnCollision() {
        var idx = ContactIndex()
        idx.add(name: "Alice", phones: [], emails: ["shared@example.com"])
        idx.add(name: "Bob", phones: [], emails: ["shared@example.com"])
        XCTAssertEqual(idx.displayName(for: "shared@example.com"), "Alice")
    }

    func testBlankNameAndJunkHandlesIgnored() {
        var idx = ContactIndex()
        idx.add(name: "   ", phones: ["5132671812"], emails: ["x@y.com"]) // blank name → skipped
        XCTAssertTrue(idx.isEmpty)
        idx.add(name: "Dave", phones: ["not-a-number"], emails: [])
        XCTAssertNil(idx.displayName(for: "")) // empty handle
        XCTAssertNil(idx.displayName(for: "+10000000000"))
    }
}
