import Foundation
@testable import PippinLib
import XCTest

/// The subset of JSON Schema 2020-12 that `docs/schemas` uses: type, const,
/// enum, properties, required, additionalProperties, items, minItems, minimum,
/// pattern, oneOf and local `$ref`. Test-only; the runtime `SchemaValidator`
/// stays the small top-level argument check it is.
enum JSONSchema {
    /// Every way `value` breaks `schema`; empty when it conforms.
    static func errors(_ value: JSONValue, _ schema: JSONValue, root: JSONValue? = nil, at path: String = "$") -> [String] {
        let root = root ?? schema
        guard case let .object(rules) = schema else { return [] }
        var errors: [String] = []

        if let ref = rules["$ref"]?.stringValue {
            let target = ref.dropFirst(2).split(separator: "/").reduce(Optional(root)) { node, part in node?[String(part)] }
            guard let target else { return ["\(path): unresolved \(ref)"] }
            errors += self.errors(value, target, root: root, at: path)
        }
        if let options = rules["oneOf"]?.arrayValue {
            let matches = options.filter { self.errors(value, $0, root: root, at: path).isEmpty }.count
            if matches != 1 {
                let detail = options.flatMap { self.errors(value, $0, root: root, at: path) }.joined(separator: "; ")
                errors.append("\(path): matches \(matches) of \(options.count) oneOf branches (\(detail))")
            }
        }
        if let expected = rules["const"], expected != value {
            errors.append("\(path): expected \(expected), got \(value)")
        }
        if let allowed = rules["enum"]?.arrayValue, !allowed.contains(value) {
            errors.append("\(path): \(value) is not one of \(allowed)")
        }
        if let type = rules["type"] {
            let names = type.arrayValue?.compactMap(\.stringValue) ?? [type.stringValue].compactMap { $0 }
            if !names.contains(where: { matches(value, type: $0) }) {
                errors.append("\(path): expected \(names.joined(separator: " or ")), got \(typeName(value))")
            }
        }
        if let minimum = rules["minimum"]?.doubleValue, let number = value.doubleValue, number < minimum {
            errors.append("\(path): \(number) is below \(minimum)")
        }
        if let pattern = rules["pattern"]?.stringValue, let text = value.stringValue,
           text.range(of: pattern, options: .regularExpression) == nil {
            errors.append("\(path): \"\(text)\" does not match \(pattern)")
        }
        if case let .array(items) = value {
            if let minItems = rules["minItems"]?.intValue, items.count < Int(minItems) {
                errors.append("\(path): fewer than \(minItems) items")
            }
            if let itemSchema = rules["items"] {
                for (index, item) in items.enumerated() {
                    errors += self.errors(item, itemSchema, root: root, at: "\(path)[\(index)]")
                }
            }
        }
        if case let .object(members) = value {
            let properties: [String: JSONValue]
            if case let .object(dict)? = rules["properties"] { properties = dict } else { properties = [:] }
            for name in (rules["required"]?.arrayValue ?? []).compactMap(\.stringValue) where members[name] == nil {
                errors.append("\(path): missing required \"\(name)\"")
            }
            for (name, member) in members.sorted(by: { $0.key < $1.key }) {
                if let property = properties[name] {
                    errors += self.errors(member, property, root: root, at: "\(path).\(name)")
                } else if rules["additionalProperties"] == .bool(false) {
                    errors.append("\(path): unexpected \"\(name)\"")
                } else if let extra = rules["additionalProperties"], extra != .bool(true) {
                    errors += self.errors(member, extra, root: root, at: "\(path).\(name)")
                }
            }
        }
        return errors
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("string", .string), ("array", .array), ("object", .object),
             ("integer", .int), ("number", .int), ("number", .double):
            return true
        case let ("integer", .double(number)):
            return number == number.rounded()
        default:
            return false
        }
    }

    private static func typeName(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "boolean"
        case .int: return "integer"
        case .double: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    /// The schema that fits every sample: a property is required when every
    /// sample object has it, and an array's items fit every element seen.
    static func infer(_ samples: [JSONValue]) -> JSONValue {
        var types: Set<String> = []
        var objects: [[String: JSONValue]] = []
        var elements: [JSONValue] = []
        for sample in samples {
            types.insert(typeName(sample))
            if case let .object(members) = sample { objects.append(members) }
            if case let .array(items) = sample { elements += items }
        }
        if types.contains("number") { types.remove("integer") }
        var schema: [String: JSONValue] = [:]
        if types.count == 1, let only = types.first {
            schema["type"] = .string(only)
        } else if !types.isEmpty {
            schema["type"] = .array(types.sorted().map { .string($0) })
        }
        if !objects.isEmpty {
            let names = Set(objects.flatMap(\.keys))
            schema["properties"] = .object(Dictionary(uniqueKeysWithValues: names.map { name in
                (name, infer(objects.compactMap { $0[name] }))
            }))
            let required = names.filter { name in objects.allSatisfy { $0[name] != nil } }.sorted()
            if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        }
        if types.contains("array") {
            schema["items"] = elements.isEmpty ? .object([:]) : infer(elements)
        }
        return .object(schema)
    }
}

