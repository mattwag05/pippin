@testable import PippinLib
import XCTest

/// Unit tests for the `mail list --preview` body-cache assembly
/// (`MailBridge.assemblePreviews` / `bodyPreview` / `buildBatchBodiesScript`).
/// Uses a temp-file cache + a stub fetcher closure, so they run without Mail.app
/// (CI-safe).
final class MailBridgePreviewAssemblyTests: XCTestCase {
    private var dbPath: String!
    private var cache: MailBodyCache!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "mail-preview-test-\(UUID().uuidString).db"
        cache = try MailBodyCache(dbPath: dbPath)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    /// A live metadata row as `listMessages(preview: nil)` returns it: body nil,
    /// no preview yet.
    private func metaRow(id: String, read: Bool = false) -> MailMessage {
        MailMessage(
            id: id, account: "iCloud", mailbox: "INBOX",
            subject: "Subj \(id)", from: "a@b.com", to: ["c@d.com"],
            date: "2026-06-03T12:00:00Z", read: read, body: nil
        )
    }

    /// A fully-fetched message as the batch fetch / cache returns it: body set.
    private func fullMessage(id: String, body: String, read: Bool = false) -> MailMessage {
        MailMessage(
            id: id, account: "iCloud", mailbox: "INBOX",
            subject: "Subj \(id)", from: "a@b.com", to: ["c@d.com"],
            date: "2026-06-03T12:00:00Z", read: read, body: body,
            htmlBody: "<p>\(body)</p>", headers: ["X-Test": "1"]
        )
    }

    // MARK: - bodyPreview truncation helper

    func testBodyPreviewShortBodyNotTruncated() {
        XCTAssertEqual(MailBridge.bodyPreview("hi", chars: 10), "hi")
    }

    func testBodyPreviewExactBoundaryNotTruncated() {
        // length == chars → no ellipsis (JXA: s.length > N is false).
        XCTAssertEqual(MailBridge.bodyPreview("12345", chars: 5), "12345")
    }

    func testBodyPreviewTruncatesWithEllipsis() {
        XCTAssertEqual(MailBridge.bodyPreview("123456789", chars: 5), "12345…")
    }

    func testBodyPreviewUtf16Semantics() {
        // "🎉" is one Character but two UTF-16 code units, matching JS substring.
        // A 5-unit cut of "🎉🎉🎉" (6 units) keeps 2.5 emoji worth of units; the
        // helper must operate on UTF-16 units, not Characters, to match JXA.
        let body = "🎉🎉🎉" // 3 chars, 6 UTF-16 units
        let expected = String(decoding: Array(body.utf16).prefix(5), as: UTF16.self) + "…"
        XCTAssertEqual(MailBridge.bodyPreview(body, chars: 5), expected)
    }

    // MARK: - assemblePreviews

    func testAllHitsDeriveFromCacheAndSkipFetch() {
        cache.put(fullMessage(id: "iCloud||INBOX||1", body: "first body"))
        cache.put(fullMessage(id: "iCloud||INBOX||2", body: "second body"))
        let meta = [metaRow(id: "iCloud||INBOX||1"), metaRow(id: "iCloud||INBOX||2")]

        var capturedIds: [String]?
        let result = MailBridge.assemblePreviews(
            metadata: meta, previewChars: 5, cache: cache,
            fetchMisses: { ids in capturedIds = ids; return (messages: [], timedOut: false) }
        )

        XCTAssertEqual(capturedIds, [], "all hits → fetcher gets an empty id list")
        XCTAssertEqual(result.messages.map(\.bodyPreview), ["first…", "secon…"])
        XCTAssertFalse(result.fetchTimedOut)
    }

    func testAllMissesFetchAndWriteThrough() {
        let meta = [metaRow(id: "iCloud||INBOX||1"), metaRow(id: "iCloud||INBOX||2")]
        XCTAssertEqual(cache.count(), 0)

        var capturedIds: [String]?
        let result = MailBridge.assemblePreviews(
            metadata: meta, previewChars: 100, cache: cache,
            fetchMisses: { ids in
                capturedIds = ids
                return (messages: [
                    self.fullMessage(id: "iCloud||INBOX||1", body: "alpha"),
                    self.fullMessage(id: "iCloud||INBOX||2", body: "beta"),
                ], timedOut: false)
            }
        )

        XCTAssertEqual(capturedIds, ["iCloud||INBOX||1", "iCloud||INBOX||2"])
        XCTAssertEqual(result.messages.map(\.bodyPreview), ["alpha", "beta"])
        XCTAssertEqual(cache.count(), 2, "fresh bodies written through")
        XCTAssertEqual(cache.get(compoundId: "iCloud||INBOX||1")?.body, "alpha")
    }

    func testMixedHitsAndMissesPreserveOrder() {
        cache.put(fullMessage(id: "iCloud||INBOX||2", body: "cached-two"))
        let meta = [
            metaRow(id: "iCloud||INBOX||1"),
            metaRow(id: "iCloud||INBOX||2"),
            metaRow(id: "iCloud||INBOX||3"),
        ]

        var capturedIds: [String]?
        let result = MailBridge.assemblePreviews(
            metadata: meta, previewChars: 100, cache: cache,
            fetchMisses: { ids in
                capturedIds = ids
                return (messages: [
                    self.fullMessage(id: "iCloud||INBOX||1", body: "fresh-one"),
                    self.fullMessage(id: "iCloud||INBOX||3", body: "fresh-three"),
                ], timedOut: false)
            }
        )

        XCTAssertEqual(capturedIds, ["iCloud||INBOX||1", "iCloud||INBOX||3"], "only misses fetched")
        XCTAssertEqual(result.messages.map(\.bodyPreview), ["fresh-one", "cached-two", "fresh-three"])
    }

