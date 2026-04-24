import Foundation

/// Shared soft-timeout constants and helpers. Bridges that enumerate
/// unbounded collections (Contacts client-side, Notes/Mail via JXA) clamp
/// caller-supplied timeouts through `SoftTimeout.clamp(_:)` so the
/// `[1s, 5min]` bounds are defined in one place.
///
/// Keep these in sync with the JXA-side clamps in `MailBridgeScripts` and
/// the inline `Math.max/min` in the Notes scripts — those can't import this
/// module but must agree with the Swift values.
public enum SoftTimeout {
    /// Default wall-clock soft timeout for bridge enumerations. 22s — long
    /// enough for healthy stores, short enough not to wedge MCP clients or
    /// bump the 60s `runChild` hard cap.
    public static let defaultMs = 22000

    /// Clamp a caller-supplied soft timeout to `[1s, 5min]`. Zero/negative
    /// would insta-fire; huge values defeat the cap.
    public static func clamp(_ ms: Int) -> Int {
        max(1000, min(ms, 300_000))
    }
}
