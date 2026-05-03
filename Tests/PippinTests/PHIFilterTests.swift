@testable import PippinLib
import XCTest

final class PHIFilterTests: XCTestCase {
    func testCleanBodyPasses() {
        let result = PHIFilter.scan("Hey, are we still on for lunch at 1?")
        XCTAssertTrue(result.isClean)
        XCTAssertTrue(result.flagged.isEmpty)
    }

    func testFlagsSSN() {
        let result = PHIFilter.scan("My SSN is 123-45-6789 please don't share")
        XCTAssertTrue(result.flagged.contains("ssn"))
    }

    func testFlagsCreditCard() {
        let result = PHIFilter.scan("Card: 4111 1111 1111 1111 expires 12/30")
        XCTAssertTrue(result.flagged.contains("credit_card"))
    }

    func testFlagsAPIKey() {
        let result = PHIFilter.scan("token: sk-abc123def456ghi789jkl012mno345")
        XCTAssertTrue(result.flagged.contains("api_key"))
    }

    func testFlagsPrivateKeyBlock() {
        let result = PHIFilter.scan("-----BEGIN RSA PRIVATE KEY-----\nMIIEow...")
        XCTAssertTrue(result.flagged.contains("private_key_block"))
    }

    func testFlagsPasswordMention() {
        let result = PHIFilter.scan("password: hunter2")
        XCTAssertTrue(result.flagged.contains("password_mention"))
    }

    func testMultipleCategoriesReported() {
        let result = PHIFilter.scan("SSN 111-22-3333 and password=foo")
        XCTAssertTrue(result.flagged.contains("ssn"))
        XCTAssertTrue(result.flagged.contains("password_mention"))
    }
}