    func testLiveMetadataReadFlagNotOverwrittenByCache() {
        // Cache holds a stale read=true snapshot; the live metadata row says
        // read=false. The output must keep the live (false) flag.
        cache.put(fullMessage(id: "iCloud||INBOX||1", body: "body", read: true))
        let meta = [metaRow(id: "iCloud||INBOX||1", read: false)]

        let result = MailBridge.assemblePreviews(
            metadata: meta, previewChars: 100, cache: cache,
            fetchMisses: { _ in (messages: [], timedOut: false) }
        )

        XCTAssertEqual(result.messages.first?.read, false, "live read flag preserved")
        XCTAssertEqual(result.messages.first?.bodyPreview, "body", "only body borrowed from cache")
        XCTAssertNil(result.messages.first?.body, "list output keeps body nil; preview carries the text")
    }

    func testUnreachedMissGetsNoPreview() {
        // Fetch timed out before reaching the second id → it's absent from the
        // returned set and must end up with no bodyPreview (no crash).
        let meta = [metaRow(id: "iCloud||INBOX||1"), metaRow(id: "iCloud||INBOX||2")]
        let result = MailBridge.assemblePreviews(
            metadata: meta, previewChars: 100, cache: cache,
            fetchMisses: { _ in
                (messages: [self.fullMessage(id: "iCloud||INBOX||1", body: "only-one")], timedOut: true)
            }
        )

        XCTAssertEqual(result.messages[0].bodyPreview, "only-one")
        XCTAssertNil(result.messages[1].bodyPreview)
        XCTAssertTrue(result.fetchTimedOut)
    }

    func testNoCacheTreatsEveryRowAsMiss() {
        // Even with bodies in the cache, cache: nil forces every id into the
        // fetch set (the --no-cache path).
        cache.put(fullMessage(id: "iCloud||INBOX||1", body: "should-be-ignored"))
        let meta = [metaRow(id: "iCloud||INBOX||1"), metaRow(id: "iCloud||INBOX||2")]

        var capturedIds: [String]?
        let result = MailBridge.assemblePreviews(
            metadata: meta, previewChars: 100, cache: nil,
            fetchMisses: { ids in
                capturedIds = ids
                return (messages: [self.fullMessage(id: "iCloud||INBOX||1", body: "live-one")], timedOut: false)
            }
        )

        XCTAssertEqual(capturedIds, ["iCloud||INBOX||1", "iCloud||INBOX||2"])
        XCTAssertEqual(result.messages[0].bodyPreview, "live-one")
    }

    func testCachedEmptyBodyTreatedAsMiss() {
        // A cached entry with an empty body must not satisfy the hit path.
        cache.put(fullMessage(id: "iCloud||INBOX||1", body: ""))
        let meta = [metaRow(id: "iCloud||INBOX||1")]

        var capturedIds: [String]?
        _ = MailBridge.assemblePreviews(
            metadata: meta, previewChars: 100, cache: cache,
            fetchMisses: { ids in capturedIds = ids; return (messages: [], timedOut: false) }
        )
        XCTAssertEqual(capturedIds, ["iCloud||INBOX||1"])
    }

    // MARK: - buildBatchBodiesScript

    func testBatchScriptShape() {
        let script = MailBridge.buildBatchBodiesScript(
            compoundIds: ["iCloud||INBOX||1", "iCloud||INBOX||2", "Work||INBOX||9"],
            softTimeoutMs: 22000
        )
        XCTAssertTrue(script.contains("var groups ="), "injects grouped ids")
        XCTAssertTrue(script.contains("var softTimeoutMs = 22000;"))
        XCTAssertTrue(script.contains("Date.now() - _start > softTimeoutMs"), "soft-timeout guard")
        XCTAssertTrue(script.contains("_meta.timedOut = true"))
        XCTAssertTrue(script.contains("msg.content()"), "fetches body")
        XCTAssertTrue(script.contains("JSON.stringify({results: results, meta: _meta});"))
    }

    func testBatchScriptGroupsByMailbox() {
        // Two ids in one account/mailbox + one in another → two groups, each
        // mailbox resolved once.
        let script = MailBridge.buildBatchBodiesScript(
            compoundIds: ["iCloud||INBOX||1", "iCloud||INBOX||2", "Work||Archive||9"]
        )
        XCTAssertTrue(script.contains("\"account\":\"iCloud\""))
        XCTAssertTrue(script.contains("\"account\":\"Work\""))
        XCTAssertTrue(script.contains("\"mailbox\":\"Archive\""))
        // The two iCloud ids share one group's ids array.
        XCTAssertTrue(script.contains("\"ids\":[\"1\",\"2\"]"))
    }

    func testBatchScriptDropsUnparseableIds() {
        // A malformed id must not appear; valid ones still do.
        let script = MailBridge.buildBatchBodiesScript(compoundIds: ["garbage", "iCloud||INBOX||5"])
        XCTAssertFalse(script.contains("garbage"))
        XCTAssertTrue(script.contains("\"ids\":[\"5\"]"))
    }
}