/// Builds a value of any `Decodable` model without a fixture: every field gets
/// a placeholder. Optionals are filled at nesting depths below `fill` and left
/// nil from there down. `fillLevels` gives the widest and the narrowest output
/// and, between them, each nested optional object present with its own
/// optionals unset, so a field inside one is not wrongly marked required.
struct Filler: Decoder {
    let fill: Int
    let depth: Int
    static let fillLevels = [Int.max, 0, 1, 2, 3]
    var codingPath: [CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    struct Unsupported: Error {
        let what: String
    }

    static func make<T: Decodable>(_ type: T.Type, full: Bool) throws -> T {
        try make(type, fill: full ? Int.max : 0)
    }

    static func make<T: Decodable>(_ type: T.Type, fill: Int, depth: Int = 0) throws -> T {
        // Types a placeholder string cannot build. A raw-value enum that is
        // not CaseIterable needs one of its cases listed here.
        let known: [Any] = [
            Date(timeIntervalSince1970: 1_767_225_600), URL(fileURLWithPath: "/tmp/sample"), Data(),
            RiskLevel.low, DiagnosticCheck.Status.ok,
        ]
        if let value = known.lazy.compactMap({ $0 as? T }).first { return value }
        if let iterable = type as? any CaseIterable.Type, let first = firstCase(iterable) as? T { return first }
        return try T(from: Filler(fill: fill, depth: depth))
    }

    private static func firstCase<C: CaseIterable>(_: C.Type) -> Any? {
        C.allCases.first
    }

    func container<Key: CodingKey>(keyedBy _: Key.Type) -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(Keyed<Key>(fill: fill, depth: depth))
    }

    func unkeyedContainer() -> UnkeyedDecodingContainer {
        Unkeyed(fill: fill, depth: depth)
    }

    func singleValueContainer() -> SingleValueDecodingContainer {
        Single(fill: fill, depth: depth)
    }

    private struct Keyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
        let fill: Int
        let depth: Int
        var codingPath: [CodingKey] { [] }
        /// A dictionary decodes through `allKeys`, so it comes out empty.
        var allKeys: [Key] { [] }
        func contains(_: Key) -> Bool {
            depth < fill
        }

        func decodeNil(forKey _: Key) -> Bool {
            depth >= fill
        }

        func decode(_: Bool.Type, forKey _: Key) -> Bool {
            true
        }

        func decode(_: String.Type, forKey _: Key) -> String {
            "text"
        }

        func decode(_: Double.Type, forKey _: Key) -> Double {
            1.5
        }

        func decode(_: Float.Type, forKey _: Key) -> Float {
            1.5
        }

        func decode(_: Int.Type, forKey _: Key) -> Int {
            1
        }

        func decode(_: Int8.Type, forKey _: Key) -> Int8 {
            1
        }

        func decode(_: Int16.Type, forKey _: Key) -> Int16 {
            1
        }

        func decode(_: Int32.Type, forKey _: Key) -> Int32 {
            1
        }

        func decode(_: Int64.Type, forKey _: Key) -> Int64 {
            1
        }

        func decode(_: UInt.Type, forKey _: Key) -> UInt {
            1
        }

        func decode(_: UInt8.Type, forKey _: Key) -> UInt8 {
            1
        }

        func decode(_: UInt16.Type, forKey _: Key) -> UInt16 {
            1
        }

        func decode(_: UInt32.Type, forKey _: Key) -> UInt32 {
            1
        }

        func decode(_: UInt64.Type, forKey _: Key) -> UInt64 {
            1
        }

        func decode<T: Decodable>(_ type: T.Type, forKey _: Key) throws -> T {
            try Filler.make(type, fill: fill, depth: depth + 1)
        }

        func nestedContainer<Nested: CodingKey>(keyedBy _: Nested.Type, forKey _: Key) -> KeyedDecodingContainer<Nested> {
            KeyedDecodingContainer(Keyed<Nested>(fill: fill, depth: depth + 1))
        }

        func nestedUnkeyedContainer(forKey _: Key) -> UnkeyedDecodingContainer {
            Unkeyed(fill: fill, depth: depth)
        }

        func superDecoder() -> Decoder {
            Filler(fill: fill, depth: depth)
        }

