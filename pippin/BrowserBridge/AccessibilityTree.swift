import Foundation

// MARK: - Interactive Role Set

private let interactiveRoles: Set<String> = [
    "button",
    "link",
    "textbox",
    "checkbox",
    "radio",
    "combobox",
    "listbox",
    "menuitem",
    "menuitemcheckbox",
    "menuitemradio",
    "option",
    "searchbox",
    "slider",
    "spinbutton",
    "switch",
    "tab",
    "treeitem",
    "select",
    "input",
    "textarea",
]

// MARK: - AccessibilityTree

public enum AccessibilityTree {
    /// Parse a Playwright accessibility snapshot (JSON string) and assign @ref IDs to interactive elements.
    /// Returns the root-level ElementRef array.
    public static func parse(_ jsonString: String) throws -> [ElementRef] {
        guard let data = jsonString.data(using: .utf8) else {
            throw BrowserBridgeError.decodingFailed("AccessibilityTree: cannot convert JSON string to data")
        }
        guard let rawArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw BrowserBridgeError.decodingFailed("AccessibilityTree: expected top-level JSON array of objects")
        }
        return fromArray(rawArray)
    }

    /// Parse a pre-decoded JSON object array and assign @ref IDs.
    public static func fromArray(_ array: [[String: Any]]) -> [ElementRef] {
        // Counter is captured by reference via a class box so recursive calls share state
        let counter = RefCounter()
        return array.map { node in parseNode(node, counter: counter) }
    }

    // MARK: - Private helpers

    private final class RefCounter: @unchecked Sendable {
        var value: Int = 0

        func next() -> String {
            value += 1
            return "@ref\(value)"
        }
    }

    private static func parseNode(_ node: [String: Any], counter: RefCounter) -> ElementRef {
        let role = (node["role"] as? String) ?? "generic"
        let name = node["name"] as? String
        let value = node["value"] as? String

        // Assign a @ref ID only to interactive elements
        let ref: String
        if interactiveRoles.contains(role.lowercased()) {
            ref = counter.next()
        } else {
            // Non-interactive nodes still appear in the tree without a @ref
            ref = ""
        }

        // Recurse into children
        let rawChildren = node["children"] as? [[String: Any]] ?? []
        let children = rawChildren.map { parseNode($0, counter: counter) }

        return ElementRef(ref: ref, role: role, name: name, value: value, children: children)
    }
}
