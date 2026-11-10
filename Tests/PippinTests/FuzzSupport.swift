import Foundation
@testable import PippinLib
import XCTest

/// SplitMix64: tiny, seedable, and identical on every host, so a failing fuzz
/// case reproduces from the seed printed in its failure message.
struct FuzzRNG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `0 ..< bound` (`bound` must be positive).
    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }

    mutating func chance(_ percent: Int) -> Bool {
        below(100) < percent
    }

    mutating func pick<T>(_ items: [T]) -> T {
        items[below(items.count)]
    }
}

enum Fuzz {
    /// Seed for a test: `PIPPIN_FUZZ_SEED` when set (to replay a failure or
    /// explore), else the fixed per-test default so CI runs are deterministic.
    static func seed(default fallback: UInt64) -> UInt64 {
        ProcessInfo.processInfo.environment["PIPPIN_FUZZ_SEED"].flatMap { UInt64($0) } ?? fallback
    }

    /// Fragments chosen to hit quoting, separators, numeric edges and the
    /// grammars of the parsers under test.
    static let fragments: [String] = [
        "", " ", "\t", "\n", "\r", "\r\n", "\0", "\\", "\\\\", "'", "\"", "`", "${x}", "$(x)",
        "\u{2028}", "\u{2029}", "\u{202E}", "\u{FFFC}", "\u{FEFF}", "\u{301}", "\u{200D}", "🌍", "é", "١٢٣", "½",
        "||", "|", "%", "_", "%41", "%ZZ", "://", "/", ":", ";", ",", "-", "--", "+", "=", "#", "{", "}", "[", "]",
        "0", "1", "7", "9", "-1", "42", "9223372036854775807", "9223372036854775808", "-9223372036854775808",
        "99999999999999999999999999", "1e309", "0x10", "NaN",
        "today", "today+", "today+3", "week", "month", "2026-03-07", "2026-03-07T10:00:00Z", "2026-03-07 10:00",
        "0000-00-00", "9999-99-99", "T", "Z", "m", "h", "d", "w", "s", "15m", "2h",
        "this", "future", "high", "none", "agent", "id", "INBOX", "Work", "null", "true", "false",
        "{\"excluded\":[]}", "{\"steps\":[]}", "```json", "```", "imap://ABC-123/INBOX", "Subject: x", " folded",
        "eyJvZmZzZXQiOjAsImZpbHRlcl9oYXNoIjoiYSJ9", "A", "AAAA", "=", "==",
    ]

    /// A hostile string: fragments and stray scalars, in random order.
    static func string(_ rng: inout FuzzRNG, maxPieces: Int = 8) -> String {
        var out = ""
        for _ in 0 ..< rng.below(maxPieces + 1) {
            if rng.chance(80) {
                out += rng.pick(fragments)
            } else if let scalar = Unicode.Scalar(UInt32(rng.below(0x3000))) {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    static func bytes(_ rng: inout FuzzRNG, max: Int = 64) -> Data {
        Data((0 ..< rng.below(max + 1)).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
    }

    static func json(_ rng: inout FuzzRNG, depth: Int = 3) -> JSONValue {
        switch rng.below(depth > 0 ? 8 : 6) {
        case 0: return .null
        case 1: return .bool(rng.chance(50))
        case 2: return .int(rng.pick([0, 1, -1, 20, Int64.max, Int64.min, Int64(truncatingIfNeeded: rng.next())]))
        case 3: return .double(rng.pick([0, -0.5, 1e19, -1e19, 1e308, 4.9e-324, 3.0]))
        case 4, 5: return .string(string(&rng))
        case 6: return .array((0 ..< rng.below(4)).map { _ in json(&rng, depth: depth - 1) })
        default:
            var object: [String: JSONValue] = [:]
            for _ in 0 ..< rng.below(4) {
                object[string(&rng, maxPieces: 2)] = json(&rng, depth: depth - 1)
            }
            return .object(object)
        }
    }

    /// Arguments aimed at `schema`: mostly well-typed values for declared
    /// properties (so calls get past validation into `buildArgs`), salted with
    /// wrong types, unknown keys and non-object roots.
    static func arguments(_ rng: inout FuzzRNG, for schema: JSONValue) -> JSONValue? {
        if rng.chance(5) { return rng.chance(50) ? nil : json(&rng) }
        var object: [String: JSONValue] = [:]
        if case let .some(.object(properties)) = schema["properties"] {
            for (name, property) in properties.sorted(by: { $0.key < $1.key }) where rng.chance(65) {
                object[name] = rng.chance(80) ? conforming(&rng, to: property) : json(&rng)
            }
        }
        if rng.chance(10) { object[string(&rng, maxPieces: 2)] = json(&rng) }
        return .object(object)
    }

    private static func conforming(_ rng: inout FuzzRNG, to property: JSONValue) -> JSONValue {
        if case let .some(.array(options)) = property["enum"], !options.isEmpty, rng.chance(70) {
            return rng.pick(options)
        }
        switch property["type"]?.stringValue {
        case "string": return .string(string(&rng))
        case "integer": return .int(rng.pick([0, 1, -1, 20, 100_000, Int64.max, Int64.min]))
        case "number": return .double(rng.pick([0, 1.5, -1, 1e19]))
        case "boolean": return .bool(rng.chance(50))
        case "array": return .array((0 ..< rng.below(4)).map { _ in .string(string(&rng)) })
        default: return json(&rng)
        }
    }

    static func describe(_ value: JSONValue?) -> String {
        guard let value, let data = try? JSONEncoder().encode(value) else { return "nil" }
        return String(decoding: data, as: UTF8.self)
    }
}
