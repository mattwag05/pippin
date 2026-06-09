@testable import PippinLib
import XCTest

/// Tests for decoding Messages `attributedBody` typedstream blobs and resolving
/// message body text (pippin-cc1). Modern macOS leaves `message.text` NULL and
/// stores the body in `attributedBody` as an NSArchiver typedstream.
final class MessagesAttributedBodyTests: XCTestCase {
    /// A real typedstream (NSArchiver) archive of a *synthetic* NSAttributedString
    /// "Hello, typedstream world! 🌍" — same on-disk format as chat.db's
    /// attributedBody (header `\x04\x0bstreamtyped…`), but no real message data.
    private static let goldenBlobBase64 =
        "BAtzdHJlYW10eXBlZIHoA4QBQISEhBJOU0F0dHJpYnV0ZWRTdHJpbmcAhIQITlNPYmplY3QAhZKEhIQI" +
        "TlNTdHJpbmcBlIQBKx5IZWxsbywgdHlwZWRzdHJlYW0gd29ybGQhIPCfjI2GhAJpSQEckoSEhAxOU0Rp" +
        "Y3Rpb25hcnkAlIQBaQCGhg=="

    func testDecodesTypedstreamAttributedBodyToPlainText() throws {
        let blob = try XCTUnwrap(Data(base64Encoded: Self.goldenBlobBase64))
        // text NULL + real blob → decode the blob.
        let resolved = MessagesDatabase.resolveBody(text: nil, attributedBody: blob)
        XCTAssertEqual(resolved, "Hello, typedstream world! 🌍")
    }

    func testPrefersTextColumnWhenPresent() throws {
        // A populated text column wins; the blob isn't even consulted.
        let blob = try XCTUnwrap(Data(base64Encoded: Self.goldenBlobBase64))
        XCTAssertEqual(
            MessagesDatabase.resolveBody(text: "plain text body", attributedBody: blob),
            "plain text body"
        )
        // Empty string is treated as absent → falls through to the blob.
        XCTAssertEqual(
            MessagesDatabase.resolveBody(text: "", attributedBody: blob),
            "Hello, typedstream world! 🌍"
        )
    }

    func testNoTextAndNoBlobIsNil() {
        XCTAssertNil(MessagesDatabase.resolveBody(text: nil, attributedBody: nil))
        XCTAssertNil(MessagesDatabase.resolveBody(text: "", attributedBody: nil))
        XCTAssertNil(MessagesDatabase.resolveBody(text: nil, attributedBody: Data()))
    }

    func testMalformedBlobDoesNotCrashAndReturnsNil() {
        // The ObjC shim must contain the NSException NSUnarchiver raises on junk.
        let junk = Data([0x04, 0x0B, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6D, 0xFF, 0xFF, 0xFF])
        XCTAssertNil(MessagesDatabase.resolveBody(text: nil, attributedBody: junk))
        XCTAssertNil(MessagesDatabase.resolveBody(text: nil, attributedBody: Data([0x00, 0x01, 0x02])))
    }

    func testCleanDecodedBodyStripsAttachmentMarkersAndTrims() {
        // U+FFFC (object replacement) marks inline attachments — strip them.
        XCTAssertNil(MessagesDatabase.cleanDecodedBody("\u{FFFC}"))
        XCTAssertNil(MessagesDatabase.cleanDecodedBody("  \u{FFFC} \n"))
        XCTAssertEqual(MessagesDatabase.cleanDecodedBody("look \u{FFFC}"), "look")
        XCTAssertEqual(MessagesDatabase.cleanDecodedBody("  hi there  "), "hi there")
        XCTAssertNil(MessagesDatabase.cleanDecodedBody(""))
    }
}
