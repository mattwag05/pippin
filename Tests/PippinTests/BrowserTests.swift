@testable import PippinLib
import XCTest

final class BrowserTests: XCTestCase {
    // MARK: - AccessibilityTree parsing

    func testAccessibilityTreeParseButton() throws {
        let json = """
        [{"role":"button","name":"Submit","children":[]}]
        """
        let elements = try AccessibilityTree.parse(json)
        XCTAssertEqual(elements.count, 1)
        let first = elements[0]
        XCTAssertEqual(first.ref, "@ref1")
        XCTAssertEqual(first.role, "button")
        XCTAssertEqual(first.name, "Submit")
    }

    func testAccessibilityTreeParseMultipleRefs() throws {
        let json = """
        [
          {"role":"button","name":"Click Me","children":[]},
          {"role":"link","name":"Go Here","children":[]},
          {"role":"textbox","name":"Search","children":[]}
        ]
        """
        let elements = try AccessibilityTree.parse(json)
        XCTAssertEqual(elements.count, 3)
        XCTAssertEqual(elements[0].ref, "@ref1")
        XCTAssertEqual(elements[0].role, "button")
        XCTAssertEqual(elements[1].ref, "@ref2")
        XCTAssertEqual(elements[1].role, "link")
        XCTAssertEqual(elements[2].ref, "@ref3")
        XCTAssertEqual(elements[2].role, "textbox")
    }

    func testAccessibilityTreeNonInteractiveNoRef() throws {
        let json = """
        [{"role":"generic","name":"wrapper","children":[{"role":"button","name":"OK","children":[]}]}]
        """
        let elements = try AccessibilityTree.parse(json)
        XCTAssertEqual(elements.count, 1)
        let outer = elements[0]
        // Non-interactive "generic" role should have empty ref
        XCTAssertEqual(outer.ref, "")
        XCTAssertEqual(outer.role, "generic")
        XCTAssertEqual(outer.children.count, 1)
        let inner = outer.children[0]
        // The button inside gets @ref1
        XCTAssertEqual(inner.ref, "@ref1")
        XCTAssertEqual(inner.role, "button")
        XCTAssertEqual(inner.name, "OK")
    }

    func testAccessibilityTreeInvalidJSON() throws {
        XCTAssertThrowsError(try AccessibilityTree.parse("invalid json"))
    }

    // MARK: - PageInfo Codable round-trip

    func testPageInfoRoundTrip() throws {
        let original = PageInfo(url: "https://example.com", title: "Example Domain", status: 200)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PageInfo.self, from: data)

        XCTAssertEqual(decoded.url, original.url)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.status, original.status)
    }

    func testPageInfoRoundTripNilStatus() throws {
        let original = PageInfo(url: "https://example.com", title: "Example")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PageInfo.self, from: data)

        XCTAssertEqual(decoded.url, "https://example.com")
        XCTAssertEqual(decoded.title, "Example")
        XCTAssertNil(decoded.status)
    }

    // MARK: - ElementRef Codable round-trip

    func testElementRefRoundTrip() throws {
        let child = ElementRef(ref: "@ref2", role: "link", name: "Learn more", children: [])
        let original = ElementRef(
            ref: "@ref1",
            role: "button",
            name: "Submit",
            value: "submit",
            children: [child]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ElementRef.self, from: data)

        XCTAssertEqual(decoded.ref, "@ref1")
        XCTAssertEqual(decoded.role, "button")
        XCTAssertEqual(decoded.name, "Submit")
        XCTAssertEqual(decoded.value, "submit")
        XCTAssertEqual(decoded.children.count, 1)
        XCTAssertEqual(decoded.children[0].ref, "@ref2")
        XCTAssertEqual(decoded.children[0].role, "link")
        XCTAssertEqual(decoded.children[0].name, "Learn more")
    }

    func testElementRefRoundTripEmptyChildren() throws {
        let original = ElementRef(ref: "@ref1", role: "textbox", name: "Email")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ElementRef.self, from: data)

        XCTAssertEqual(decoded.ref, "@ref1")
        XCTAssertEqual(decoded.role, "textbox")
        XCTAssertEqual(decoded.name, "Email")
        XCTAssertNil(decoded.value)
        XCTAssertTrue(decoded.children.isEmpty)
    }

    // MARK: - SnapshotResult Codable round-trip

    func testSnapshotResultRoundTrip() throws {
        let element = ElementRef(ref: "@ref1", role: "button", name: "OK", children: [])
        let original = SnapshotResult(
            url: "https://example.com/page",
            title: "A Page",
            snapshot: [element]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SnapshotResult.self, from: data)

        XCTAssertEqual(decoded.url, "https://example.com/page")
        XCTAssertEqual(decoded.title, "A Page")
        XCTAssertEqual(decoded.snapshot.count, 1)
        XCTAssertEqual(decoded.snapshot[0].ref, "@ref1")
        XCTAssertEqual(decoded.snapshot[0].role, "button")
    }

    func testSnapshotResultEmptySnapshot() throws {
        let original = SnapshotResult(url: "about:blank", title: "Blank", snapshot: [])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SnapshotResult.self, from: data)

        XCTAssertEqual(decoded.url, "about:blank")
        XCTAssertEqual(decoded.title, "Blank")
        XCTAssertTrue(decoded.snapshot.isEmpty)
    }

    // MARK: - TabInfo Codable round-trip

    func testTabInfoRoundTrip() throws {
        let original = TabInfo(index: 0, url: "https://example.com", title: "Example", isActive: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TabInfo.self, from: data)

        XCTAssertEqual(decoded.index, 0)
        XCTAssertEqual(decoded.url, "https://example.com")
        XCTAssertEqual(decoded.title, "Example")
        XCTAssertTrue(decoded.isActive)
    }

    func testTabInfoInactiveTab() throws {
        let original = TabInfo(index: 1, url: "https://other.com", title: "Other", isActive: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TabInfo.self, from: data)

        XCTAssertEqual(decoded.index, 1)
        XCTAssertFalse(decoded.isActive)
    }

    func testTabInfoArrayRoundTrip() throws {
        let tabs = [
            TabInfo(index: 0, url: "https://example.com", title: "Tab 1", isActive: false),
            TabInfo(index: 1, url: "https://other.com", title: "Tab 2", isActive: true),
        ]
        let data = try JSONEncoder().encode(tabs)
        let decoded = try JSONDecoder().decode([TabInfo].self, from: data)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].index, 0)
        XCTAssertFalse(decoded[0].isActive)
        XCTAssertEqual(decoded[1].index, 1)
        XCTAssertTrue(decoded[1].isActive)
    }
}
