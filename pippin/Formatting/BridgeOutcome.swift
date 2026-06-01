import Foundation

/// Outcome of a bridge query that walks an unbounded collection and may hit a
/// wall-clock soft timeout: the `results` plus a `timedOut` flag callers
/// surface as a "partial results" advisory to the user.
///
/// Shared by the bridges that emit the `results`-generic shape — `NotesBridge`
/// and `ContactsBridge` — so the struct (and its back-compat decoder) isn't
/// redefined per bridge. The `Decodable` conformance is **conditional** on
/// `T: Decodable`: JXA-backed bridges (Notes) decode `{results, meta:{timedOut}}`
/// straight from the script's JSON, while framework-backed bridges (Contacts)
/// build the value in Swift and never exercise it — so the consolidation
/// doesn't couple unrelated bridges to a decoder they don't use.
///
/// `MailBridge.ScanOutcome` deliberately stays separate: it is non-generic and
/// names its payload `messages` (not `results`), a shape already unified within
/// MailBridge.
public struct BridgeOutcome<T> {
    public let results: T
    public let timedOut: Bool

    public init(results: T, timedOut: Bool) {
        self.results = results
        self.timedOut = timedOut
    }
}

/// Conditionally Sendable so callers can return a BridgeOutcome across a
/// `detachBlocking { }` boundary when the payload is Sendable (it always is —
/// the bridge DTO arrays are Sendable). A `public` struct needs this spelled
/// out; the compiler only infers Sendable for non-public types.
extension BridgeOutcome: Sendable where T: Sendable {}

extension BridgeOutcome: Decodable where T: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        results = try container.decode(T.self, forKey: .results)
        let meta = try container.decodeIfPresent(Meta.self, forKey: .meta)
        timedOut = meta?.timedOut ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case results, meta
    }

    /// Backward-compatible: legacy scripts that don't emit `timedOut` (or omit
    /// `meta` entirely) decode cleanly with `timedOut` defaulting to `false`
    /// rather than failing.
    private struct Meta: Decodable {
        let timedOut: Bool

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            timedOut = try container.decodeIfPresent(Bool.self, forKey: .timedOut) ?? false
        }

        private enum CodingKeys: String, CodingKey {
            case timedOut
        }
    }
}