        func superDecoder(forKey _: Key) -> Decoder {
            Filler(fill: fill, depth: depth)
        }
    }

    /// One element, so an array's item shape shows in the output.
    private struct Unkeyed: UnkeyedDecodingContainer {
        let fill: Int
        let depth: Int
        var codingPath: [CodingKey] { [] }
        var count: Int? { 1 }
        var currentIndex = 0
        var isAtEnd: Bool { currentIndex >= 1 }
        func decodeNil() -> Bool {
            false
        }

        mutating func decode(_: Bool.Type) -> Bool {
            advance(true)
        }

        mutating func decode(_: String.Type) -> String {
            advance("text")
        }

        mutating func decode(_: Double.Type) -> Double {
            advance(1.5)
        }

        mutating func decode(_: Float.Type) -> Float {
            advance(1.5)
        }

        mutating func decode(_: Int.Type) -> Int {
            advance(1)
        }

        mutating func decode(_: Int8.Type) -> Int8 {
            advance(1)
        }

        mutating func decode(_: Int16.Type) -> Int16 {
            advance(1)
        }

        mutating func decode(_: Int32.Type) -> Int32 {
            advance(1)
        }

        mutating func decode(_: Int64.Type) -> Int64 {
            advance(1)
        }

        mutating func decode(_: UInt.Type) -> UInt {
            advance(1)
        }

        mutating func decode(_: UInt8.Type) -> UInt8 {
            advance(1)
        }

        mutating func decode(_: UInt16.Type) -> UInt16 {
            advance(1)
        }

        mutating func decode(_: UInt32.Type) -> UInt32 {
            advance(1)
        }

        mutating func decode(_: UInt64.Type) -> UInt64 {
            advance(1)
        }

        mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
            try advance(Filler.make(type, fill: fill, depth: depth + 1))
        }

        mutating func nestedContainer<Nested: CodingKey>(keyedBy _: Nested.Type) -> KeyedDecodingContainer<Nested> {
            advance(KeyedDecodingContainer(Keyed<Nested>(fill: fill, depth: depth + 1)))
        }

        mutating func nestedUnkeyedContainer() -> UnkeyedDecodingContainer {
            advance(Unkeyed(fill: fill, depth: depth))
        }

        mutating func superDecoder() -> Decoder {
            advance(Filler(fill: fill, depth: depth))
        }

        private mutating func advance<T>(_ value: T) -> T {
            currentIndex += 1
            return value
        }
    }

    private struct Single: SingleValueDecodingContainer {
        let fill: Int
        let depth: Int
        var codingPath: [CodingKey] { [] }
        func decodeNil() -> Bool {
            false
        }

        func decode(_: Bool.Type) -> Bool {
            true
        }

        func decode(_: String.Type) -> String {
            "text"
        }

        func decode(_: Double.Type) -> Double {
            1.5
        }

        func decode(_: Float.Type) -> Float {
            1.5
        }

        func decode(_: Int.Type) -> Int {
            1
        }

        func decode(_: Int8.Type) -> Int8 {
            1
        }

        func decode(_: Int16.Type) -> Int16 {
            1
        }

        func decode(_: Int32.Type) -> Int32 {
            1
        }

        func decode(_: Int64.Type) -> Int64 {
            1
        }

        func decode(_: UInt.Type) -> UInt {
            1
        }

        func decode(_: UInt8.Type) -> UInt8 {
            1
        }

        func decode(_: UInt16.Type) -> UInt16 {
            1
        }

        func decode(_: UInt32.Type) -> UInt32 {
            1
        }

        func decode(_: UInt64.Type) -> UInt64 {
            1
        }

        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            try Filler.make(type, fill: fill, depth: depth + 1)
        }
    }
}

/// Reading and rewriting the checked-in files under `docs/schemas`.
enum SchemaFiles {
    static let version = "v\(AGENT_SCHEMA_VERSION)"
    static let dialect = "https://json-schema.org/draft/2020-12/schema"

    /// Repo root, from this file's place at Tests/PippinTests/Contract/.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let directory = repoRoot.appendingPathComponent("docs/schemas/\(version)")

    static func text(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try String(decoding: encoder.encode(value), as: UTF8.self) + "\n"
    }

    static func load(_ relativePath: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: directory.appendingPathComponent(relativePath)))
    }

    /// Fails when the checked-in file differs from `value`; with
    /// `PIPPIN_UPDATE_SCHEMAS=1` it rewrites the file instead.
    static func assertGolden(_ relativePath: String, _ value: JSONValue, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = directory.appendingPathComponent(relativePath)
        let expected = try text(value)
        if ProcessInfo.processInfo.environment["PIPPIN_UPDATE_SCHEMAS"] == "1" {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try expected.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let actual = try? String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(
            actual, expected,
            "docs/schemas/\(version)/\(relativePath) is stale. Regenerate: PIPPIN_UPDATE_SCHEMAS=1 make test",
            file: file, line: line
        )
    }
}
