import Foundation

/// Shared JSON field-projection used by `--fields`. One implementation so the
/// json-mode helpers on the models (`jsonData(fields:)`, `filteredNoteDicts`)
/// and the agent-mode envelope path can't drift apart.
///
/// Projection keeps only the requested top-level keys. The rules cover every
/// payload shape pippin emits:
/// - **array of objects** → each element projected to `fields`
/// - **object with an `items` array** (a paginated page) → `items` elements
///   projected, sibling keys like `next_cursor` preserved
/// - **plain object** (e.g. a single `show` result) → projected to `fields`
/// - **scalars / non-object elements** → returned unchanged
public enum FieldProjection {
    /// Parse a comma-separated `--fields` string into a trimmed, de-blanked
    /// list. Returns `nil` for nil/empty input so callers can treat "no
    /// projection" uniformly.
    public static func parse(_ fields: String?) -> [String]? {
        guard let fields else { return nil }
        let list = fields
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return list.isEmpty ? nil : list
    }

    /// Project an already-deserialized JSON value (the output of
    /// `JSONSerialization.jsonObject`).
    public static func project(_ json: Any, fields: [String]) -> Any {
        if let array = json as? [Any] {
            return array.map { projectElement($0, fields: fields) }
        }
        if let dict = json as? [String: Any] {
            if let items = dict["items"] as? [Any] {
                var out = dict
                out["items"] = items.map { projectElement($0, fields: fields) }
                return out
            }
            return projectElement(dict, fields: fields)
        }
        return json
    }

    /// Encode `value`, then project — the entry point most callers want.
    /// Returns a `JSONSerialization`-compatible object ready to re-serialize.
    public static func projectedObject(_ value: some Encodable, fields: [String]) throws -> Any {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        let json = try JSONSerialization.jsonObject(with: data)
        return project(json, fields: fields)
    }

    private static func projectElement(_ element: Any, fields: [String]) -> Any {
        guard let dict = element as? [String: Any] else { return element }
        return fields.reduce(into: [String: Any]()) { result, field in
            if let value = dict[field] { result[field] = value }
        }
    }
}
